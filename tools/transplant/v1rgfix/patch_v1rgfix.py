#!/usr/bin/env python3
"""v1-rgfix: same-length in-place patch of the ripgrep filepath effect inside
an UNCOMPRESSED opencode 1.18.32 bun-standalone runtime (Android/bionic).

Fixes (triage: .omo/evidence/rc6-b2-upx-tui/task-v1input.txt):
  1. boot freeze: remove orDie/download/spawn-tar chain entirely; degrade to
     typed failure (Effect.ignore in TuiConfig.waitForDependencies swallows it)
  2. broken @effect stat layer bypassed: existence probed via
     FSUtil.readDirectoryEntries (fs/promises readdir -> getdents64, verified
     alive on oscar kernel 3.18 with bun 1.4.0)
  3. no spawn tar, no download (downloaded glibc rg is unexecutable on bionic)

Probe order: OPENCODE_SKIP_RG abort switch -> PATH scan (bionic Termux rg) ->
cache bin target -> typed failure.

Usage: patch_v1rgfix.py <uncompressed-runtime> [--revert]
Same-length guarantee: output file size == input size; bytes outside the
patched span are untouched (verified by sha over prefix/suffix).
"""
import hashlib
import sys

OLD_BODY = b'''let y=yield*Y.sync(()=>t0("rg"));if(y&&(yield*H.isFile(y).pipe(Y.orDie)))return y;let A=v1.join(u0.Path.bin,"rg");if(yield*H.isFile(A).pipe(Y.orDie))return A;let M="arm64-linux",B=$[M];if(!B)throw Error(`unsupported platform for ripgrep: ${M}`);let u=`ripgrep-15.1.0-${B.platform}.${B.extension}`,_=`https://github.com/BurntSushi/ripgrep/releases/download/15.1.0/${u}`,K0=v1.join(u0.Path.bin,u);yield*Y.logInfo("downloading ripgrep",{url:_}),yield*H.ensureDir(u0.Path.bin).pipe(Y.orDie);let y0=yield*C1.get(_).pipe(q.execute,Y.flatMap((z0)=>z0.arrayBuffer),Y.mapError((z0)=>z0 instanceof Error?z0:Error(String(z0))));if(y0.byteLength===0)throw Error(`failed to download ripgrep from ${_}`);return yield*H.writeWithDirs(K0,new Uint8Array(y0)),yield*k(K0,B,A),yield*H.remove(K0,{force:!0}).pipe(Y.ignore),A'''

NEW_BODY = b'''if(process.env.OPENCODE_SKIP_RG)return yield*Y.fail(Error("ripgrep disabled via OPENCODE_SKIP_RG"));let A=v1.join(u0.Path.bin,"rg"),Z=v1.basename(A),ok=(d,n)=>H.readDirectoryEntries(d).pipe(Y.map((E)=>E.some((e)=>e.name===n&&e.type!=="directory")),Y.catch(()=>Y.succeed(!1)));for(let D of(process.env.PATH||"").split(":"))if(D&&(yield*ok(D,Z)))return v1.join(D,Z);if(yield*ok(v1.dirname(A),Z))return A;return yield*Y.fail(Error("ripgrep unavailable: readdir probe failed; download/extract disabled on bionic"))'''

ANCHOR = b"downloading ripgrep"


def main() -> int:
    path = sys.argv[1]
    revert = "--revert" in sys.argv
    src, dst = (NEW_BODY, OLD_BODY) if revert else (OLD_BODY, NEW_BODY)
    if len(dst) > len(src):
        print("FATAL: replacement longer than original (%d > %d)" % (len(dst), len(src)))
        return 1
    data = open(path, "rb").read()
    n = data.count(ANCHOR)
    if n != 1:
        print("FATAL: anchor count %d != 1" % n)
        return 1
    start = data.find(src)
    if start == -1:
        print("FATAL: %s body not found (already patched?)" % ("NEW" if revert else "OLD"))
        return 1
    end = start + len(src)
    pad = dst + b" " * (len(src) - len(dst))
    pre = hashlib.sha256(data[:start]).hexdigest()
    post = hashlib.sha256(data[end:]).hexdigest()
    out = data[:start] + pad + data[end:]
    assert len(out) == len(data), "length drift"
    assert hashlib.sha256(out[:start]).hexdigest() == pre
    assert hashlib.sha256(out[end:]).hexdigest() == post
    open(path, "wb").write(out)
    print("patched %s @ +%d: body %d -> %d bytes (+%d pad), size %d unchanged"
          % (path, start, len(src), len(dst), len(src) - len(dst), len(out)))
    print("span sha pre/post untouched: %s %s" % (pre[:16], post[:16]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
