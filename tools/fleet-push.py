#!/usr/bin/env python3
"""fleet-push.py — 三节点 fleet 压缩推送调度器（PTY 管理 + 屏幕流归整 + 多行进度条）

用法:
    python3 tools/fleet-push.py [--plan] [--dry-run N] [--tag TAG]
                                [--versions v1 v2 ...] [--attempts N]
                                [--include-artifacts] [--no-clean]

    --plan              只打印作业图与将要执行的命令，不跑任何东西（安全预览）
    --dry-run N         用模拟数据渲染 N 秒仪表盘后退出（UI 预览，零副作用）
    --tag TAG           gh release 上传目标 tag（默认 RELEASE_TAG）
    --versions          只处理列出的版本；默认自动发现 native 包（Push 范围）
    --include-artifacts 额外纳入仅有 revived 工件的旧版本（无包源，走 xz 预压）

流程（每版本，双源模式）:
    [pkg 模式]      源 = 已构建的 native 包（pacman .pkg.tar.xz 优先 / .deb 回落）
                    包本身就是压缩容器 → 直接推到节点 → 节点解包取 bin/opencode
                    → upx --best → xz -9 → out.xz + SHA   （跳过本地 xz 预压）
    [artifact 模式] 源 = artifacts/transplant/<ver>/opencode-native-revived
                    local xz -9 预压 → 推 in.elf.xz → 节点解压 → upx → …
    节点: local / miao1 / miao2 三槽抢占, 失败换节点重试
    收尾: fetch → 校验 SHA → gh release upload --clobber → sync 钩子 → 记档

PTY 用途: 计算与收尾作业的 stdout/stderr 挂到伪终端从端，
upx/xz/gh 的 \\r 刷新型进度行被归整为「live:」瞬态行，
普通行进环形缓冲（完成时落盘 .omo/evidence/fleet/<ver>-<kind>.log）。

进度条: 各阶段按权重×(耗时/预期ETA) 估算，阶段 done 标记直接置满。
零第三方依赖（纯 stdlib）。Ctrl-C 优雅收尾。
"""

import argparse
import base64
import glob as globmod
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
from typing import Optional

# ─────────────────────────── 配置（按需修改） ───────────────────────────

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ART_DIR = os.path.join(REPO_ROOT, "artifacts", "transplant")
OUT_DIR = os.path.join(REPO_ROOT, "packing", "fleet")     # 产物与中转
EVID_DIR = os.path.join(REPO_ROOT, ".omo", "evidence", "fleet")

RELEASE_TAG = "Push260903"          # gh release 上传目标
ASSET_TMPL = "opencode-native-{ver}-upx.xz"

# native 包搜索模式（按优先级；剔除 glibc/standalone/compressed 命名）
PKG_PATTERNS = [
    "packing/pacman/opencode-{ver}-*aarch64.pkg.tar.xz",
    "packing/dpkg-native/opencode_{ver}_aarch64.deb",
    "packing/dpkg-native/opencode-native_{ver}_aarch64.deb",
]
# 默认版本范围（Push260903 = 13 版本）；--versions 可覆盖
PUSH_RANGE = ("1.18.15", "1.18.27")

# 计算节点: None=本机, 其余=ssh 目标（别名或 user@host）
NODES: dict[str, Optional[str]] = {
    "local":  None,
    "miao1":  "ssh miao1",
    "miao2":  "ssh miao2",
}
RDIR = "~/opc-fleet/{ver}"          # 远端工作目录模板
CLEAN_REMOTE = True                 # 成功后清理远端目录

MAX_ATTEMPTS = 3                    # 每版本计算失败重试上限（换节点计一次）
SSH_TIMEOUT = 8                     # 节点健康检查/传输超时(秒)
HEALTH_TTL = 60                     # 健康检查缓存(秒)

# 阶段预期耗时(秒) —— 决定进度条平滑度，按机器实况调
STAGE_ETA: dict[str, int] = {
    "xz9in": 240, "unpack": 40, "upx": 480, "xz9": 150,
    "fetch": 120, "verify": 20, "upload": 120, "sync": 30,
}
COMPUTE_WEIGHT, FINAL_WEIGHT = 0.75, 0.25

# ─────────────────────────── ANSI ───────────────────────────

ALT_IN, ALT_OUT = "\x1b[?1049h", "\x1b[?1049l"
HIDE_C, SHOW_C = "\x1b[?25l", "\x1b[?25h"
CLR = "\x1b[2J\x1b[H"
DIM, B, G, Y, R, N = "\x1b[2m", "\x1b[1m", "\x1b[32m", "\x1b[33m", "\x1b[31m", "\x1b[0m"


