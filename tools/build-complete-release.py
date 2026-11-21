"""Wrap an already-built Workshop directory into one verified release ZIP."""
import argparse
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import re
import zipfile


WORKSHOP_ID = '3836261433'
DOCUMENTS = {
    'README.zh-CN.md', 'WORKSHOP-DESCRIPTION.txt', 'WORKSHOP-DESCRIPTION.en.txt',
    'UPLOAD.md', 'CHANGELOG.txt', 'VALIDATION.md', 'LICENSE-DECISION.md',
    'UPDATE-NOTES.zh-CN.txt', 'UPDATE-NOTES.en.txt',
    'START-HERE.txt', 'preview.png', 'modpreview.png', 'modpreview.gif',
    'modicon.png', 'ARTWORK.json', 'artwork-source.gif',
}
SHOWCASE = (
    '01-player-home.jpg', '02-world-lyrics-gold.gif', '03-world-lyrics-blue.gif',
    '04-word-animation.gif', '05-environment-settings.png', 'steam-links.json',
)
PRIVATE_PARTS = {
    '.state', '.git', '.game', 'artifacts', 'dist', 'music_cache', 'font-source',
    '__pycache__', '.env', '.ssh', '.aws', '.codex',
}
FIXED_ZIP_TIME = (2026, 11, 7, 0, 0, 0)
LAUNCHER_FIRST_VERSION = (0, 6, 0)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def json_bytes(value):
    return (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + '\n').encode('utf-8')


def safe_name(name):
    if not isinstance(name, str):
        raise ValueError('Artifact path must be a string')
    path = PurePosixPath(name)
    if (not name or path.is_absolute() or path.as_posix() != name
            or any(character in name for character in '\\:\r\n\x00')
            or '..' in path.parts):
        raise ValueError('Unsafe artifact path: ' + repr(name))
    if (any(part.lower() in PRIVATE_PARTS for part in path.parts)
            or path.name.lower() == 'dangomusic_connection.lua'):
        raise ValueError('Private artifact path: ' + name)
    return path


def checked_path(root, name):
    relative = safe_name(name)
    path = root.joinpath(*relative.parts)
    for ancestor in (path, *path.parents):
        if ancestor.is_symlink() or (hasattr(ancestor, 'is_junction') and ancestor.is_junction()):
            raise ValueError('Refusing linked input')
    if not path.resolve().is_relative_to(root.resolve()):
        raise ValueError('Refusing out-of-directory input')
    return path


def inventory(entries):
    return {name: {'bytes': len(data), 'sha256': sha(data)} for name, data in sorted(entries.items())}


def requires_launcher(version):
    match = re.fullmatch(r'(\d+)\.(\d+)\.(\d+)(?:[-+][A-Za-z0-9.+-]+)?', version)
    return bool(match and tuple(map(int, match.groups())) >= LAUNCHER_FIRST_VERSION)


def verify_launcher(version, entries):
    package = 'DST-Music-' + version + '-Windows-Companion'
    launcher_dir = 'workshop-mod/windows-player/'
    companion = launcher_dir + package + '.zip'
    manifest_path = launcher_dir + 'companion.json'
    for name in ('workshop-mod/一键启动播放器.cmd', 'workshop-mod/自启动设置.cmd',
                 launcher_dir + '停止配套播放器.cmd', launcher_dir + 'Launch-Workshop.ps1',
                 launcher_dir + 'Runtime-Paths.ps1', manifest_path, companion):
        if not entries.get(name):
            raise ValueError('Missing required Workshop launcher file: ' + name)
    expected = {'schema': 1, 'package': package, 'sha256': sha(entries[companion])}
    if json.loads(entries[manifest_path]) != expected:
        raise ValueError('Workshop launcher manifest does not match the companion ZIP')
    try:
        with zipfile.ZipFile(io.BytesIO(entries[companion])) as archive:
            required = {
                package + '/' + name for name in (
                    'Start-Player.ps1', 'Stop-Player.ps1', 'Check-Environment.ps1',
                    'Connect-Workshop.ps1', 'Runtime-Paths.ps1', 'helper/server.mjs',
                    'helper/NativePlayer.ps1', 'runtime/node/node.exe', 'runtime/python/python.exe',
                )
            }
            if not required.issubset(archive.namelist()) or archive.testzip() is not None:
                raise ValueError('Workshop companion ZIP is incomplete or damaged')
    except zipfile.BadZipFile as error:
        raise ValueError('Workshop companion ZIP is incomplete or damaged') from error


