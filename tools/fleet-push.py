#!/usr/bin/env python3
"""fleet-push.py v3 — 三节点 fleet 压缩推送调度器（PTY 屏幕流归整 + 实时进度聚合）

用法:
    python3 tools/fleet-push.py [--plan] [--dry-run N] [--tag TAG]
        [--versions v1 v2 ...] [--attempts N] [--include-artifacts]
        [--no-remote-upload] [--verify-download] [--no-clean]

流程（每版本, 包源=packing/pacman/opencode-<v>-1-aarch64.pkg.tar.xz）:
  push   本机 →节点: python 分块写 ssh stdin, 自建进度条        (10%)
  untar  节点解包取 ELF                                         (5%)
  upx    upx --best, 原生进度条实时聚合(如 `2/5 [***....] 37.7%`) (45%)
  xz9    xz -9 压缩产物                                         (15%)
  upload 节点直传 gh release(已录认证): python3 分块上传自建进度条,
         无 python3 回落 gh release upload; 上传后本机核对资产尺寸 (25%)

upx 完成块解析并展示:
        File size         Ratio      Format      Name
   179807785 ->  51891796   28.86%    linux/elf64   xxxbin

仪表盘: 槽位行(实时阶段+进度+瞬态) / 版本行(运行=总条, 完成=upx摘要)
        底部 TOTAL 总进度条 + 事件流. Ctrl-C 优雅收尾落终表.

零第三方依赖(本机); 节点需 upx + (gh 已认证); python3 可选(升级上传进度).
"""

import argparse
import base64
import os
import pty
import re
import select
import shlex
import signal
import subprocess
import sys
import threading
import time
from collections import deque

# ───────────────────── 配置 ─────────────────────

def _find_repo(start):
    d = start
    while d != "/":
        if os.path.isdir(os.path.join(d, ".git")):
            return d
        d = os.path.dirname(d)
    return None

_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = _find_repo(_SCRIPT_DIR)
HOME_BASE = os.path.expanduser("~/opc-fleet")
INBOX = os.path.join(HOME_BASE, "inbox")          # 节点常驻模式的包源
PKG_DIR = (os.path.join(REPO_ROOT, "packing", "pacman") if REPO_ROOT
           else INBOX)
OUT_DIR = (os.path.join(REPO_ROOT, "packing", "fleet") if REPO_ROOT
           else os.path.join(HOME_BASE, "out"))
EVID_DIR = (os.path.join(REPO_ROOT, ".omo", "evidence", "fleet") if REPO_ROOT
            else os.path.join(HOME_BASE, "logs"))
LOG_PATH = (os.path.join(REPO_ROOT, ".omo", "evidence",
                         "task-fleet-compressed-push.log") if REPO_ROOT
            else os.path.join(HOME_BASE, "logs", "fleet-push.log"))

RELEASE_TAG = "Push260903"
ASSET_TMPL = "opencode-native-{ver}-upx.xz"
PKG_TMPL = "opencode-{ver}-1-aarch64.pkg.tar.xz"

_DEFAULT_NODES = {              # None = 本机
    "local":  None,
    "miao1":  "ssh miao1",
    "miao2":  "ssh miao2",
}


def _parse_nodes():
    env = os.environ.get("FLEET_NODES")
    if not env:
        return dict(_DEFAULT_NODES)
    out = {}
    for part in env.split(","):
        part = part.strip()
        if not part:
            continue
        if "=" in part:
            name, cmd = part.split("=", 1)
            out[name.strip()] = None if cmd.strip() in ("local", "-") else cmd.strip()
        else:
            out[part] = None
    return out


NODES = _parse_nodes()
RDIR = "~/opc-fleet/{ver}"
CLEAN_REMOTE = True
MAX_ATTEMPTS = 3
SSH_TIMEOUT = 8
HEALTH_TTL = 60

# 阶段权重 / 兜底 ETA(秒)（push/upx/upload 有真实进度, ETA 仅兜底）
WEIGHTS = {"push": .10, "untar": .05, "upx": .45, "xz9": .15, "upload": .25}
STAGE_ETA = {"push": 60, "untar": 60, "upx": 480, "xz9": 150, "upload": 90}

# ───────────────────── ANSI ─────────────────────

ALT_IN, ALT_OUT = "\x1b[?1049h", "\x1b[?1049l"
HIDE_C, SHOW_C = "\x1b[?25l", "\x1b[?25h"
CLR = "\x1b[2J\x1b[H"
DIM, B, G, Y, R, N = "\x1b[2m", "\x1b[1m", "\x1b[32m", "\x1b[33m", "\x1b[31m", "\x1b[0m"