def bar(pct: float, width: int = 22) -> str:
    n = max(0, min(width, int(round(width * pct / 100.0))))
    return "█" * n + "░" * (width - n)


def hms(sec: float) -> str:
    sec = int(sec)
    return f"{sec//3600:02d}:{(sec%3600)//60:02d}:{sec%60:02d}"

# ─────────────────────────── 状态模型 ───────────────────────────


def _verkey(v: str):
    return tuple(int(x) for x in v.split("."))


class Ver:
    PENDING, PRESTAGE, COMPUTE, FINALIZE = "pending", "prestage", "compute", "finalize"
    DONE, FAILED, SKIPPED = "done", "failed", "skipped"

    def __init__(self, ver: str) -> None:
        self.ver = ver
        self.state: str = Ver.PENDING
        self.mode: str = "pkg"              # "pkg" | "artifact"
        self.src_pkg: Optional[str] = None  # pkg 模式的包路径
        self.src_kind: str = "pacman"       # pacman | deb
        self.revived: Optional[str] = None  # artifact 模式的 ELF 路径
        self.attempt: int = 0
        self.node: Optional[str] = None
        self.stage: Optional[str] = None
        self.stage_pct: dict[str, float] = {}
        self.t_start: Optional[float] = None
        self.t_done: Optional[float] = None
        self.sha_node: Optional[str] = None
        self.asset: Optional[str] = None
        self.err: Optional[str] = None
        self.in_xz = os.path.join(OUT_DIR, ver, "in.elf.xz")
        self.out_xz = os.path.join(OUT_DIR, ver, ASSET_TMPL.format(ver=ver))
        self.rdir = RDIR.format(ver=ver)

    # 计算槽 stdin 的容器文件
    def payload_file(self) -> str:
        if self.mode == "pkg":
            assert self.src_pkg is not None
            return self.src_pkg
        return self.in_xz

    def payload_kind(self) -> str:
        if self.mode == "pkg":
            return self.src_kind
        return "xz"

    def in_pending_hint(self) -> bool:
        return self.mode == "artifact" and not os.path.exists(self.in_xz)

    def stage_progress(self, stage: str, now: Optional[float] = None) -> float:
        """阶段进度: done 标记置满; 否则按 elapsed/ETA"""
        if self.stage_pct.get(stage, 0) >= 100:
            return 100.0
        if self.t_start is None:
            return 0.0
        now = now if now is not None else time.time()
        eta = STAGE_ETA.get(stage, 120)
        return min(95.0, 100.0 * (now - self.t_start) / max(1, eta))

    def overall_pct(self) -> float:
        comp = ["unpack", "upx", "xz9"]
        fin = ["fetch", "verify", "upload", "sync"]
        if self.state in (Ver.PENDING, Ver.PRESTAGE):
            if self.mode == "pkg":
                return 2.0
            return 5.0 * self.stage_progress("xz9in") / 100.0
        if self.state == Ver.COMPUTE:
            return 2.0 + 98.0 * COMPUTE_WEIGHT * sum(
                self.stage_progress(s) for s in comp) / (100.0 * len(comp))
        if self.state == Ver.FINALIZE:
            return 2.0 + 98.0 * (COMPUTE_WEIGHT + FINAL_WEIGHT * sum(
                self.stage_progress(s) for s in fin) / (100.0 * len(fin)))
        return 100.0


class Fleet:
    def __init__(self) -> None:
        self.lock = threading.RLock()
        self.vers: dict[str, Ver] = {}
        self.slot_job: dict[str, Optional["PtyJob"]] = {}
        self.slot_live: dict[str, str] = {}
        self.events: deque[tuple[float, str]] = deque(maxlen=200)
        self.health: dict[str, tuple[bool, float]] = {}
        self.stop = threading.Event()
        self.t0 = time.time()

    def ev(self, text: str) -> None:
        with self.lock:
            self.events.append((time.time(), text))
        log(f"EVT {text}")

    def health_ok(self, node: str, node_cmd: str) -> bool:
        with self.lock:
            hit = self.health.get(node)
            if hit is not None and time.time() - hit[1] < HEALTH_TTL:
                return hit[0]
        ok = False
        try:
            rc = subprocess.run(shlex.split(node_cmd) + ["true"],
                                timeout=SSH_TIMEOUT,
                                stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL).returncode
            ok = (rc == 0)
        except Exception:
            ok = False
        with self.lock:
            self.health[node] = (ok, time.time())
        if not ok:
            self.ev(f"{node} 不可达(ssh timeout={SSH_TIMEOUT}s)")
        return ok

# ─────────────────────────── 证据日志 ───────────────────────────