def navigation(version):
    player_guidance = (
        '玩家双击工坊目录里的「一键启动播放器」，随后回游戏点「连接播放器」。\n'
        '已有一键版登录与设置在升级时保留。'
        if requires_launcher(version) else
        '玩家需更新已经解压的后台文件，并保留原来的 .state 目录。'
    )
    return f'''DangoMusic {version} 完整发布包

发布操作
1. 更新现有工坊条目 {WORKSHOP_ID}。
   https://steamcommunity.com/sharedfiles/filedetails/?id={WORKSHOP_ID}
2. 上传内容目录选择本包中的 workshop-mod。
3. 动态封面选择 modpreview.gif，静态封面选择 modpreview.png。
4. 中文简介见 WORKSHOP-DESCRIPTION.txt，英文简介见 WORKSHOP-DESCRIPTION.en.txt。
5. 本次更新日志可直接复制 UPDATE-NOTES.zh-CN.txt 或 UPDATE-NOTES.en.txt；历史记录见 CHANGELOG.txt。

后台与源码
Windows Companion 后台包位于 workshop-mod/windows-player/。
源码包位于 workshop-mod/source/。
{player_guidance}

校验
RELEASE-MANIFEST.json 记录发布内容的大小与 SHA-256。
SHA256SUMS.txt 同时校验发布内容和 RELEASE-MANIFEST.json。
本工具仅生成本地发布包，未自动上传。
'''.encode('utf-8')


def collect(build_directory, showcase=None):
    root = Path(build_directory).absolute()
    manifest = json.loads(checked_path(root, 'BUILD-MANIFEST.json').read_bytes())
    version = manifest.get('version')
    if not isinstance(version, str) or not re.fullmatch(r'[0-9][A-Za-z0-9.+-]*', version):
        raise ValueError('Invalid build version')
    outputs = manifest.get('outputs')
    if not isinstance(outputs, dict):
        raise ValueError('Missing build output inventory')
    entries = {}
    names = set()
    for name, record in outputs.items():
        safe_name(name)
        if name.lower() in names:
            raise ValueError('Duplicate build output path')
        names.add(name.lower())
        if not (name.startswith('workshop-mod/') or name in DOCUMENTS):
            continue
        data = checked_path(root, name).read_bytes()
        if (not isinstance(record, dict) or type(record.get('bytes')) is not int
                or record['bytes'] != len(data) or record.get('sha256') != sha(data)):
            raise ValueError('Build output hash or size mismatch: ' + name)
        entries[name] = data
    if not any(name.startswith('workshop-mod/') for name in entries):
        raise ValueError('Missing Workshop content')
    if requires_launcher(version):
        verify_launcher(version, entries)
    # Reject extra files and linked directories instead of silently omitting Mod data.
    for path in checked_path(root, 'workshop-mod').rglob('*'):
        name = path.relative_to(root).as_posix()
        checked_path(root, name)
        if path.is_file() and name not in entries:
            raise ValueError('Unlisted Workshop file: ' + name)
    if showcase is not None:
        showcase_root = Path(showcase).absolute()
        for name in SHOWCASE:
            entries['showcase/' + name] = checked_path(showcase_root, name).read_bytes()
    entries['PUBLISH-README.txt'] = navigation(version)
    entries['RELEASE-MANIFEST.json'] = json_bytes({
        'schema': 1, 'version': version, 'workshopId': WORKSHOP_ID, 'uploaded': False,
        'files': inventory(entries),
        'inventoryScope': 'Payload files, excluding RELEASE-MANIFEST.json and SHA256SUMS.txt',
    })
    entries['SHA256SUMS.txt'] = ''.join(
        sha(data) + '  ' + name + '\n' for name, data in sorted(entries.items())
    ).encode('utf-8')
    return version, entries


def verify_zip(path, prefix, entries):
    with zipfile.ZipFile(path) as archive:
        expected = {prefix + '/' + name for name in entries}
        if len(archive.namelist()) != len(expected) or set(archive.namelist()) != expected:
            raise ValueError('Release ZIP member list mismatch')
        if archive.testzip() is not None:
            raise ValueError('Release ZIP CRC verification failed')
        for name, data in entries.items():
            actual = archive.read(prefix + '/' + name)
            if len(actual) != len(data) or sha(actual) != sha(data):
                raise ValueError('Release ZIP hash mismatch: ' + name)


def build(build_directory, output=None, showcase=None):
    """Return the new ZIP path. Existing output files are never replaced."""
    version, entries = collect(build_directory, showcase)
    prefix = 'DangoMusic-' + version + '-Release'
    path = Path(output) if output is not None else Path(build_directory).absolute().parent / (prefix + '.zip')
    if path.exists() or path.is_symlink():
        raise FileExistsError('Release output already exists')
    created = False
    try:
        with zipfile.ZipFile(path, 'x', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
            created = True
            for name, data in sorted(entries.items()):
                item = zipfile.ZipInfo(prefix + '/' + name, date_time=FIXED_ZIP_TIME)
                item.compress_type = zipfile.ZIP_STORED if name.lower().endswith('.zip') else zipfile.ZIP_DEFLATED
                item.external_attr = 0o100644 << 16
                archive.writestr(item, data)
        verify_zip(path, prefix, entries)
    except Exception:
        if created:
            path.unlink()
        raise
    return path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('build_directory', type=Path, help='Existing build-workshop.py output directory')
    parser.add_argument('--output', type=Path, help='Output ZIP path, defaulting to the versioned name in the build parent')
    parser.add_argument('--showcase', type=Path, help='Directory containing the six public showcase assets')
    args = parser.parse_args()
    try:
        result = build(args.build_directory, args.output, args.showcase)
    except (OSError, ValueError, zipfile.BadZipFile) as error:
        parser.exit(1, str(error) + '\n')
    print(result)


if __name__ == '__main__':
    main()
