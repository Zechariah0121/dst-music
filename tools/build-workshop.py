"""Build local Workshop beta artifacts from explicit, private-state-free inputs.

This command creates files only in dist. It never uploads or installs a Mod,
starts a player, or changes the running game. Component licenses are preserved.
"""
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
from pathlib import Path, PurePosixPath
import re
import zipfile


ROOT = Path(__file__).resolve().parents[1]
VERSION = '0.6.0-beta.6'
STAGE = 'workshop-beta-upload-bundle'
COMPANION = 'DST-Music-' + VERSION + '-Windows-Companion'
SOURCE = 'DST-Music-' + VERSION + '-Source'
UPLOAD = 'DST-Music-' + VERSION + '-Workshop-Upload'
LICENSE_DECISION = 'component-licenses-preserved'
IDENTITY = {'schema': 1, 'id': 'zcc-dst-music', 'channel': 'workshop-beta', 'version': VERSION}
WORKSHOP_DOCS = (
    'README.zh-CN.md', 'WORKSHOP-DESCRIPTION.txt', 'WORKSHOP-DESCRIPTION.en.txt', 'UPLOAD.md', 'CHANGELOG.txt',
    'UPDATE-NOTES.zh-CN.txt', 'UPDATE-NOTES.en.txt',
    'VALIDATION.md', 'LICENSE-DECISION.md', 'START-HERE.txt',
    'preview.png', 'modpreview.png', 'modpreview.gif', 'modicon.png', 'ARTWORK.json', 'artwork-source.gif',
)
WORKSHOP_LAUNCHER = (
    ('release/workshop/一键启动播放器.cmd', '一键启动播放器.cmd'),
    ('release/workshop/自启动设置.cmd', '自启动设置.cmd'),
    ('release/workshop/停止配套播放器.cmd', 'windows-player/停止配套播放器.cmd'),
    ('release/workshop/Launch-Workshop.ps1', 'windows-player/Launch-Workshop.ps1'),
)
MOD_FILES = (
    'modmain.lua', 'modinfo.lua', 'music_workshop_identity.json',
    'modicon.tex', 'modicon.xml',
    'images/music/ui.png', 'images/music/ui.tex', 'images/music/ui.xml',
)
HELPER_SUFFIXES = {'.mjs', '.js', '.css', '.html', '.py', '.cs', '.ps1', '.dll', '.txt', '.md', '.kt'}
TEST_SUFFIXES = {'.mjs', '.py', '.ps1', '.cs', '.lua'}
PRIVATE_PARTS = {'.state', '.git', '.game', 'artifacts', 'dist', 'music_cache', 'font-source', '__pycache__'}
FIXED_ZIP_TIME = (2026, 11, 7, 0, 0, 0)


