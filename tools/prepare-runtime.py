"""Build the private Windows runtime from pinned official upstream archives.

This is a maintainer tool, not an installer. It changes only the project runtime
and its download cache; the user package needs no Python/Node installation.
"""
import base64
import hashlib
import json
from pathlib import Path, PurePosixPath
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
LOCK = json.loads((ROOT / 'tools/runtime-lock.json').read_text('utf-8'))
CACHE = ROOT / '.state/release-downloads'
RUNTIME = ROOT / 'runtime'
FILES = {}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def download(name, entry):
    expected = entry.get('sha256') or base64.b64decode(entry['digestBase64']).hex()
    target = CACHE / entry['url'].rsplit('/', 1)[1]
    CACHE.mkdir(parents=True, exist_ok=True)
    if not target.exists():
        temporary = target.with_suffix(target.suffix + '.partial')
        request = urllib.request.Request(entry['url'], headers={'User-Agent': 'DST-Music-Release/0.5'})
        h = hashlib.sha256()
        size = 0
        try:
            with urllib.request.urlopen(request, timeout=60) as response, temporary.open('wb') as output:
                while chunk := response.read(1024 * 1024):
                    size += len(chunk)
                    if size > 256 * 1024 * 1024:
                        raise ValueError('Archive exceeds runtime download budget')
                    output.write(chunk)
                    h.update(chunk)
            if h.hexdigest() != expected:
                raise ValueError(name + ' archive digest mismatch')
            temporary.replace(target)
        finally:
            temporary.unlink(missing_ok=True)
    if digest(target.read_bytes()) != expected:
        raise ValueError(name + ' cached archive digest mismatch')
    print(name + ': archive SHA-256 matched', flush=True)
    return target, expected


def write(target, data):
    FILES[target.relative_to(RUNTIME).as_posix()] = digest(data)
    if target.exists():
        if target.read_bytes() != data:
            raise ValueError('Refusing to overwrite a different runtime file: ' + str(target.relative_to(ROOT)))
        return
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(data)


def safe_member(name):
    member = PurePosixPath(name)
    if member.is_absolute() or '..' in member.parts or '\\' in name or ':' in name:
        raise ValueError('Unsafe runtime archive path')
    return member


def main():
    sources = {}
    for name in ('node', 'python', 'pillow'):
        entry = LOCK[name]
        path, sha256 = download(name, entry)
        sources[name] = {**entry, 'sha256': sha256}
        with zipfile.ZipFile(path) as archive:
            for item in archive.infolist():
                member = safe_member(item.filename)
                if item.is_dir():
                    continue
                if (item.external_attr >> 16) & 0o170000 == 0o120000:
                    raise ValueError('Symlink in runtime archive')
                if name == 'node':
                    if member.name not in ('node.exe', 'LICENSE') or len(member.parts) != 2:
                        continue
                    target = RUNTIME / 'node' / member.name
                elif name == 'python':
                    target = RUNTIME / 'python' / str(member)
                    if member.name.endswith('._pth'):
                        # Keep imports isolated from the host machine, but allow
                        # our compiler's sibling modules and bundled Pillow.
                        version = ''.join(entry['version'].split('.')[:2])
                        content = ('python' + version + '.zip\n.\nLib/site-packages\n../../helper\nimport site\n').encode('ascii')
                        write(target, content)
                        continue
                else:
                    target = RUNTIME / 'python/Lib/site-packages' / str(member)
                write(target, archive.read(item))
    sources['notice'] = 'Digests matched official HTTPS metadata; Sigstore signature/certificate chain was not independently verified. Node includes only node.exe and its complete LICENSE. Python embed and Pillow include their original license material. Python _pth adds only package-local helper and site-packages directories.'
    write(RUNTIME / 'SOURCES.json', (json.dumps(sources, indent=2, ensure_ascii=False) + '\n').encode('utf-8'))
    write(RUNTIME / 'RUNTIME-FILES.json', (json.dumps(FILES, indent=2, sort_keys=True) + '\n').encode('utf-8'))
    print('Portable runtime prepared at runtime/; no system installation performed.', flush=True)


if __name__ == '__main__':
    main()