_log_lock = threading.Lock()
LOG_PATH = os.path.join(REPO_ROOT, ".omo", "evidence",
                        "task-fleet-compressed-push.log")


def log(line: str) -> None:
    os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)
    with _log_lock:
        with open(LOG_PATH, "a", encoding="utf-8") as f:
            f.write(time.strftime("[%H:%M:%S] ") + line + "\n")

# ─────────────────────────── PTY 作业 ───────────────────────────


class PtyJob:
    """把命令挂上伪终端跑; 读者线程归整屏幕流。
    start() 之前 proc/master 为 None——内部访问经 alive()/live()/kill() 或
    _reader(master, proc) 参数化，杜绝 None 解引用。"""

    def __init__(self, fleet: Fleet, ver: Ver, slot: str, argv: list[str],
                 stdin_file: Optional[str] = None, cwd: Optional[str] = None) -> None:
        self.f, self.v, self.slot = fleet, ver, slot
        self.argv, self.stdin_file, self.cwd = argv, stdin_file, cwd
        self.proc: Optional[subprocess.Popen] = None
        self.master: Optional[int] = None
        self.raw: deque[str] = deque(maxlen=500)
        self.transient = ""
        self.rc: Optional[int] = None
        self.done = threading.Event()

    # --- 行处理 ---
    def _on_line(self, line: str) -> None:
        line = line.rstrip()
        if not line:
            return
        self.raw.append(line)
        v = self.v
        m = re.match(r"^#S (\S+)", line)
        if m:
            with self.f.lock:
                v.stage, v.t_start = m.group(1), time.time()
            self.f.ev(f"{self.slot}: {v.ver} 阶段→ {v.stage}")
            return
        m = re.match(r"^#D (\S+)", line)
        if m:
            with self.f.lock:
                v.stage_pct[m.group(1)] = 100.0
                if v.stage == m.group(1):
                    v.stage = None
            return
        m = re.match(r"^#SHA ([0-9a-f]{64})", line)
        if m:
            with self.f.lock:
                v.sha_node = m.group(1)
            return
        m = re.match(r"^#P (\d+)(?:\s+(.*))?$", line)
        if m:
            with self.f.lock:
                v.stage_pct["__manual__"] = float(m.group(1))

    def _feed(self, chunk: str) -> None:
        for part in chunk.replace("\r\n", "\n").split("\n"):
            if "\r" in part:
                segs = part.split("\r")
                self.transient = segs[-1]
                for s in segs[:-1]:
                    if s.strip():
                        self._on_line(s)
            elif part:
                self._on_line(part)
                self.transient = ""

    # --- 读者线程（master/proc 以参数传入，杜绝 None 解引用） ---
    def _reader(self, master: int, proc: subprocess.Popen) -> None:
        while True:
            try:
                r, _, _ = select.select([master], [], [], 0.5)
            except (OSError, ValueError):
                break
            if r:
                try:
                    data = os.read(master, 65536)
                except OSError:            # EIO: 子进程退出
                    break
                if not data:
                    break
                self._feed(data.decode("utf-8", "replace"))
            if proc.poll() is not None and not r:
                try:
                    while select.select([master], [], [], 0.1)[0]:
                        data = os.read(master, 65536)
                        if not data:
                            break
                        self._feed(data.decode("utf-8", "replace"))
                except OSError:
                    pass
                break
        try:
            self.rc = proc.wait(timeout=10)
        except Exception:
            self.rc = proc.returncode
        self.done.set()

    # --- 启动 ---
    def start(self) -> "PtyJob":
        master, slave = pty.openpty()
        stdin: Optional[int] = None
        if self.stdin_file:
            stdin = os.open(self.stdin_file, os.O_RDONLY)
        self.proc = subprocess.Popen(
            self.argv, stdin=stdin, stdout=slave, stderr=slave,
            cwd=self.cwd or REPO_ROOT, preexec_fn=os.setsid, close_fds=True)
        os.close(slave)
        if stdin is not None:
            os.close(stdin)                # 子进程已 dup, 父端即关
        proc = self.proc
        assert proc is not None
        threading.Thread(target=self._reader, args=(master, proc),
                         daemon=True, name=f"rd-{self.v.ver}").start()
        self.master = master
        return self

    # --- 对外只读接口（内部处理 None） ---
    def alive(self) -> bool:
        return self.proc is not None and self.proc.poll() is None

    def live(self) -> str:
        return self.transient.strip()

    def kill(self) -> None:
        if self.proc is not None:
            try:
                self.proc.terminate()
            except Exception:
                pass

# ─────────────────────────── 作业命令构造 ───────────────────────────