def bar(pct, width=24, ch="█", gap="░"):
    n = max(0, min(width, int(round(width * pct / 100.0))))
    return ch * n + gap * (width - n)


def hms(sec):
    sec = int(sec)
    return f"{sec//3600:02d}:{(sec%3600)//60:02d}:{sec%60:02d}"


def mib(n):
    return f"{n/1048576:.1f}MiB"

# ───────────────────── 状态 ─────────────────────


class Ver:
    PENDING, PUSH, COMPUTE, UPLOAD_WAIT, DONE, FAILED, SKIPPED = (
        "pending", "push", "compute", "upload-wait", "done", "failed", "skipped")

    def __init__(self, ver, pkg, asset):
        self.ver, self.pkg, self.asset = ver, pkg, asset
        self.state = Ver.PENDING
        self.attempt = 0
        self.node = None
        self.stage = None
        self.pct = 0.0
        self.stage_pct: dict = {}
        self.t_start = None
        self.t_state = None
        self.t_done = None
        self.rc = None
        self.err = None
        self.push_pct = 0.0
        self.push_done = 0
        self.push_total = 0
        self.sha_node = None
        self.size_out = 0
        self.upx_in = self.upx_out = 0
        self.upx_ratio = self.upx_fmt = self.upx_name = ""
        self.upx_live = ""
        self.upload_pct = 0.0
        self.live = ""

    def stage_progress(self, stage, now=None):
        if self.stage_pct.get(stage, 0) >= 100:
            return 100.0
        if self.t_state is None:
            return 0.0
        now = now if now is not None else time.time()
        return min(95.0, 100.0 * (now - self.t_state) / max(1, STAGE_ETA.get(stage, 120)))

    def recompute(self, now=None):
        comp = ["untar", "upx", "xz9"]
        if self.state == Ver.PENDING:
            self.pct = 0.0
        elif self.state == Ver.PUSH:
            self.pct = WEIGHTS["push"] * self.push_pct
        elif self.state == Ver.COMPUTE:
            base = WEIGHTS["push"]
            acc = 0.0
            for s in comp:
                acc += self.stage_progress(s, now)
            self.pct = base + (WEIGHTS["untar"] + WEIGHTS["upx"] + WEIGHTS["xz9"]) * acc / 300.0
        elif self.state == Ver.UPLOAD_WAIT:
            base = WEIGHTS["push"] + WEIGHTS["untar"] + WEIGHTS["upx"] + WEIGHTS["xz9"]
            self.pct = base + WEIGHTS["upload"] * self.stage_progress("upload", now)
        else:
            self.pct = 100.0


class Fleet:
    def __init__(self):
        self.lock = threading.RLock()
        self.vers: dict = {}
        self.slot_job: dict = {}
        self.slot_live: dict = {}
        self.events = deque(maxlen=200)
        self.health: dict = {}
        self.stop = threading.Event()
        self.t0 = time.time()
        self.repo = ""

    def ev(self, text):
        with self.lock:
            self.events.append((time.time(), text))
        log(f"EVT {text}")

    def health_ok(self, node, cmd):
        if node == "local":
            return True
        with self.lock:
            ok, ts = self.health.get(node, (None, 0.0))
            if ts and time.time() - ts < HEALTH_TTL:
                return bool(ok)
        try:
            rc = subprocess.run(shlex.split(cmd) + ["true"], timeout=SSH_TIMEOUT,
                                stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL).returncode
            ok = rc == 0
        except Exception:
            ok = False
        with self.lock:
            self.health[node] = (ok, time.time())
        if not ok:
            self.ev(f"{node} 不可达 (ssh {SSH_TIMEOUT}s)")
        return ok


def log(line):
    os.makedirs(EVID_DIR, exist_ok=True)
    os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)
    with open(LOG_PATH, "a", encoding="utf-8") as f:
        f.write(time.strftime("[%H:%M:%S] ") + line + "\n")

# ───────────────────── 节点作业脚本 ─────────────────────

UPLOADER_PY = r'''
import subprocess, sys, os, urllib.request
tag, repo, path, asset = sys.argv[1:5]
size = os.path.getsize(path)
def gh(*a):
    return subprocess.run(["gh"]+list(a), capture_output=True, text=True).stdout.strip()
url = gh("api", "repos/%s/releases/tags/%s" % (repo, tag), "--jq", ".upload_url")
url = url.split("{")[0] + "?name=" + asset
tok = gh("auth", "token")
class P:
    def __init__(self, f):
        self.f, self.n, self.last = f, 0, -1
    def read(self, n=-1):
        b = self.f.read(n)
        self.n += len(b)
        pct = int(100*self.n/size) if size else 100
        if pct != self.last:
            sys.stdout.write("#U %d\n" % pct); sys.stdout.flush(); self.last = pct
        return b
req = urllib.request.Request(url, data=P(open(path, "rb")), method="PUT",
    headers={"Authorization": "Bearer " + tok,
             "Content-Type": "application/octet-stream",
             "Content-Length": str(size)})
urllib.request.urlopen(req)
print("#U 100")
'''

