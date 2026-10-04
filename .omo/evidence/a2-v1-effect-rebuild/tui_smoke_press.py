#!/usr/bin/env python3
"""TUI smoke for the oscar v1 press5 deploy (A2 todo18).

Judgment criterion (set by the task, stderrs):
    real PTY  -> render frames seen AND keystroke bytes produce a
                 response (output byte DELTA > 0).

Why not tools/transplant/tui_smoke.py: that harness asserts on the
lazily-extracted $TMPDIR/.bun-*.so (swap_tui.has_ffi_guard), which is the
pre-todo16 design. press5 carries its pty inside the bun store chunk and
has zero external .so, so "did a .bun-*.so appear" is not a meaningful
signal here — and asserting it would report a false FAIL on a healthy
runtime. The render+echo DELTA pair is the task's own criterion and is
what actually proves the TUI is alive on this 3.18 kernel.

Usage: tui_smoke_press.py [--launcher PATH] [--cwd DIR] [--settle S]
                          [--after-keys S] [--keys STRING] [--dump FILE]
Exit 0 only when render frames AND keystroke echo both hold.
"""
import argparse
import errno
import os
import pty
import select
import signal
import sys
import time


def drain(fd, seconds):
    """Read from the pty for `seconds`, returning (bytes, frames)."""
    buf = b""
    frames = 0
    deadline = time.time() + seconds
    while time.time() < deadline:
        r, _, _ = select.select([fd], [], [], 0.25)
        if not r:
            continue
        try:
            chunk = os.read(fd, 65536)
        except OSError as e:
            # EIO is the normal pty hangup signal on Linux.
            if e.errno == errno.EIO:
                break
            raise
        if not chunk:
            break
        buf += chunk
        # A "frame" is a cursor-home / full-repaint sequence: the TUI
        # redrawing rather than a single one-shot dump.
        if b"\x1b[H" in chunk or b"\x1b[2J" in chunk or b"\x1b[J" in chunk:
            frames += 1
    return buf, frames


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--launcher", default=None,
                    help="opencode1 launcher (default: resolve from PATH)")
    ap.add_argument("--cwd", default=None)
    ap.add_argument("--settle", type=float, default=25.0,
                    help="seconds to wait for first render (3.18 boots slowly)")
    ap.add_argument("--after-keys", type=float, default=12.0,
                    help="seconds to collect output after sending keys")
    ap.add_argument("--keys", default="hello",
                    help="keystrokes to type (echo probe)")
    ap.add_argument("--dump", default=None, help="write raw output here")
    args = ap.parse_args()

    launcher = args.launcher or "opencode1"
    if os.path.sep not in launcher:
        for d in os.environ.get("PATH", "").split(os.pathsep):
            cand = os.path.join(d, launcher)
            if os.path.isfile(cand) and os.access(cand, os.X_OK):
                launcher = cand
                break
    if not os.path.isfile(launcher):
        print(f"TUI_SMOKE: FAIL — launcher not found: {args.launcher or launcher}")
        return 1
    launcher = os.path.abspath(launcher)

    env = dict(os.environ)
    env["TERM"] = env.get("TERM") or "xterm-256color"

    pid, fd = pty.fork()
    if pid == 0:
        if args.cwd:
            try:
                os.chdir(args.cwd)
            except OSError:
                pass
        try:
            os.execve(launcher, [launcher], env)
        except Exception as e:  # noqa: BLE001
            print(f"execve failed: {e}", file=sys.stderr)
            os._exit(127)

    raw = b""
    # Phase 1: wait for the first render.
    pre, frames = drain(fd, args.settle)
    raw += pre
    exited_early = False
    wpid, st = os.waitpid(pid, os.WNOHANG)
    if wpid == pid:
        exited_early = True

    # Phase 2: type and watch for a response.
    post = b""
    keys_sent = 0
    if not exited_early:
        payload = args.keys.encode()
        try:
            os.write(fd, payload)
            keys_sent = len(payload)
        except OSError:
            pass
        post, frames2 = drain(fd, args.after_keys)
        frames += frames2
        raw += post
        wpid, st = os.waitpid(pid, os.WNOHANG)
        if wpid == pid:
            exited_early = True

    status = None
    if not exited_early:
        for sig in (signal.SIGTERM, signal.SIGKILL):
            try:
                os.kill(pid, sig)
            except ProcessLookupError:
                break
            deadline = time.time() + 3
            while time.time() < deadline:
                wpid, st = os.waitpid(pid, os.WNOHANG)
                if wpid == pid:
                    status = st
                    break
                time.sleep(0.1)
            if status is not None:
                break
    else:
        status = st

    code = os.waitstatus_to_exitcode(status) if status is not None else None
    crashed = code is not None and code < 0
    panic = b"panic:" in raw or b"integer does not fit" in raw

    # Render evidence: box-drawing glyphs, or ANSI SGR colour, or the
    # app's own chrome. Frames counted above are the stronger signal.
    render_bytes = len(pre)
    render_glyphs = sum(raw.count(t) for t in (b"\xe2\x94", b"\xe2\x96", b"\xe2\x95"))
    has_sgr = b"\x1b[" in raw
    rendered = frames > 0 or render_glyphs > 0 or (render_bytes > 0 and has_sgr)

    delta = len(post)
    echo = delta > 0

    if args.dump:
        with open(args.dump, "wb") as f:
            f.write(raw)

    print(f"TUI_SMOKE launcher={launcher}")
    print(f"  render: bytes={render_bytes} frames={frames} glyphs={render_glyphs} "
          f"sgr={has_sgr} -> {'YES' if rendered else 'NO'}")
    print(f"  echo:   keys_sent={keys_sent} out_delta={delta} -> {'YES' if echo else 'NO'}")
    print(f"  exit={code if code is not None else 'killed'} panic={'YES' if panic else 'no'}")

    if not rendered:
        print("TUI_SMOKE: FAIL — no render frames")
        return 1
    if not echo:
        print("TUI_SMOKE: FAIL — keystrokes produced no output (input dead)")
        return 1
    if panic or crashed:
        print("TUI_SMOKE: FAIL — crash/panic")
        return 1
    print("TUI_SMOKE: PASS (render + keystroke echo)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