COMPUTE_SH = """set -euo pipefail
R="$1"; KIND="${2:-xz}"; cd "$R"
say(){ printf '#%s\\n' "$*"; }
say "S unpack"
case "$KIND" in
  xz)     xz -dc payload.src > work.elf ;;
  pacman) tar -xJf payload.src -O usr/bin/opencode > work.elf 2>/dev/null \\
          || tar -xJf payload.src -O --wildcards '*bin/opencode' > work.elf ;;
  deb)    ar p payload.src data.tar.xz | xz -dc \\
          | tar -xO --wildcards '*usr/bin/opencode' > work.elf ;;
  *) echo "unknown kind: $KIND" >&2; exit 64 ;;
esac
test -s work.elf
say "D unpack"
say "S upx"
upx --best -o packed.elf work.elf
say "D upx"
say "S xz9"; xz -9 -c packed.elf > out.xz; say "D xz9"
printf '#SHA %s\\n' "$(sha256sum out.xz | cut -d' ' -f1)"
"""

FLEET_SYNC_CMD = os.environ.get("FLEET_SYNC_CMD", ":")


def cmd_prestage(v: Ver) -> list[str]:
    os.makedirs(os.path.dirname(v.in_xz), exist_ok=True)
    return ["bash", "-o", "pipefail", "-c",
            f'printf "#S xz9in\\n"; xz -9 -c {shlex.quote(v.revived or "")} > '
            f'{shlex.quote(v.in_xz)}; printf "#D xz9in\\n"']


def cmd_compute(node_cmd: Optional[str], v: Ver) -> list[str]:
    r = v.rdir
    kind = v.payload_kind()
    b64 = base64.b64encode(COMPUTE_SH.encode()).decode()
    inner = (f"mkdir -p {r} && cat > {r}/payload.src && "
             f"echo {b64} | base64 -d > {r}/job.sh && bash {r}/job.sh {r} {kind}")
    if node_cmd is None:
        return ["bash", "-c", inner]
    return ["bash", "-c", f"{node_cmd} {shlex.quote(inner)}"]


def cmd_fetch(node_cmd: str, v: Ver) -> list[str]:
    return ["bash", "-c",
            f"{node_cmd} 'cat {v.rdir}/out.xz' > {shlex.quote(v.out_xz + '.part')}"]


def cmd_finalize(v: Ver, tag: str) -> list[str]:
    v.asset = ASSET_TMPL.format(ver=v.ver)
    return ["bash", "-o", "pipefail", "-c", f"""
set -e
printf '#S verify\\n'
sha_node=$(sha256sum {shlex.quote(v.out_xz + '.part')} | cut -d' ' -f1)
if [ "$sha_node" != "{v.sha_node or ''}" ]; then
  echo "SHA MISMATCH node={v.sha_node} local=$sha_node" >&2; exit 42
fi
mv {shlex.quote(v.out_xz + '.part')} {shlex.quote(v.out_xz)}
printf '#D verify\\n'
printf '#S upload\\n'
gh release upload {shlex.quote(tag)} {shlex.quote(v.out_xz)} --clobber
printf '#D upload\\n'
printf '#S sync\\n'
eval {shlex.quote(FLEET_SYNC_CMD)}
printf '#D sync\\n'
printf '#DONE {v.ver}\\n'
"""]

# ─────────────────────────── 调度器 ───────────────────────────


def pick_prestage(fleet: Fleet) -> Optional[Ver]:
    """仅 artifact 模式需要本地 xz 预压；pkg 模式直接进计算队列"""
    with fleet.lock:
        for v in fleet.vers.values():
            if v.state == Ver.PENDING and v.mode == "artifact" \
                    and v.revived is not None and os.path.exists(v.revived) \
                    and not os.path.exists(v.in_xz):
                return v
    return None


def pick_compute(fleet: Fleet) -> Optional[Ver]:
    with fleet.lock:
        for v in fleet.vers.values():
            if v.state == Ver.PENDING and v.attempt < MAX_ATTEMPTS:
                if v.mode == "pkg" and v.src_pkg and os.path.exists(v.src_pkg):
                    return v
                if v.mode == "artifact" and os.path.exists(v.in_xz):
                    return v
    return None


def pick_finalize(fleet: Fleet) -> Optional[Ver]:
    with fleet.lock:
        for v in fleet.vers.values():
            if v.state == Ver.COMPUTE and v.sha_node:
                return v
    return None


