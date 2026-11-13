"""Complete release wrapper regressions using temporary synthetic builds."""
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import zipfile


SCRIPT = Path(__file__).resolve().parents[1] / 'tools/build-complete-release.py'
SPEC = importlib.util.spec_from_file_location('complete_release', SCRIPT)
BUILDER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BUILDER)


class CompleteReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='music-complete-release-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.folder = self.root / 'build'
        self.folder.mkdir()
        self.version = '0.5.1-beta.3'
        self.prefix = 'DangoMusic-' + self.version + '-Release/'
        self.files = {
            'workshop-mod/modmain.lua': b'-- synthetic Mod',
            'workshop-mod/windows-player/Companion.zip': b'synthetic companion ZIP',
            'workshop-mod/source/Source.zip': b'synthetic source ZIP',
            'Companion.zip': b'synthetic companion ZIP',
            'Source.zip': b'synthetic source ZIP',
            'Workshop-Upload.zip': b'redundant upload ZIP',
        }
        for name in BUILDER.DOCUMENTS:
            self.files[name] = ('public ' + name).encode('utf-8')
        for name, data in self.files.items():
            path = self.folder / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        self.manifest = {'version': self.version, 'outputs': BUILDER.inventory(self.files)}
        self.save_manifest()
        (self.folder / 'SHA256SUMS.txt').write_text('obsolete checksums', encoding='utf-8')

    def save_manifest(self):
        (self.folder / 'BUILD-MANIFEST.json').write_bytes(BUILDER.json_bytes(self.manifest))

    def test_structure_navigation_and_checksums(self):
        output = BUILDER.build(self.folder)
        self.assertEqual(output, self.root / ('DangoMusic-' + self.version + '-Release.zip'))
        with zipfile.ZipFile(output) as archive:
            payload = {name.removeprefix(self.prefix): archive.read(name) for name in archive.namelist()}
            self.assertTrue(all(name.startswith(self.prefix) for name in archive.namelist()))
            self.assertIsNone(archive.testzip())
        expected = {name for name in self.files if name.startswith('workshop-mod/') or name in BUILDER.DOCUMENTS}
        self.assertEqual(set(payload), expected | {'PUBLISH-README.txt', 'RELEASE-MANIFEST.json', 'SHA256SUMS.txt'})
        self.assertEqual({name for name in payload if name.endswith('.zip')}, {
            'workshop-mod/windows-player/Companion.zip', 'workshop-mod/source/Source.zip',
        })
        navigation = payload['PUBLISH-README.txt'].decode('utf-8')
        for fragment in ('更新现有工坊', '3836261433', 'workshop-mod', 'modpreview.gif',
                         'modpreview.png', 'WORKSHOP-DESCRIPTION.en.txt', '.state', '未自动上传'):
            self.assertIn(fragment, navigation)
        manifest = json.loads(payload['RELEASE-MANIFEST.json'])
        self.assertEqual(manifest['version'], self.version)
        self.assertEqual(manifest['workshopId'], '3836261433')
        self.assertNotIn(str(self.root), payload['RELEASE-MANIFEST.json'].decode('utf-8'))
        content = {name: data for name, data in payload.items() if name not in ('RELEASE-MANIFEST.json', 'SHA256SUMS.txt')}
        self.assertEqual(manifest['files'], BUILDER.inventory(content))
        lines = payload['SHA256SUMS.txt'].decode('utf-8').splitlines()
        self.assertEqual(len(lines), len(payload) - 1)
        for line in lines:
            digest, name = line.split('  ', 1)
            self.assertEqual(hashlib.sha256(payload[name]).hexdigest(), digest)

    def test_rejects_tampered_size_and_hash(self):
        for data in (b'changed', b'-- synthetic MOd'):
            with self.subTest(data=data):
                (self.folder / 'workshop-mod/modmain.lua').write_bytes(data)
                with self.assertRaisesRegex(ValueError, 'hash or size mismatch'):
                    BUILDER.build(self.folder)
        self.assertFalse(list(self.root.glob('*.zip')))

    def test_does_not_overwrite(self):
        output = self.root / 'existing.zip'
        output.write_bytes(b'keep existing output')
        with self.assertRaises(FileExistsError):
            BUILDER.build(self.folder, output)
        self.assertEqual(output.read_bytes(), b'keep existing output')

    def test_showcase_allowlist(self):
        showcase = self.root / 'showcase-input'
        showcase.mkdir()
        for name in BUILDER.SHOWCASE:
            (showcase / name).write_bytes(b'authorized public material')
        (showcase / 'manifest.json').write_text(json.dumps({'original': str(self.root)}), encoding='utf-8')
        (showcase / 'review-screenshot.png').write_bytes(b'private review')
        output = BUILDER.build(self.folder, showcase=showcase)
        with zipfile.ZipFile(output) as archive:
            names = {name.removeprefix(self.prefix) for name in archive.namelist()}
        self.assertEqual({name for name in names if name.startswith('showcase/')}, {
            'showcase/' + name for name in BUILDER.SHOWCASE
        })

    def test_rejects_unsafe_manifest_paths(self):
        for name in ('../outside.txt', 'workshop-mod/../../outside.txt',
                     'C:/private.txt', 'workshop-mod/.state/token',
                     'workshop-mod/dangomusic_connection.lua', 'workshop-mod\\private.txt'):
            with self.subTest(name=name):
                self.manifest['outputs'][name] = {'bytes': 0, 'sha256': BUILDER.sha(b'')}
                self.save_manifest()
                with self.assertRaises(ValueError):
                    BUILDER.build(self.folder)
                del self.manifest['outputs'][name]

    def test_rejects_unlisted_workshop_file(self):
        (self.folder / 'workshop-mod/unlisted.txt').write_bytes(b'unlisted')
        with self.assertRaisesRegex(ValueError, 'Unlisted Workshop file'):
            BUILDER.build(self.folder)

    def test_new_release_requires_the_complete_launcher_and_matching_zip(self):
        version = '0.6.0-beta.2'
        package = 'DST-Music-' + version + '-Windows-Companion'
        prefix = 'workshop-mod/windows-player/'
        companion = prefix + package + '.zip'
        manifest_path = prefix + 'companion.json'
        files = {
            'workshop-mod/一键启动播放器.cmd': b'synthetic launcher command',
            'workshop-mod/自启动设置.cmd': b'synthetic settings command',
            prefix + '停止配套播放器.cmd': b'synthetic stop command',
            prefix + 'Launch-Workshop.ps1': b'synthetic launcher',
            prefix + 'Runtime-Paths.ps1': b'synthetic runtime path helper',
        }
        archive_bytes = io.BytesIO()
        with zipfile.ZipFile(archive_bytes, 'w') as archive:
            for name in ('Start-Player.ps1', 'Stop-Player.ps1', 'Check-Environment.ps1',
                         'Connect-Workshop.ps1', 'Runtime-Paths.ps1', 'helper/server.mjs',
                         'helper/NativePlayer.ps1', 'runtime/node/node.exe', 'runtime/python/python.exe'):
                archive.writestr(package + '/' + name, 'fixture')
        files[companion] = archive_bytes.getvalue()
        files[manifest_path] = BUILDER.json_bytes({
            'schema': 1, 'package': package, 'sha256': BUILDER.sha(files[companion]),
        })
        for name, data in files.items():
            (self.folder / name).write_bytes(data)
        self.files.update(files)
        self.manifest = {'version': version, 'outputs': BUILDER.inventory(self.files)}
        self.save_manifest()
        self.assertIn('一键启动播放器', BUILDER.collect(self.folder)[1]['PUBLISH-README.txt'].decode())
        for name in files:
            with self.subTest(name=name):
                record = self.manifest['outputs'].pop(name)
                self.save_manifest()
                with self.assertRaisesRegex(ValueError, 'Missing required Workshop launcher file'):
                    BUILDER.collect(self.folder)
                self.manifest['outputs'][name] = record
        mismatched_zip = b'new companion archive'
        (self.folder / companion).write_bytes(mismatched_zip)
        self.manifest['outputs'][companion] = BUILDER.inventory({companion: mismatched_zip})[companion]
        self.save_manifest()
        with self.assertRaisesRegex(ValueError, 'manifest does not match the companion ZIP'):
            BUILDER.collect(self.folder)
        matching_manifest = BUILDER.json_bytes({
            'schema': 1, 'package': package, 'sha256': BUILDER.sha(mismatched_zip),
        })
        (self.folder / manifest_path).write_bytes(matching_manifest)
        self.manifest['outputs'][manifest_path] = BUILDER.inventory({manifest_path: matching_manifest})[manifest_path]
        self.save_manifest()
        with self.assertRaisesRegex(ValueError, 'companion ZIP is incomplete or damaged'):
            BUILDER.collect(self.folder)

    def test_rejects_linked_showcase_input(self):
        showcase = self.root / 'showcase-input'
        showcase.mkdir()
        outside = self.root / 'outside.jpg'
        outside.write_bytes(b'outside file')
        try:
            (showcase / BUILDER.SHOWCASE[0]).symlink_to(outside)
        except OSError as error:
            self.skipTest('Symlinks unavailable: ' + str(error))
        with self.assertRaisesRegex(ValueError, 'linked input'):
            BUILDER.build(self.folder, showcase=showcase)

    def test_verification_failure_removes_partial_output(self):
        output = self.root / 'failed.zip'
        with mock.patch.object(BUILDER, 'verify_zip', side_effect=ValueError('test hash failure')):
            with self.assertRaisesRegex(ValueError, 'test hash failure'):
                BUILDER.build(self.folder, output)
        self.assertFalse(output.exists())

    def test_zip_verifier_rejects_changed_member(self):
        output = self.root / 'changed.zip'
        with zipfile.ZipFile(output, 'w') as archive:
            archive.writestr('release/file.txt', b'changed')
        with self.assertRaisesRegex(ValueError, 'hash mismatch'):
            BUILDER.verify_zip(output, 'release', {'file.txt': b'correct'})
        with self.assertRaisesRegex(ValueError, 'member list mismatch'):
            BUILDER.verify_zip(output, 'release', {'other.txt': b'correct'})

    def test_cli_custom_output(self):
        output = self.root / ('custom-' + self.version + '.zip')
        result = subprocess.run([sys.executable, str(SCRIPT), str(self.folder), '--output', str(output)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(output.is_file())


if __name__ == '__main__':
    unittest.main()