JOB_SH = r'''
set -uo pipefail
R="$1"; D="$2"; A="$3"; TAG="$4"; REPO="$5"; RM="$6"
cd "$R" || exit 9
say(){ printf '#%s\n' "$*"; }
say "S untar"
tar -xJf "$D" -C "$R" || { say "E untar"; exit 2; }
B="$(find "$R" -type f -name opencode | head -1)"
[ -n "$B" ] || { say "E no-elf"; exit 2; }
say "D untar"
say "S upx"
upx --best -o "$R/packed" "$B"
rc=$?
say "D upx"
[ $rc -eq 0 ] || { say "E upx rc=$rc"; exit 3; }
say "S xz9"
xz -9 -c "$R/packed" > "$R/out.xz" || { say "E xz9"; exit 4; }
say "D xz9"
printf '#SHA %s\n' "$(sha256sum "$R/out.xz" | cut -d' ' -f1)"
printf '#SIZE %s\n' "$(wc -c < "$R/out.xz")"
say "S upload"
ok=0
if command -v python3 >/dev/null 2>&1; then
  if [ -f upl.py ]; then
    python3 upl.py "$TAG" "$REPO" "$R/out.xz" "$A" && ok=1
  fi
fi
if [ $ok -eq 0 ]; then
  gh release upload "$TAG" "$R/out.xz" --repo "$REPO" --clobber && ok=1
fi
if [ $ok -eq 0 ]; then say "E upload"; exit 5; fi
say "D upload"
say "UPLOADED"
[ "$RM" = "1" ] && rm -rf "$R"
exit 0
'''


def b64(s):
    return base64.b64encode(s.encode()).decode()


def job_argv(node_cmd, v, tag, repo, do_clean):
    r = v.rdir
    pkg_name = os.path.basename(v.pkg)
    if node_cmd is None:
        d = shlex.quote(v.pkg)                 # 本机: 直接读本地绝对路径
        head = f"mkdir -p {r}"
    else:
        d = shlex.quote(f"{r}/{pkg_name}")
        head = f"mkdir -p {r} && cat > {d}"    # 远程: 先收 push 的 stdin
    inner = (f"{head} && echo {b64(UPLOADER_PY)} | base64 -d > {r}/upl.py && "
             f"echo {b64(JOB_SH)} | base64 -d > {r}/job.sh && "
             f"bash {r}/job.sh {r} {d} {shlex.quote(v.asset)} "
             f"{shlex.quote(tag)} {shlex.quote(repo)} {1 if do_clean else 0}")
    if node_cmd is None:
        return ["bash", "-c", inner], None
    return ["bash", "-c", f"{node_cmd} {shlex.quote(inner)}"], v.pkg

# ───────────────────── PTY 作业 ─────────────────────

UPX_PROG = re.compile(r"^\s*(\S+)\s+(\d+)/(\d+)\s+\[([*.]+)\]\s+([\d.]+)%")
UPX_SUM = re.compile(r"^\s*(\d+)\s*->\s*(\d+)\s+([\d.]+)%\s+(\S+)\s+(\S+)\s*$")