def _dump_job(v: Ver, kind: str, job: PtyJob) -> None:
    os.makedirs(EVID_DIR, exist_ok=True)
    path = os.path.join(EVID_DIR, f"{v.ver}-{kind}.log")
    try:
        with open(path, "w", encoding="utf-8") as f:
            for ln in job.raw:
                f.write(ln + "\n")
            if job.transient.strip():
                f.write("live: " + job.transient + "\n")
    except Exception:
        pass


def slot_worker(fleet: Fleet, slot: str, node_cmd: Optional[str]) -> None:
    """计算槽: prestage 优先(仅 local/artifact 模式), 其次 compute"""
    while not fleet.stop.is_set():
        if slot == "local":
            v = pick_prestage(fleet)
            if v is not None:
                with fleet.lock:
                    v.state, v.node = Ver.PRESTAGE, slot
                fleet.ev(f"local 预压 {v.ver}")
                job = PtyJob(fleet, v, slot, cmd_prestage(v))
                with fleet.lock:
                    fleet.slot_job[slot] = job
                job.start()
                job.done.wait()
                if job.rc == 0:
                    with fleet.lock:
                        v.stage_pct["xz9in"] = 100.0
                        v.state, v.node = Ver.PENDING, None
                    try:
                        mb = os.path.getsize(v.in_xz) // (2 * 1024 * 1024)
                    except OSError:
                        mb = -1
                    fleet.ev(f"预压完成 {v.ver} ({mb}MiB)")
                else:
                    with fleet.lock:
                        v.state, v.node = Ver.PENDING, None
                    fleet.ev(f"预压失败 {v.ver} rc={job.rc}")
                _dump_job(v, "prestage", job)
                continue
        v = pick_compute(fleet)
        if v is None:
            time.sleep(3)
            continue
        if node_cmd is not None and not fleet.health_ok(slot, node_cmd):
            time.sleep(10)
            continue
        with fleet.lock:
            v.state, v.node, v.attempt = Ver.COMPUTE, slot, v.attempt + 1
            v.stage, v.t_start, v.stage_pct = None, time.time(), {}
        fleet.ev(f"{slot} 计算 {v.ver} [{v.mode}/{v.payload_kind()}] "
                 f"(attempt {v.attempt}/{MAX_ATTEMPTS})")
        job = PtyJob(fleet, v, slot, cmd_compute(node_cmd, v),
                     stdin_file=v.payload_file())
        with fleet.lock:
            fleet.slot_job[slot] = job
        job.start()
        job.done.wait()
        rc, sha = job.rc, v.sha_node
        if rc == 0 and sha:
            fleet.ev(f"{slot} 计算完成 {v.ver} sha={sha[:12]} (待收尾)")
        else:
            exhausted = v.attempt >= MAX_ATTEMPTS
            with fleet.lock:
                if exhausted:
                    v.state, v.err = Ver.FAILED, f"compute rc={rc} (重试耗尽)"
                else:
                    v.state, v.node, v.err = Ver.PENDING, None, f"compute rc={rc}"
            fleet.ev(f"计算失败 {v.ver} on {slot} rc={rc}"
                     + (" → 重试耗尽" if exhausted else " → 换节点重试"))
        _dump_job(v, f"compute-{slot}", job)


def finalizer_worker(fleet: Fleet, tag: str) -> None:
    """收尾线程: fetch → verify → upload → sync → 记档"""
    while not fleet.stop.is_set():
        v = pick_finalize(fleet)
        if v is None:
            time.sleep(3)
            continue
        node = v.node
        node_cmd = NODES.get(node) if node is not None else None
        with fleet.lock:
            v.state, v.stage, v.t_start = Ver.FINALIZE, "fetch", time.time()
            v.stage_pct = {}
        fleet.ev(f"finalizer 认领 {v.ver} (from {node})")

        # 1) fetch（远端 → 本地）
        if node is not None and node_cmd is not None:
            os.makedirs(os.path.dirname(v.out_xz), exist_ok=True)
            fjob = PtyJob(fleet, v, "final", cmd_fetch(node_cmd, v)).start()
            fjob.done.wait()
            _dump_job(v, "fetch", fjob)
            if fjob.rc != 0:
                with fleet.lock:
                    v.state, v.err, v.node = Ver.PENDING, "fetch fail", None
                fleet.ev(f"fetch 失败 {v.ver} → 重新入队")
                continue
        with fleet.lock:
            v.stage_pct["fetch"] = 100.0

        # 2..4) verify + upload + sync —— 本地 PTY 作业
        ljob = PtyJob(fleet, v, "final", cmd_finalize(v, tag)).start()
        ljob.done.wait()
        if ljob.rc == 0 and os.path.exists(v.out_xz):
            with fleet.lock:
                v.state, v.t_done = Ver.DONE, time.time()
            dur = hms((v.t_done or 0) - (v.t_start or 0))
            fleet.ev(f"✔ {v.ver} 上传+同步完成 ({dur})")
        else:
            with fleet.lock:
                v.state, v.err, v.node = Ver.PENDING, f"finalize rc={ljob.rc}", None
            fleet.ev(f"收尾失败 {v.ver} rc={ljob.rc} → 重入队")
        _dump_job(v, "finalize", ljob)

        # 5) 远端清理
        if ljob.rc == 0 and CLEAN_REMOTE and node is not None and node_cmd is not None:
            try:
                subprocess.run(shlex.split(node_cmd) + [f"rm -rf {v.rdir}"],
                               timeout=SSH_TIMEOUT,
                               stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL)
            except Exception:
                pass

