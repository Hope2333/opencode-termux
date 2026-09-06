#!/data/data/com.termux/files/usr/bin/python3
"""gen-packages-index.py — generate a flat APT Packages index from local .deb dirs.

Replaces dpkg-scanpackages (not shipped by Termux dpkg). Scans the given dirs
(default: the four packing deb families), reads each deb's control metadata,
and emits RFC822-style stanzas compatible with apt flat repos.

Filename is written as the BASENAME because release assets live at the release
root (GitHub `releases/latest/download/<basename>` flat URL shape).

Usage: python3 tools/gen-packages-index.py [OUT] [DIR...]
  OUT default: packing/Packages.gz
  DIR default: packing/dpkg packing/dpkg-native packing/dpkg-compressed packing/dpkg-standalone
"""
import sys, os, gzip, hashlib, tarfile, io, re

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def read_control(deb):
    """Extract control fields from a .deb (control.tar.xz or control.tar.gz)."""
    with open(deb, 'rb') as f:
        data = f.read()
    if not data.startswith(b'!<arch>\n'):
        raise ValueError('not an ar archive: %s' % deb)
    blob = None
    pos = 8
    while pos + 60 <= len(data):
        name = data[pos:pos + 16].decode('ascii', 'replace').strip()
        size = int(data[pos + 48:pos + 58].decode('ascii', 'replace').strip() or 0)
        body = data[pos + 60:pos + 60 + size]
        if name.startswith('control.tar.'):
            blob = (name, body)
            break
        pos = pos + 60 + size + (size % 2)
    if blob is None:
        raise ValueError('no control member in %s' % deb)
    kind, ctrl_blob = blob
    mode = 'r:xz' if kind.endswith('xz') else 'r:gz'
    tf = tarfile.open(fileobj=io.BytesIO(ctrl_blob), mode=mode)
    member = None
    for cand in ('./control', 'control'):
        try:
            member = tf.extractfile(cand)
        except KeyError:
            member = None
        if member is not None:
            break
    if member is None:
        tf.close()
        raise ValueError('no control file in %s' % deb)
    ctrl = member.read().decode('utf-8', 'replace')
    tf.close()
    fields = {}
    for line in ctrl.splitlines():
        if ': ' in line and not line.startswith((' ', chr(9))):
            k, _, v = line.partition(': ')
            fields[k] = v.strip()
    return fields

def main():
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(REPO, 'packing/Packages.gz')
    dirs = sys.argv[2:] or ['packing/dpkg', 'packing/dpkg-native', 'packing/dpkg-compressed', 'packing/dpkg-standalone']
    stanzas = []
    seen = set()
    for d in dirs:
        full = d if os.path.isabs(d) else os.path.join(REPO, d)
        if not os.path.isdir(full):
            continue
        for name in sorted(os.listdir(full)):
            if not name.endswith('.deb'):
                continue
            deb = os.path.join(full, name)
            try:
                f = read_control(deb)
            except Exception as e:
                print('WARN skip %s: %s' % (name, e), file=sys.stderr)
                continue
            pkg = f.get('Package', '')
            ver = f.get('Version', '')
            if (pkg, ver) in seen:
                continue
            seen.add((pkg, ver))
            h = hashlib.sha256()
            sz = 0
            with open(deb, 'rb') as fh:
                for chunk in iter(lambda: fh.read(1 << 20), b''):
                    h.update(chunk)
                    sz += len(chunk)
            stanzas.append('\n'.join([
                'Package: %s' % pkg,
                'Version: %s' % ver,
                'Architecture: %s' % f.get('Architecture', 'aarch64'),
                'Installed-Size: %s' % f.get('Installed-Size', '0'),
                'Depends: %s' % f.get('Depends', ''),
                'Description: %s' % f.get('Description', ''),
                'Filename: %s' % name,
                'Size: %d' % sz,
                'SHA256: %s' % h.hexdigest(),
            ]) + '\n')
    blob = ''.join(stanzas).encode()
    tmp = out + '.tmp'
    with gzip.open(tmp, 'wb', compresslevel=9) as g:
        g.write(blob)
    os.replace(tmp, out)
    print('PACKAGES_INDEX %s entries=%d bytes=%d' % (out, len(stanzas), os.path.getsize(out)))
    return 0 if stanzas else 1

if __name__ == '__main__':
    sys.exit(main())