class PtyJob:
    def __init__(self, fleet, ver, slot, argv, push_file=None):
        self.f, self.v, self.slot = fleet, ver, slot
        self.argv = argv
        self.push_file = push_file          # 非 None: 分块写 stdin(自建进度)
        self.proc = None
        self.master = None
        self.raw = deque(maxlen=600)
        self.transient = ""
        self.rc = None
        self.done = threading.Event()

    def _on_line(self, line):
        v = self.v
        self.raw.append(line)
        m = re.match(r"^#S (\S+)$", line)
        if m:
            with self.f.lock:
                v.stage = m.group(1)
                v.t_state = time.time()
            return
        m = re.match(r"^#D (\S+)$", line)
        if m:
            with self.f.lock:
                v.stage_pct[m.group(1)] = 100.0
                if v.stage == m.group(1):
                    v.stage = None
            return
        m = re.match(r"^#E (.+)$", line)
        if m:
            with self.f.lock:
                v.err = m.group(1)
            self.f.ev(f"{self.slot}: {v.ver} 错误 {m.group(1)}")
            return
        m = re.match(r"^#U (\d+)$", line)
        if m:
            with self.f.lock:
                v.stage_pct["upload"] = float(m.group(1))
                v.upload_pct = float(m.group(1))
            return
        m = re.match(r"^#SHA ([0-9a-f]{64})$", line)
        if m:
            with self.f.lock:
                v.sha_node = m.group(1)
            return
        m = re.match(r"^#SIZE (\d+)$", line)
        if m:
            with self.f.lock:
                v.size_out = int(m.group(1))
            return
        m = UPX_SUM.match(line)
        if m:
            with self.f.lock:
                v.upx_in, v.upx_out = int(m.group(1)), int(m.group(2))
                v.upx_ratio, v.upx_fmt, v.upx_name = m.group(3), m.group(4), m.group(5)
            return
        if line.strip() == "#UPLOADED":
            self.f.ev(f"{self.slot}: {v.ver} 已上传 {v.asset}")

    def _on_transient(self, t):
        v = self.v
        m = UPX_PROG.match(t)
        if m:
            with self.f.lock:
                v.stage_pct["upx"] = float(m.group(5))
                v.upx_live = f"{m.group(2)}/{m.group(3)} {m.group(5)}%"
            return
        if "%" in t:
            with self.f.lock:
                v.live = t[:60]

    def _push_writer(self):
        """分块写 ssh stdin, 自建 push 进度"""
        assert self.push_file is not None
        assert self.proc is not None
        total = os.path.getsize(self.push_file)
        with self.f.lock:
            self.v.push_total = total
        sent = 0
        try:
            with open(self.push_file, "rb") as f, self.proc.stdin as w:
                while True:
                    chunk = f.read(1048576)
                    if not chunk:
                        break
                    w.write(chunk)
                    sent += len(chunk)
                    with self.f.lock:
                        self.v.push_pct = 100.0 * sent / max(1, total)
                        self.v.push_done = sent
                try:
                    w.close()
                except Exception:
                    pass
            self.f.ev(f"{self.slot}: {self.v.ver} push 完成 {mib(total)}")
        except Exception as e:
            self.f.ev(f"{self.slot}: {self.v.ver} push 中断 {e}")

    def _reader(self, master, proc):
        while True:
            try:
                r, _, _ = select.select([master], [], [], 0.5)
            except (OSError, ValueError):
                break
            if r:
                try:
                    data = os.read(master, 65536)
                except OSError:
                    break
                if not data:
                    break
                for part in data.decode("utf-8", "replace").replace("\r\n", "\n").split("\n"):
                    if "\r" in part:
                        segs = part.split("\r")
                        for s in segs[:-1]:
                            if s.strip():
                                self._on_line(s)
                        self.transient = segs[-1]
                        self._on_transient(self.transient)
                    elif part:
                        self.transient = ""
                        self._on_line(part)
            if proc.poll() is not None and not r:
                break
        try:
            self.rc = proc.wait(timeout=15)
        except Exception:
            self.rc = proc.returncode
        self.done.set()

    def start(self):
        master, slave = pty.openpty()
        if self.push_file:
            self.proc = subprocess.Popen(self.argv, stdin=subprocess.PIPE,
                                         stdout=slave, stderr=slave,
                                         cwd=REPO_ROOT, preexec_fn=os.setsid,
                                         close_fds=True)
        else:
            self.proc = subprocess.Popen(self.argv, stdin=subprocess.DEVNULL,
                                         stdout=slave, stderr=slave,
                                         cwd=REPO_ROOT, preexec_fn=os.setsid,
                                         close_fds=True)
        os.close(slave)
        self.master = master
        if self.push_file:
            threading.Thread(target=self._push_writer, daemon=True).start()
        threading.Thread(target=self._reader, args=(master, self.proc),
                         daemon=True, name=f"rd-{self.v.ver}").start()
        return self

    def kill(self):
        if self.proc is not None:
            try:
                self.proc.terminate()
            except Exception:
                pass

# ───────────────────── 调度器 ─────────────────────