# ─────────────────────────── 仪表盘 ───────────────────────────

DISP_W = 100
ICON = {"done": "✔", "failed": "✖", "skipped": "◌", "prestage": "▶",
        "compute": "▶", "finalize": "▶", "pending": "◌"}
COLOR: dict[str, str] = {"done": G, "failed": R, "skipped": DIM, "pending": DIM}


def render(fleet: Fleet, tag: str) -> list[str]:
    now = time.time()
    L: list[str] = []
    L.append(f" {B}FLEET-COMPRESSED-PUSH{N}  tag={tag}  "
             f"elapsed {hms(now - fleet.t0)}  " + time.strftime("%H:%M:%S"))
    L.append(" slots " + "─" * (DISP_W - 8))
    for slot in list(NODES) + ["final"]:
        with fleet.lock:
            job = fleet.slot_job.get(slot)
            live = fleet.slot_live.get(slot, "")
        if job is not None and job.alive():
            v = job.v
            st = v.stage or "…"
            sp = v.stage_progress(st) if v.t_start is not None else 0.0
            L.append(f" [{slot:<6}] {Y}▶{N} {v.ver:<9} {st:<8} {bar(sp, 18)} {sp:5.1f}%"
                     + (f"  {DIM}live:{live[:36]}{N}" if live else ""))
        else:
            L.append(f" [{slot:<6}] {DIM}idle{N}")
    L.append(" versions " + "─" * (DISP_W - 11))
    with fleet.lock:
        vs = sorted(fleet.vers.values(), key=lambda x: _verkey(x.ver))
    for v in vs:
        icon = ICON.get(v.state, "◌")
        col = COLOR.get(v.state, N)
        note = ""
        if v.state == Ver.SKIPPED:
            note = f"{DIM}(缺源工件){N}"
        elif v.state == Ver.PENDING and v.in_pending_hint():
            note = f"{DIM}(待预压){N}"
        elif v.state == Ver.PENDING:
            note = f"{DIM}(队列 attempt {v.attempt}/{MAX_ATTEMPTS}){N}"
        if v.err is not None:
            note += f" {R}{v.err}{N}"
        pct = v.overall_pct()
        L.append(f" {col}{icon}{N} {v.ver:<9} {col}{bar(pct)}{N} {pct:5.1f}%{note}")
    L.append(" events " + "─" * (DISP_W - 9))
    with fleet.lock:
        tail = list(fleet.events)[-5:]
    for ts, txt in tail:
        L.append(f"  {DIM}{time.strftime('%H:%M:%S', time.localtime(ts))}{N} {txt}")
    L.append(f" {DIM}Ctrl-C = 优雅收尾（停止派发, 等在跑作业, 落盘终表）{N}")
    return L


def display_loop(fleet: Fleet, tag: str, stop_ev: threading.Event) -> None:
    sys.stdout.write(ALT_IN + HIDE_C)
    try:
        while not stop_ev.wait(0.25):
            with fleet.lock:
                for slot, job in list(fleet.slot_job.items()):
                    if job is not None:
                        fleet.slot_live[slot] = job.live() if job.alive() else ""
            lines = render(fleet, tag)
            sys.stdout.write(CLR + "\n".join(lines) + "\n")
            sys.stdout.flush()
    finally:
        sys.stdout.write(SHOW_C + ALT_OUT)
        sys.stdout.flush()

# ─────────────────────────── 版本发现 ───────────────────────────

_EXCLUDE_RE = re.compile(r"(glibc|standalone|compressed)", re.I)


def find_native_package(ver: str) -> "tuple[Optional[str], str]":
    """按优先级找 native 包（剔除 glibc/standalone/compressed 命名）"""
    for pat in PKG_PATTERNS:
        for hit in sorted(globmod.glob(os.path.join(REPO_ROOT, pat.format(ver=ver)))):
            base = os.path.basename(hit)
            if _EXCLUDE_RE.search(base):
                continue
            if base.endswith(".pkg.tar.xz"):
                return hit, "pacman"
            if base.endswith(".deb"):
                return hit, "deb"
    return None, ""