def release_builder():
    """Reuse the existing release allowlists and credential-byte scanner."""
    spec = importlib.util.spec_from_file_location('music_release_builder', Path(__file__).with_name('build-release.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def sha(data):
    return hashlib.sha256(data).hexdigest()


def safe_name(name):
    path = PurePosixPath(name)
    if not name or path.is_absolute() or '..' in path.parts or '\\' in name or ':' in name or path.as_posix() != name:
        raise ValueError('Unsafe artifact path')
    if any(part.lower() in PRIVATE_PARTS for part in path.parts) or path.name.lower() == 'dangomusic_connection.lua':
        raise ValueError('Private path in artifact: ' + name)
    return path


class Files:
    def __init__(self, root):
        self.root = root.resolve()
        self.entries = {}
        self.names = set()

    def put(self, name, data):
        safe_name(name)
        if name.lower() in self.names:
            raise ValueError('Duplicate artifact path: ' + name)
        self.names.add(name.lower())
        self.entries[name] = data

    def add(self, source, name=None):
        source_path = safe_name(source)
        path = self.root.joinpath(*source_path.parts)
        if not path.resolve().is_relative_to(self.root):
            raise ValueError('Refusing out-of-project source')
        for ancestor in (path, *path.parents):
            if ancestor == self.root:
                break
            if ancestor.is_symlink() or (hasattr(ancestor, 'is_junction') and ancestor.is_junction()):
                raise ValueError('Refusing linked source')
        self.put(name or source, path.read_bytes())

    def tree(self, directory, suffixes, prefix=None):
        for path in sorted((self.root / directory).rglob('*')):
            relative = path.relative_to(self.root).as_posix()
            parts = PurePosixPath(relative).parts
            if any(part.lower() in PRIVATE_PARTS for part in parts) or path.name.lower() == 'dangomusic_connection.lua':
                continue
            if path.is_file() and path.suffix.lower() in suffixes:
                name = relative if prefix is None else prefix + path.relative_to(self.root / directory).as_posix()
                self.add(relative, name)


def json_bytes(value):
    return (json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + '\n').encode('utf-8')


def inventory(entries):
    return {name: {'bytes': len(data), 'sha256': sha(data)} for name, data in sorted(entries.items())}


def validate_identity(root):
    info = (root / 'mod/modinfo.lua').read_text('utf-8-sig')
    versions = re.findall(r'^\s*version\s*=\s*[\"\']([^\"\']+)[\"\']\s*(?:--[^\n]*)?$', info, re.MULTILINE)
    if versions != [VERSION]:
        raise ValueError('Source modinfo.lua version must equal ' + VERSION)
    marker = json.loads((root / 'mod/music_workshop_identity.json').read_text('utf-8-sig'))
    if marker != IDENTITY:
        raise ValueError('Workshop identity marker differs from the expected public identity')


def collect_mod(root):
    files = Files(root)
    for name in MOD_FILES:
        files.add('mod/' + name, name)
    files.tree('mod/scripts', {'.lua'}, prefix='scripts/')
    # Keep component provenance alongside the bundled Companion and Source.
    scope = (
        '# 工坊 Mod 与配套播放器的通知范围\n\n'
        '此目录包含客户端 Lua、静态 UI 图集、图标和公开身份标记，'
        'windows-player/ 内置 Windows Companion ZIP，source/ 内置对应源码 ZIP。'
        'NAudio、QRCode、Node、Python、Pillow 和 DangoMusic 派生音频实现按各组件原许可保留。'
        '以下保留原配套项目的第三方通知，licenses/ 内保留原上游许可和来源文本，'
        '其中相对路径以 Companion/Source 包根目录为准。许可范围见 LICENSE-DECISION.md。\n\n'
    ).encode('utf-8')
    files.add('release/THIRD-PARTY-NOTICES.md', 'THIRD-PARTY-NOTICES.md')
    files.entries['THIRD-PARTY-NOTICES.md'] = scope + files.entries['THIRD-PARTY-NOTICES.md']
    for name in ('DangoMusic.LICENSE.txt', 'NAudio.LICENSE.txt', 'SOURCES.md'):
        files.add('helper/native-deps/' + name, 'licenses/' + name)
    files.add('helper/public/vendor/qrcode-LICENSE.txt', 'licenses/qrcode-LICENSE.txt')
    files.add('release/workshop/LICENSE-DECISION.md', 'LICENSE-DECISION.md')
    files.add('release/workshop/START-HERE.txt', 'START-HERE.txt')
    # 安装帮助可直接阅读，玩家无需先解压配套包寻找说明。
    files.add('release/workshop/README.zh-CN.md', 'windows-player/README.zh-CN.md')
    for source, destination in WORKSHOP_LAUNCHER:
        files.add(source, destination)
    files.add('Runtime-Paths.ps1', 'windows-player/Runtime-Paths.ps1')
    return files


def collect_implementation(root, legacy):
    files = Files(root)
    for name in legacy.ROOT_FILES:
        if name != '安装客户端Mod.cmd':
            files.add(name)
    for name in ('Connect-Workshop.ps1', '连接工坊Mod.cmd'):
        files.add(name)
    files.tree('helper', HELPER_SUFFIXES)
    for name in MOD_FILES:
        files.add('mod/' + name)
    files.tree('mod/scripts', {'.lua'})
    files.tree('mod/tests', TEST_SUFFIXES)
    files.tree('tests', TEST_SUFFIXES)
    files.add('tests/native-player-silence.mp3')
    for name in ('prepare-runtime.py', 'runtime-lock.json', 'build-release.py', 'build-workshop.py', 'build-complete-release.py', 'create-workshop-art.py'):
        files.add('tools/' + name)
    for name in legacy.DOCS:
        files.add('release/' + name)
    for name in WORKSHOP_DOCS:
        files.add('release/workshop/' + name)
    for source, _ in WORKSHOP_LAUNCHER:
        files.add(source)
    files.add('release/workshop/LICENSE-DECISION.md', 'LICENSE-DECISION.md')
    files.add('README.md')
    files.add('.gitignore')
    files.add('.github/workflows/release.yml')
    files.add('release/github/RELEASE.md')
    files.add('release/THIRD-PARTY-NOTICES.md', 'THIRD-PARTY-NOTICES.md')
    files.put('VERSION', (VERSION + '\n' + STAGE + '\n').encode('ascii'))
    return files


def add_runtime(files):
    manifest_data = (files.root / 'runtime/RUNTIME-FILES.json').read_bytes()
    manifest = json.loads(manifest_data.decode('utf-8-sig'))
    if not isinstance(manifest, dict) or not manifest:
        raise ValueError('Runtime inventory is empty or invalid; run prepare-runtime.py')
    for name, expected in manifest.items():
        safe_name(name)
        files.add('runtime/' + name)
        if sha(files.entries['runtime/' + name]) != expected:
            raise ValueError('Runtime differs from authenticated preparation: ' + name)
    files.put('runtime/RUNTIME-FILES.json', manifest_data)


def scan_private(collections, root, legacy):
    legacy.ROOT = root
    credentials = legacy.private_patterns()
    for files in collections:
        for name, data in files.entries.items():
            safe_name(name)
            if any(pattern in data for pattern in credentials):
                # Only the artifact path is reported, never the matched bytes.
                raise ValueError('Known local credential found in artifact file: ' + name)


def add_manifest(files, product):
    files.put('MANIFEST.json', json_bytes({
        'product': product, 'version': VERSION, 'stage': STAGE,
        'overallLicenseDecision': LICENSE_DECISION, 'uploaded': False,
        'files': inventory(files.entries),
    }))


def write_zip(path, prefix, entries):
    with zipfile.ZipFile(path, 'x', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name, data in sorted(entries.items()):
            item = zipfile.ZipInfo(prefix + '/' + name, date_time=FIXED_ZIP_TIME)
            item.compress_type = zipfile.ZIP_STORED if name.lower().endswith('.zip') else zipfile.ZIP_DEFLATED
            item.external_attr = 0o100644 << 16
            archive.writestr(item, data)
    verify_zip(path, prefix, entries)


def verify_zip(path, prefix, entries):
    with zipfile.ZipFile(path) as archive:
        expected_names = {prefix + '/' + name for name in entries}
        if len(archive.namelist()) != len(expected_names) or set(archive.namelist()) != expected_names:
            raise ValueError('ZIP member list differs from the allowlist')
        if archive.testzip() is not None:
            raise ValueError('ZIP CRC verification failed')
        for name, data in entries.items():
            if sha(archive.read(prefix + '/' + name)) != sha(data):
                raise ValueError('ZIP payload differs: ' + name)


def build(root=ROOT):
    root = Path(root).resolve()
    validate_identity(root)
    legacy = release_builder()
    workshop = collect_mod(root)
    source = collect_implementation(root, legacy)
    # The maintenance installer remains in source for a complete rebuild.
    # Companion users enter through Connect-Workshop.ps1 / 连接工坊Mod.cmd.
    source.add('安装客户端Mod.cmd')
    companion = Files(root)
    for name, data in source.entries.items():
        if name != '安装客户端Mod.cmd':
            companion.put(name, data)
    companion.entries['README.md'] = source.entries['release/workshop/README.zh-CN.md']
    add_runtime(companion)
    documents = Files(root)
    for name in WORKSHOP_DOCS:
        documents.add('release/workshop/' + name, name)
    scan_private((workshop, source, companion, documents), root, legacy)
    add_manifest(source, 'Source')
    add_manifest(companion, 'Windows Companion')

    stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    folder = root / 'dist' / (VERSION + '-workshop-' + stamp)
    folder.mkdir(parents=True, exist_ok=False)
    output = {}
    for package, files, embedded_directory in (
        (COMPANION, companion, 'windows-player'), (SOURCE, source, 'source'),
    ):
        path = folder / (package + '.zip')
        write_zip(path, package, files.entries)
        data = path.read_bytes()
        output[path.name] = data
        workshop.put(embedded_directory + '/' + path.name, data)
        if package == COMPANION:
            workshop.put('windows-player/companion.json', json_bytes({
                'schema': 1, 'package': package, 'sha256': sha(data),
            }))
    scan_private((workshop,), root, legacy)
    for name, data in workshop.entries.items():
        relative = 'workshop-mod/' + name
        path = folder / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        if sha(path.read_bytes()) != sha(data):
            raise ValueError('Workshop output payload differs: ' + name)
        output[relative] = data
    for name, data in documents.entries.items():
        (folder / name).write_bytes(data)
        output[name] = data
    upload_path = folder / (UPLOAD + '.zip')
    write_zip(upload_path, 'workshop-mod', workshop.entries)
    output[upload_path.name] = upload_path.read_bytes()
    for name, data in output.items():
        if sha((folder / name).read_bytes()) != sha(data):
            raise ValueError('Output file differs from its payload: ' + name)
    manifest = {
        'version': VERSION, 'stage': STAGE, 'uploaded': False,
        'overallLicenseDecision': LICENSE_DECISION,
        'workshopMod': inventory(workshop.entries),
        'companionPayload': inventory(companion.entries),
        'sourcePayload': inventory(source.entries),
        'outputs': inventory(output),
        'privacyScan': 'passed', 'zipCrcVerification': 'passed', 'allPayloadHashVerification': 'passed',
    }
    manifest_data = json_bytes(manifest)
    (folder / 'BUILD-MANIFEST.json').write_bytes(manifest_data)
    output['BUILD-MANIFEST.json'] = manifest_data
    checksums = ''.join(sha(data) + '  ' + name + '\n' for name, data in sorted(output.items()))
    (folder / 'SHA256SUMS.txt').write_text(checksums, encoding='utf-8')
    result = {
        'folder': str(folder), 'version': VERSION, 'stage': STAGE,
        'workshopFiles': len(workshop.entries), 'companionFiles': len(companion.entries),
        'sourceFiles': len(source.entries), 'privacyScan': 'passed',
        'zipPayloadVerification': 'passed', 'licenseDecision': LICENSE_DECISION, 'uploaded': False,
    }
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return folder


if __name__ == '__main__':
    build()