class Scheduler:
    def __init__(self, fleet, opts):
        self.f, self.o = fleet, opts
        self.jobs: dict = {}

    def next_pending(self, exclude_node=None):
        with self.f.lock:
            for v in self.f.vers.values():
                if v.state == Ver.PENDING and v.node is None:
                    if exclude_node and v.err and exclude_node in (v.err or ""):
                        continue
                    return v
            return None

    def assign(self, slot, node, node_cmd, kind):
        v = self.next_pending()
        if v is None:
            return False
        with self.f.lock:
            if v.state != Ver.PENDING or v.node is not None:
                return False
            if kind == "push" and v.state != Ver.PENDING:
                return False
            v.node = node
            v.state = Ver.PUSH if (kind == "push" and node != "local") else Ver.COMPUTE
            if node == "local":
                v.state = Ver.COMPUTE       # 本机无 push 阶段
            v.attempt += 1
            v.t_start = v.t_start or time.time()
            v.t_state = time.time()
            v.stage = None
            v.stage_pct = {}
            v.push_pct = 0.0
            self.f.slot_job[slot] = v
        self.f.ev(f"{slot} ← {v.ver} (尝试 {v.attempt}/{self.o.attempts})")
        argv, pushf = job_argv(node_cmd, v, self.o.tag, self.f.repo, self.o.clean)
        job = PtyJob(self.f, v, slot, argv, push_file=pushf)
        self.jobs[(slot, v.ver)] = job
        job.start()
        with self.f.lock:
            v.state = Ver.PUSH if pushf else Ver.COMPUTE
        return True

    def poll(self):
        for (slot, ver), job in list(self.jobs.items()):
            if not job.done.is_set():
                continue
            v = self.f.vers[ver]
            rc = job.rc
            with self.f.lock:
                self.f.slot_job.pop(slot, None)
                v.rc = rc
                if v.state == Ver.PUSH and rc not in (0, None) and v.push_pct < 100:
                    v.state = Ver.PENDING
                    v.node = None
                    self.f.ev(f"{slot}: {v.ver} push 失败 rc={rc} → 重新排队")
                    self.jobs.pop((slot, ver), None)
                    continue
                if rc == 0 and v.sha_node:
                    v.state = Ver.DONE
                    v.t_done = time.time()
                    log(f"DONE {ver} node={v.node} sha={v.sha_node[:16]} "
                        f"out={mib(v.size_out)} upx={v.upx_in}->{v.upx_out} "
                        f"({v.upx_ratio}%) fmt={v.upx_fmt}")
                    self.f.ev(f"{ver} ✔ 完成 {mib(v.size_out)} ({v.upx_ratio}%)")
                else:
                    if v.attempt >= self.o.attempts:
                        v.state = Ver.FAILED
                        v.t_done = time.time()
                        log(f"FAIL {ver} rc={rc} err={v.err} attempts={v.attempt}")
                        self.f.ev(f"{ver} ✖ 失败 rc={rc} ({v.attempt} 次尝试)")
                    else:
                        v.state = Ver.PENDING
                        v.node = None
                        v.err = v.err or f"rc={rc}"
                        self.f.ev(f"{ver} 重试排队 ({v.attempt}/{self.o.attempts})")
                self.jobs.pop((slot, ver), None)

    def slots_free(self):
        with self.f.lock:
            return {s for s in self.f.slot_job} == set() and not self.jobs

    def running(self):
        with self.f.lock:
            return set(self.f.slot_job.keys())

# ───────────────────── 显示 ─────────────────────


def render(f, o, out):
    now = time.time()
    with f.lock:
        vers = list(f.vers.values())
        slot_job = dict(f.slot_job)
        slot_live = dict(f.slot_live)
        evs = list(f.events)[-5:]
    lines = []
    lines.append(f"{B}FLEET-COMPRESSED-PUSH{N}  {time.strftime('%H:%M:%S')}"
                 f"  elapsed {hms(now-f.t0)}  remote-upload={'on' if not o.no_remote_upload else 'off'}")
    lines.append("── slots " + "─" * 56)
    for node in NODES:
        v = slot_job.get(node)
        if v is None:
            lines.append(f" [{node:6}] {DIM}idle{N}")
            continue
        sp = v.stage or ("push" if v.state == Ver.PUSH else "-")
        if sp == "push":
            pct = v.push_pct
            extra = f"{mib(v.push_done)}/{mib(v.push_total)}"
        elif sp == "upx":
            pct = v.stage_pct.get("upx", 0.0)
            extra = v.upx_live or ""
        elif sp == "upload":
            pct = v.stage_pct.get("upload", 0.0)
            extra = f"{mib(v.size_out * pct / 100)}/{mib(v.size_out)}" if v.size_out else ""
        else:
            pct = v.stage_progress(sp, now) if v.t_state else 0.0
            extra = ""
        live = slot_live.get(node, "")
        lines.append(f" [{node:6}] ▶ {v.ver:8} {sp:6} [{bar(pct)}] {pct:5.1f}%  {extra} {DIM}{live}{N}")
    lines.append("── versions " + "─" * 52)
    order = sorted(vers, key=lambda x: x.ver)
    for v in order:
        if v.state == Ver.DONE:
            lines.append(f" {G}✔{N} {v.ver:8} {v.upx_in} → {v.upx_out} "
                         f"{G}({v.upx_ratio}%){N} {v.upx_fmt:12} {hms((v.t_done or now)-(v.t_start or now))}")
        elif v.state == Ver.FAILED:
            lines.append(f" {R}✖{N} {v.ver:8} 失败 {v.err or ''} ({v.attempt} 次)")
        elif v.state == Ver.SKIPPED:
            lines.append(f" {DIM}○ {v.ver:8} 跳过(无包源){N}")
        elif v.node:
            node = v.node or "-"
            lines.append(f" {Y}▶{N} {v.ver:8} [{bar(v.pct, 30)}] {v.pct:5.1f}%  {DIM}on {node} "
                         f"({v.attempt}/{o.attempts}){N}")
        else:
            lines.append(f" {DIM}◌ {v.ver:8} 排队{N}")
    total = sum(v.pct for v in vers) / max(1, len(vers))
    nd = sum(1 for v in vers if v.state == Ver.DONE)
    nr = sum(1 for v in vers if v.node)
    nf = sum(1 for v in vers if v.state == Ver.FAILED)
    lines.append("── total " + "─" * 56)
    lines.append(f" {B}TOTAL{N} [{bar(total, 40)}] {total:5.1f}%   "
                 f"{G}✔{nd}{N} {Y}▶{nr}{N} {DIM}◌{len(vers)-nd-nr-nf}{N}"
                 + (f" {R}✖{nf}{N}" if nf else ""))
    if evs:
        lines.append("── events " + "─" * 55)
        for ts, t in evs:
            lines.append(f"  {DIM}{time.strftime('%H:%M:%S', time.localtime(ts))}{N} {t}")
    lines.append(f" {DIM}[Ctrl-C] 优雅收尾 · 完整流 → .omo/evidence/fleet/{N}")
    out.write(CLR + "\n".join(lines) + "\n")
    out.flush()


