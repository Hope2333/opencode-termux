#!/usr/bin/env python3
"""TUI smoke + embedded-libopentui guard verification (task-tui-common-fix).

Spawns a native opencode binary under a pty (fresh TMPDIR), verifies the TUI
actually renders, exits without a Zig panic, then checks the lazily-extracted
.bun-*.so carries the FFI negative-coordinate guard (swap_tui.has_ffi_guard).

Exit 0 only if: render evidence seen, no crash, guard PASS.

Usage: tui_smoke.py <opencode-binary> [--shim-dir DIR] [--home DIR] [--timeout S]
"""
import argparse
import glob
import os
import pty
import select
import shutil
import signal
import sys
import tempfile
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__))))
from swap_tui import has_ffi_guard  # noqa: E402

CRASH_EXITS = {-11, -6, 134, 139, 136}  # SIGSEGV/SIGABRT via waitpid or shell

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("binary")
    ap.add_argument("--shim-dir", default=None, help="dir containing libopencode-crhandler.so")
    ap.add_argument("--home", default=None, help="HOME to use (warm cache recommended)")
    ap.add_argument("--cwd", default=None, help="working dir for the child")
    ap.add_argument("--timeout", type=float, default=15.0)
    args = ap.parse_args()

    # The child chdirs before exec; every path handed to it must be absolute
    # or the dynamic loader (LD_LIBRARY_PATH) resolves them against the
    # child's cwd and the DT_NEEDED crhandler lookup fails with exit 127.
    binary = os.path.abspath(args.binary)
    tmpdir = tempfile.mkdtemp(prefix="tui-smoke-")
    workdir = os.path.abspath(args.cwd) if args.cwd else tempfile.mkdtemp(prefix="tui-smoke-proj-")
    env = dict(os.environ)
    env["TERM"] = env.get("TERM") or "xterm-256color"
    env["TMPDIR"] = tmpdir
    if args.home:
        env["HOME"] = os.path.abspath(args.home)
    if args.shim_dir:
        env["LD_LIBRARY_PATH"] = os.path.abspath(args.shim_dir)

    pid, fd = pty.fork()
    if pid == 0:  # child
        os.chdir(workdir)
        try:
            os.execve(binary, [binary], env)
        except Exception as e:  # noqa: BLE001
            print(f"execve failed: {e}", file=sys.stderr)
            os._exit(127)

    buf = b""
    deadline = time.time() + args.timeout
    status = None
    while time.time() < deadline:
        r, _, _ = select.select([fd], [], [], 0.5)
        if r:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            buf += chunk
        wpid, st = os.waitpid(pid, os.WNOHANG)
        if wpid == pid:
            status = st
            # drain remaining output
            while True:
                r, _, _ = select.select([fd], [], [], 0.3)
                if not r:
                    break
                try:
                    chunk = os.read(fd, 65536)
                except OSError:
                    break
                if not chunk:
                    break
                buf += chunk
            break
    if status is None:
        # still running after window: the TUI rendered and is interactive -> ok,
        # terminate it cleanly.
        os.kill(pid, signal.SIGTERM)
        try:
            status = os.waitpid(pid, 0)[1]
        except ChildProcessError:
            status = 0
        # give it a moment; if it ignored SIGTERM, SIGKILL
        time.sleep(0.5)
        try:
            os.kill(pid, signal.SIGKILL)
            os.waitpid(pid, 0)
        except (ProcessLookupError, ChildProcessError):
            pass

    render_evidence = any(
        tok in buf for tok in (b"\xe2\x94", b"opencode", b"?", b">")
    )
    exited = status is not None
    code = os.waitstatus_to_exitcode(status) if exited else None
    crashed = exited and code in CRASH_EXITS
    panic = b"integer does not fit" in buf or b"panic:" in buf

    # guard verification on the lazily-extracted runtime lib
    sos = glob.glob(os.path.join(tmpdir, ".bun-*-*.so"))
    guard_ok = None
    if sos:
        guard_ok = has_ffi_guard(open(sos[0], "rb").read())

    shutil.rmtree(tmpdir, ignore_errors=True)

    print(f"tui_smoke: render={'yes' if render_evidence else 'NO'} "
          f"exit={code if exited else 'still-running'} "
          f"panic={'YES' if panic else 'no'} "
          f"guard={'PASS' if guard_ok else ('FAIL' if guard_ok is False else 'no-so')}")

    ok = render_evidence and not panic and not crashed and guard_ok is not False
    if guard_ok is None and not crashed:
        # no .so extracted (TUI never started the renderer) -> treat as fail
        print("tui_smoke: FAIL — no runtime libopentui extracted (TUI did not start?)")
        return 1
    if not ok:
        print("tui_smoke: FAIL")
        return 1
    print("tui_smoke: PASS")
    return 0

if __name__ == "__main__":
    sys.exit(main())