def discover(only: Optional[list[str]] = None,
             include_artifacts: bool = False) -> dict[str, Ver]:
    vers: dict[str, Ver] = {}
    # 1) 包源版本（Push 主范围自动发现）
    pkg_vers: dict[str, tuple[Optional[str], str]] = {}
    for pat in PKG_PATTERNS:
        base_pat = pat.split("{ver}")[0]
        d = os.path.join(REPO_ROOT, os.path.dirname(base_pat) or ".")
        for hit in globmod.glob(os.path.join(d, "*aarch64.pkg.tar.xz")) + \
                   globmod.glob(os.path.join(d, "*_aarch64.deb")):
            base = os.path.basename(hit)
            if _EXCLUDE_RE.search(base):
                continue
            m = re.search(r"(\d+\.\d+\.\d+)", base)
            if not m:
                continue
            ver = m.group(1)
            if ver not in pkg_vers:
                pkg_vers[ver] = find_native_package(ver)
    for ver, (pkg, kind) in sorted(pkg_vers.items(), key=lambda kv: _verkey(kv[0])):
        if only is not None and ver not in only:
            continue
        if not only and not include_artifacts:
            lo, hi = (_verkey(x) for x in PUSH_RANGE)
            if not (lo <= _verkey(ver) <= hi):
                continue          # Push 范围外的旧 beta 等不入队
        v = Ver(ver)
        v.mode, v.src_pkg, v.src_kind = "pkg", pkg, kind
        vers[ver] = v
    # 2) artifact 模式（revived 直压；默认不启用，--include-artifacts 打开）
    if include_artifacts or only is not None:
        if os.path.isdir(ART_DIR):
            for d in sorted(os.listdir(ART_DIR)):
                revived = os.path.join(ART_DIR, d, "opencode-native-revived")
                if not os.path.isfile(revived):
                    continue
                if not re.match(r"^\d+\.\d+\.\d+$", d):
                    continue
                if only is not None and d not in only:
                    continue
                if d in vers:
                    continue
                if not include_artifacts:
                    continue
                v = Ver(d)
                v.mode, v.revived = "artifact", revived
                vers[d] = v
    # 3) 显式指定但无源的版本 → SKIPPED 占位
    if only is not None:
        for miss in sorted(set(only) - set(vers)):
            v = Ver(miss)
            v.state, v.err = Ver.SKIPPED, "无包源/无 revived 工件"
            vers[miss] = v
    return vers

# ─────────────────────────── 预览 ───────────────────────────


def plan_print(fleet: Fleet, tag: str) -> None:
    print("== 作业图 ==")
    for v in sorted(fleet.vers.values(), key=lambda x: _verkey(x.ver)):
        if v.state == Ver.SKIPPED:
            print(f"  ✖ {v.ver:<9} SKIPPED ({v.err})")
            continue
        if v.mode == "pkg":
            try:
                mb = os.path.getsize(v.src_pkg or "") // (2 * 1024 * 1024)
            except OSError:
                mb = -1
            print(f"  ○ {v.ver:<9} [pkg/{v.src_kind}] {os.path.basename(v.src_pkg or '')} "
                  f"({mb}MiB) → 节点解包→upx→xz9 → upload {tag}")
        else:
            print(f"  ○ {v.ver:<9} [artifact] {v.revived} → local xz9 → …")
        print(f"      产物: {v.out_xz}")
    dummy = Ver("X.Y.Z")
    dummy.mode, dummy.src_pkg, dummy.src_kind = "pkg", "/dev/null", "pacman"
    print("== 计算命令示例（pkg 模式）==")
    print("  local :", " ".join(cmd_compute(None, dummy))[:150], "…")
    for n, c in NODES.items():
        if c is not None:
            print(f"  {n:<6}:", " ".join(cmd_compute(c, dummy))[:150], "…")
    print("== 远端计算脚本 ==")
    print(COMPUTE_SH)
    print(f"sync 钩子: FLEET_SYNC_CMD={FLEET_SYNC_CMD!r}")

# ─────────────────────────── 主流程 ───────────────────────────