def release_crosscheck(f, tag):
    """gh release view 对账: DONE 资产存在且尺寸与节点报告一致"""
    r = subprocess.run(["gh", "release", "view", tag, "--json", "assets", "--jq",
                        '.assets[] | .name + " " + (.size|tostring)'],
                       capture_output=True, text=True, cwd=REPO_ROOT)
    assets = {}
    for line in r.stdout.splitlines():
        parts = line.rsplit(" ", 1)
        if len(parts) == 2 and parts[1].isdigit():
            assets[parts[0]] = int(parts[1])
    bad = 0
    with f.lock:
        done = [v for v in f.vers.values() if v.state == Ver.DONE]
    for v in done:
        got = assets.get(v.asset)
        if got is None:
            print(f"  ✖ {v.ver} 资产缺失于 release"); bad += 1
        elif v.size_out and got != v.size_out:
            print(f"  ✖ {v.ver} 尺寸不一致 release={got} node={v.size_out}"); bad += 1
        else:
            print(f"  ✔ {v.ver} {v.asset} {mib(got or 0)}")
    return bad


def final_table(f, o):
    with f.lock:
        vers = sorted(f.vers.values(), key=lambda x: x.ver)
    print("\n" + B + "══ 最终表 ══" + N)
    for v in vers:
        if v.state == Ver.DONE:
            print(f" ✔ {v.ver:8} {v.asset}  {mib(v.size_out)}  sha={v.sha_node[:16]}…"
                  f"  upx {v.upx_in}→{v.upx_out} ({v.upx_ratio}%) {v.upx_fmt}")
        elif v.state == Ver.FAILED:
            print(f" ✖ {v.ver:8} 失败: {v.err}")
        elif v.state == Ver.SKIPPED:
            print(f" ○ {v.ver:8} 跳过")
    nd = sum(1 for v in vers if v.state == Ver.DONE)
    total = len(vers)
    print(f"\n{G}FLEET-COMPRESSED-OK {nd}/{total}{N}"
          if nd == total else f"\n{Y}FLEET-COMPRESSED-PARTIAL {nd}/{total}{N}")
    log(f"VERDICT FLEET-COMPRESSED-{'OK' if nd == total else 'PARTIAL'} {nd}/{total}")

# ───────────────────── main ─────────────────────


def discover(include_artifacts):
    vers = {}
    for fn in sorted(os.listdir(PKG_DIR)) if os.path.isdir(PKG_DIR) else []:
        m = re.match(r"^opencode-([\d.]+)-1-aarch64\.pkg\.tar\.xz$", fn)
        if m:
            v = m.group(1)
            vers[v] = Ver(v, os.path.join(PKG_DIR, fn), ASSET_TMPL.format(ver=v))
    if include_artifacts and os.path.isdir(os.path.join(REPO_ROOT, "artifacts", "transplant")):
        for d in sorted(os.listdir(os.path.join(REPO_ROOT, "artifacts", "transplant"))):
            if re.match(r"^[\d.]+$", d) and d not in vers:
                sv = Ver(d, "", ASSET_TMPL.format(ver=d))
                sv.state = Ver.SKIPPED          # 无包源, 占位提示
                vers[d] = sv
    return vers


