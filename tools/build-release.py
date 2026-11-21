"""Build a clean local candidate ZIP from an explicit allowlist.

No upload, service change, game installation or account mutation is performed.
Private state is read only to reject known credential bytes in the candidate.
"""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import zipfile

ROOT = Path(__file__).resolve().parents[1]
VERSION = '0.6.0-beta.6'
PACKAGE = 'DST-Music-' + VERSION + '-Windows-x64'
ROOT_FILES = [
    'Install-Mod.ps1', 'Start-Player.ps1', 'Stop-Player.ps1',
    'Runtime-Paths.ps1', 'Check-Environment.ps1',
    '安装客户端Mod.cmd', '启动播放器.cmd', '停止播放器.cmd', 'PROTOCOL.md',
]
DOCS = {'README.zh-CN.md': 'README.md', **{name: name for name in (
    'CHANGELOG.md', 'RELEASE-STATUS.md', 'THIRD-PARTY-NOTICES.md', 'VALIDATION.md')}}
entries = {}


def sha(data):
    return hashlib.sha256(data).hexdigest()


def add(source, name=None):
    source = ROOT / source
    if not source.resolve().is_relative_to(ROOT) or source.is_symlink():
        raise ValueError('Refusing out-of-project or linked source')
    relative = source.relative_to(ROOT).as_posix()
    name = name or relative
    if name in entries:
        raise ValueError('Duplicate candidate path: ' + name)
    entries[name] = source.read_bytes()


def tree(directory, suffixes, excludes=()):
    for path in sorted((ROOT / directory).rglob('*')):
        relative = path.relative_to(ROOT).as_posix()
        if path.is_file() and path.suffix in suffixes and '__pycache__' not in path.parts and relative not in excludes:
            add(relative)


def private_patterns():
    values = []
    serialized_credentials = []
    for name in ('bridge.json', 'account.json', 'account-qq.json'):
        path = ROOT / '.state' / name
        if not path.exists():
            continue
        data = json.loads(path.read_text('utf-8-sig'))
        if name == 'bridge.json':
            values.append(data.get('token', ''))
        elif name == 'account-qq.json':
            # QQ credentials are structured; include nested refresh credentials
            # without ever printing them or adding their state file to the ZIP.
            def strings(value, field=''):
                if isinstance(value, str):
                    values.append(value)
                    for ascii_only in (False, True):
                        encoded = json.dumps(value, ensure_ascii=ascii_only)
                        if len(value) >= 12:
                            serialized_credentials.append(encoded)
                        if field.lower() in ('key', 'token', 'musickey', 'refresh_key', 'refresh_token') and value:
                            label = json.dumps(field)
                            serialized_credentials.extend((label + ':' + encoded, label + ': ' + encoded))
                elif isinstance(value, dict):
                    for key, child in value.items():
                        strings(child, key)
                elif isinstance(value, list):
                    for child in value:
                        strings(child)
            strings(data.get('cookie', {}))
        else:
            cookie = data.get('cookie', '')
            values.append(cookie)
            values.extend(part.strip().split('=', 1)[1] for part in cookie.split(';') if '=' in part)
    patterns = [value for value in values if len(value) >= 12] + serialized_credentials
    return list({value.encode(encoding) for value in patterns for encoding in ('utf-8', 'utf-16-le')})


def main():
    for name in ROOT_FILES:
        add(name)
    for source, name in DOCS.items():
        add('release/' + source, name)
    tree('helper', {'.mjs', '.js', '.css', '.html', '.py', '.cs', '.ps1', '.dll', '.txt', '.md', '.kt'})
    add('mod/modmain.lua')
    add('mod/modinfo.lua')
    add('mod/music_workshop_identity.json')
    tree('mod/scripts', {'.lua'}, ('mod/scripts/dangomusic_connection.lua',))
    for name in ('ui.png', 'ui.tex', 'ui.xml'):
        add('mod/images/music/' + name)
    tree('mod/tests', {'.py', '.lua'})
    tree('tests', {'.mjs', '.py', '.ps1', '.cs'})
    add('tests/native-player-silence.mp3')
    for name in ('prepare-runtime.py', 'runtime-lock.json', 'build-release.py'):
        add('tools/' + name)
    # Include the release document sources so maintainers can rebuild this ZIP.
    for name in DOCS:
        add('release/' + name)
    runtime_manifest = ROOT / 'runtime/RUNTIME-FILES.json'
    inventory = json.loads(runtime_manifest.read_text('utf-8'))
    for name, expected in inventory.items():
        path = Path(name)
        if path.is_absolute() or '..' in path.parts or '\\' in name or ':' in name:
            raise ValueError('Invalid runtime manifest path')
        add('runtime/' + name)
        if sha(entries['runtime/' + name]) != expected:
            raise ValueError('Runtime file differs from authenticated preparation: ' + name)
    add('runtime/RUNTIME-FILES.json')
    entries['VERSION'] = (VERSION + '\nlocal-candidate\n').encode('ascii')

    credentials = private_patterns()
    for name, data in entries.items():
        parts = Path(name).parts
        if any(part in ('.state', 'artifacts', 'music_cache', 'font-source', '__pycache__') for part in parts) or name.endswith('dangomusic_connection.lua'):
            raise ValueError('Private path in release candidate: ' + name)
        if any(pattern in data for pattern in credentials):
            raise ValueError('Known local credential found in candidate file: ' + name)
    manifest = {
        'name': PACKAGE, 'version': VERSION, 'stage': 'local-candidate',
        'overallLicenseDecision': 'pending-author-decision', 'uploaded': False,
        'files': {name: {'bytes': len(data), 'sha256': sha(data)} for name, data in sorted(entries.items())},
    }
    entries['MANIFEST.json'] = (json.dumps(manifest, indent=2, ensure_ascii=False) + '\n').encode('utf-8')
    folder = ROOT / 'dist' / (VERSION + '-candidate-' + datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ'))
    folder.mkdir(parents=True, exist_ok=False)
    archive_path = folder / (PACKAGE + '.zip')
    with zipfile.ZipFile(archive_path, 'x', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name, data in sorted(entries.items()):
            item = zipfile.ZipInfo(PACKAGE + '/' + name, date_time=(2026, 11, 4, 0, 0, 0))
            item.compress_type = zipfile.ZIP_DEFLATED
            item.external_attr = 0o100644 << 16
            archive.writestr(item, data)
    # Reopen the actual ZIP, verify all payloads and CRCs, not just the input list.
    with zipfile.ZipFile(archive_path) as archive:
        if archive.testzip() is not None:
            raise ValueError('ZIP CRC verification failed')
        for name, expected in entries.items():
            if sha(archive.read(PACKAGE + '/' + name)) != sha(expected):
                raise ValueError('ZIP payload differs: ' + name)
    checksum = sha(archive_path.read_bytes())
    archive_path.with_suffix('.zip.sha256').write_text(checksum + '  ' + archive_path.name + '\n', encoding='ascii')
    summary = {'archive': str(archive_path), 'sha256': checksum, 'files': len(entries), 'zipBytes': archive_path.stat().st_size, 'uncompressedBytes': sum(map(len, entries.values())), 'privacyScan': 'passed', 'zipPayloadVerification': 'passed', 'licenseDecision': 'pending', 'uploaded': False}
    (folder / 'BUILD-RESULT.json').write_text(json.dumps(summary, indent=2), encoding='utf-8')
    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