def final_table(fleet: Fleet, tag: str) -> None:
    done_n = fail_n = skip_n = 0
    with fleet.lock:
        vs = sorted(fleet.vers.values(), key=lambda x: _verkey(x.ver))
    log("== FINAL TABLE ==")
    for v in vs:
        if v.state == Ver.DONE:
            done_n += 1
        elif v.state == Ver.FAILED:
            fail_n += 1
        elif v.state == Ver.SKIPPED:
            skip_n += 1
        dur = hms(v.t_done - v.t_start) \
            if v.t_done is not None and v.t_start is not None else "—"
        log(f"  {v.ver:<9} {v.state:<9} {v.overall_pct():5.1f}% {dur} {v.err or ''}")
        print(f"  {v.ver:<9} {v.state:<9} {v.overall_pct():5.1f}% {dur} {v.err or ''}")
    verdict = (f"FLEET-COMPRESSED-OK done={done_n} failed={fail_n} "
               f"skipped={skip_n} total={len(vs)} tag={tag}")
    log(verdict)
    print("\n" + verdict)
    print(f"屏幕流证据: {EVID_DIR}/")
    print(f"主日志: {LOG_PATH}")


def main() -> None:
    global MAX_ATTEMPTS, CLEAN_REMOTE
    ap = argparse.ArgumentParser(description="fleet 压缩推送调度器")
    ap.add_argument("--plan", action="store_true")
    ap.add_argument("--dry-run", type=int, default=0, metavar="SEC")
    ap.add_argument("--tag", default=os.environ.get("FLEET_TAG", RELEASE_TAG))
    ap.add_argument("--versions", nargs="*", default=None)
    ap.add_argument("--attempts", type=int, default=MAX_ATTEMPTS)
    ap.add_argument("--include-artifacts", action="store_true")
    ap.add_argument("--no-clean", action="store_true")
    args = ap.parse_args()

    MAX_ATTEMPTS = max(1, args.attempts)
    if args.no_clean:
        CLEAN_REMOTE = False

    fleet = Fleet()
    fleet.vers = discover(args.versions, args.include_artifacts)
    n_real = sum(1 for v in fleet.vers.values() if v.state != Ver.SKIPPED)
    if not n_real:
        print("未发现任何版本源（native 包或 revived 工件）")
        print("提示: --versions 可显式指定; --include-artifacts 纳入 revived 旧版本")
        sys.exit(1)

    if args.plan:
        plan_print(fleet, args.tag)
        return
    if args.dry_run:
        order = sorted(fleet.vers.values(), key=lambda x: _verkey(x.ver))
        for i, v in enumerate(order):
            v.state = [Ver.PRESTAGE, Ver.COMPUTE, Ver.FINALIZE,
                       Ver.DONE, Ver.PENDING][i % 5]
            v.stage = ["xz9in", "upx", "upload", None, None][i % 5]
            v.t_start = time.time() - 60
            v.attempt = 1
        fleet.ev("dry-run: 模拟 miao1 接力 1.2.9")
        fleet.ev("dry-run: final 上传 1.2.0")
        stop = threading.Event()
        th = threading.Thread(target=display_loop,
                              args=(fleet, args.tag, stop), daemon=True)
        th.start()
        time.sleep(args.dry_run)
        stop.set()
        time.sleep(0.4)
        print("(dry-run 结束，零副作用)")
        return

    log(f"== FLEET START tag={args.tag} versions={len(fleet.vers)} "
        f"include_artifacts={args.include_artifacts} ==")
    fleet.ev(f"启动: {n_real} 个版本 / {len(NODES)} 节点")

    stop_ev = threading.Event()
    for s, c in NODES.items():
        threading.Thread(target=slot_worker, args=(fleet, s, c),
                         daemon=True, name=f"slot-{s}").start()
    threading.Thread(target=finalizer_worker, args=(fleet, args.tag),
                     daemon=True, name="finalizer").start()
    threading.Thread(target=display_loop, args=(fleet, args.tag, stop_ev),
                     daemon=True, name="display").start()

    def on_int(sig: int, frm: object) -> None:
        fleet.ev("收到中断: 停止派发, 等待在跑作业…")
        fleet.stop.set()
    signal.signal(signal.SIGINT, on_int)

    try:
        while True:
            with fleet.lock:
                terminal = all(v.state in (Ver.DONE, Ver.FAILED, Ver.SKIPPED)
                               for v in fleet.vers.values())
            if terminal:
                break
            if fleet.stop.is_set():
                deadline = time.time() + 600
                while time.time() < deadline:
                    with fleet.lock:
                        busy = [v for v in fleet.vers.values()
                                if v.state in (Ver.PRESTAGE, Ver.COMPUTE,
                                               Ver.FINALIZE)]
                    if not busy:
                        break
                    time.sleep(2)
                break
            time.sleep(2)
    finally:
        stop_ev.set()
        time.sleep(0.5)
        final_table(fleet, args.tag)


if __name__ == "__main__":
    main()