def _seed(hostspec):
    """手机侧: 把全部包 + 本脚本投送到目标机 ~/opc-fleet/, 逐文件自建进度条"""
    pkgs = [f for f in sorted(os.listdir(PKG_DIR))
            if re.match(r"^opencode-[\d.]+-1-aarch64\.pkg\.tar\.xz$", f)] \
        if os.path.isdir(PKG_DIR) else []
    if not pkgs:
        print(f"包源目录无匹配: {PKG_DIR}"); return 1
    total = sum(os.path.getsize(os.path.join(PKG_DIR, f)) for f in pkgs)
    print(f"SEED → {hostspec}  文件 {len(pkgs)}+1  总量 {mib(total)}")
    jobs = [(f, os.path.join(PKG_DIR, f)) for f in pkgs]
    jobs.append(("fleet-push.py", os.path.abspath(__file__)))
    ok = 0
    for name, path in jobs:
        dest = "~/opc-fleet/inbox/" if name != "fleet-push.py" else "~/opc-fleet/"
        size = os.path.getsize(path)
        cmd = (f"{hostspec} 'mkdir -p ~/opc-fleet/inbox && cat > {dest}{name}'")
        proc = subprocess.Popen(cmd, shell=True, stdin=subprocess.PIPE,
                                stdout=subprocess.DEVNULL,
                                stderr=subprocess.PIPE)
        sent = 0
        try:
            with open(path, "rb") as f, proc.stdin as w:
                while True:
                    chunk = f.read(1048576)
                    if not chunk:
                        break
                    w.write(chunk); sent += len(chunk)
                    pct = 100.0 * sent / size
                    sys.stdout.write(f"\r  {name:44} [{bar(pct)}] {pct:5.1f}% "
                                     f"{mib(sent)}/{mib(size)}")
                    sys.stdout.flush()
            proc.stdin.close()
            rc = proc.wait(timeout=600)
        except Exception as e:
            rc = -1; print(f"\r  {name} 异常 {e}")
        print()  # 换行
        if rc == 0:
            ok += 1
        else:
            err = (proc.stderr.read() or b"").decode("utf-8", "replace").strip()[:120] \
                if proc.stderr else ""
            print(f"  ✖ {name} rc={rc} {err}")
    script_ok = any(n == "fleet-push.py" for n, _ in jobs[:ok]) or ok == len(jobs)
    print(f"\nSEED-DONE {ok}/{len(jobs)}")
    if ok == len(jobs):
        print("目标机执行:\n"
              "  cd ~/opc-fleet && python3 fleet-push.py --plan\n"
              "  (可选第二槽) FLEET_NODES='local,miao2=ssh <miao2>' \\n"
              "  正式: python3 fleet-push.py")
    return 0 if ok == len(jobs) else 2


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", metavar="HOSTSPEC",
                    help="手机侧投送: 如 'ssh miao@host' 或 'sshpass -p 0 ssh miao@host'")
    ap.add_argument("--plan", action="store_true")
    ap.add_argument("--dry-run", type=int, metavar="SEC")
    ap.add_argument("--tag", default=RELEASE_TAG)
    ap.add_argument("--versions", nargs="*")
    ap.add_argument("--attempts", type=int, default=MAX_ATTEMPTS)
    ap.add_argument("--include-artifacts", action="store_true")
    ap.add_argument("--no-remote-upload", action="store_true")
    ap.add_argument("--verify-download", action="store_true")
    ap.add_argument("--no-clean", dest="clean", action="store_false", default=True)
    ap.add_argument("--repo", default="Hope2333/opencode-termux",
                    help="节点上无 gh repo 上下文时的显式仓库")
    o = ap.parse_args()
    o.no_remote_upload = o.no_remote_upload

    if o.seed:
        return _seed(o.seed)

    f = Fleet()
    f.vers = discover(o.include_artifacts)
    if o.versions:
        f.vers = {k: v for k, v in f.vers.items() if k in o.versions}
    f.repo = o.repo
    if REPO_ROOT:
        try:
            r = subprocess.run(["gh", "repo", "view", "--json", "nameWithOwner",
                                "-q", ".nameWithOwner"], capture_output=True,
                               text=True, cwd=REPO_ROOT)
            if r.returncode == 0 and r.stdout.strip():
                f.repo = r.stdout.strip()
        except Exception:
            pass
    if o.plan:
        print(f"repo={f.repo} tag={o.tag}")
        for v in sorted(f.vers.values(), key=lambda x: x.ver):
            src = "pkg" if v.pkg else "SKIP(无包源)"
            print(f"  {v.ver:8} ← {src:14} → {v.asset}")
        for n, c in NODES.items():
            print(f"  slot {n:6} {c or '(local)'}")
        print(f"  flow: push(10) → untar(5) → upx(45,原生进度聚合) → xz9(15) "
              f"→ upload(25,{'节点直传' if not o.no_remote_upload else '本机回传'})")
        return 0
    if o.dry_run:
        import random
        for i, v in enumerate(sorted(f.vers.values(), key=lambda x: x.ver)):
            v.upx_in, v.upx_out, v.upx_ratio = 179807785, 51891796, "28.86"
            v.upx_fmt = "linux/elf64"
            if i % 3 == 0:
                v.state, v.node, v.pct, v.stage = Ver.COMPUTE, list(NODES)[i % 3], random.random()*80, "upx"
                v.stage_pct["upx"] = random.random()*90
                v.upx_live = "2/5 37.7%"
            elif i % 3 == 1:
                v.state, v.node, v.pct, v.stage = Ver.UPLOAD_WAIT, list(NODES)[i % 3], 60+random.random()*30, "upload"
                v.stage_pct["upload"] = random.random()*80
                v.size_out = 51891796
            else:
                v.state, v.t_start, v.t_done = Ver.DONE, f.t0-600, f.t0
        try:
            sys.stdout.write(ALT_IN + HIDE_C)
            t_end = time.time() + o.dry_run
            while time.time() < t_end:
                for v in f.vers.values():
                    if v.state in (Ver.COMPUTE, Ver.UPLOAD_WAIT):
                        v.recompute()
                        if v.stage == "upx":
                            v.stage_pct["upx"] = min(100, v.stage_pct.get("upx", 0)+random.random()*3)
                render(f, o, sys.stdout)
                time.sleep(0.25)
        finally:
            sys.stdout.write(SHOW_C + ALT_OUT)
        print("(dry-run 预览结束, 未执行任何作业)")
        return 0

    if not f.vers:
        print("未发现任何版本包源 (packing/pacman)"); return 1
    log(f"START fleet-push v3 tag={o.tag} repo={f.repo} "
        f"versions={len(f.vers)} remote_upload={not o.no_remote_upload}")

    sched = Scheduler(f, o)
    stopped = threading.Event()

    def on_sig(_sig, _frm):
        if not stopped.is_set():
            stopped.set()
            f.ev("Ctrl-C: 优雅收尾(等待在跑作业)")

    signal.signal(signal.SIGINT, on_sig)

    sys.stdout.write(ALT_IN + HIDE_C)
    try:
        last_draw = 0.0
        while not (stopped.is_set() and not sched.jobs):
            now = time.time()
            sched.poll()
            if not stopped.is_set():
                for node, cmd in NODES.items():
                    with f.lock:
                        busy = node in f.slot_job
                    if busy:
                        continue
                    if not f.health_ok(node, cmd):
                        continue
                    if node == "local":
                        # 本机槽: 优先 push 之外的计算(包已在本地)
                        sched.assign("local", node, None, "compute")
                    else:
                        sched.assign(node, node, cmd, "push")
            if now - last_draw > 0.3:
                with f.lock:
                    for s, v in f.slot_job.items():
                        f.slot_live[s] = v.live or ""
                render(f, o, sys.stdout)
                last_draw = now
            time.sleep(0.15)
    finally:
        sys.stdout.write(SHOW_C + ALT_OUT)

    if not o.no_remote_upload:
        print("—— release 对账（尺寸核对）")
        release_crosscheck(f, o.tag)
    final_table(f, o)
    if o.verify_download:
        print("—— verify-download: 逐资产回下载校验（gh release download）")
        okn = 0
        for v in sorted(f.vers.values(), key=lambda x: x.ver):
            if v.state != Ver.DONE:
                continue
            tmp = os.path.join("/data/data/com.termux/files/usr/tmp",
                               f"fleet-verify-{v.ver}.xz")
            r = subprocess.run(["gh", "release", "download", o.tag, "-p", v.asset,
                                "-O", tmp, "--clobber"], capture_output=True, text=True)
            if r.returncode != 0:
                print(f"  ✖ {v.ver} 下载失败"); continue
            import hashlib
            h = hashlib.sha256()
            with open(tmp, "rb") as fh:
                for chunk in iter(lambda: fh.read(1 << 20), b""):
                    h.update(chunk)
            match = (h.hexdigest() == (v.sha_node or ""))
            print(f"  {'✔' if match else '✖'} {v.ver} sha{'一致' if match else '不一致'}")
            okn += match
            os.unlink(tmp)
        print(f"verify: {okn} 资产回验通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
