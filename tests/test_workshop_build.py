"""Local packaging regressions using a synthetic project, never a game install."""
import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
import zipfile


SPEC = importlib.util.spec_from_file_location('workshop_build', Path(__file__).resolve().parents[1] / 'tools/build-workshop.py')
BUILDER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BUILDER)


class WorkshopBuildTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='music-workshop-build-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.legacy = BUILDER.release_builder()
        for name in self.legacy.ROOT_FILES:
            self.write(name, b'synthetic launcher\n')
        for name in ('README.md', '.gitignore', '.github/workflows/release.yml', 'release/github/RELEASE.md', 'Connect-Workshop.ps1', '连接工坊Mod.cmd'):
            self.write(name, ('synthetic ' + name).encode('utf-8'))
        for name in BUILDER.MOD_FILES:
            self.write('mod/' + name, b'synthetic mod resource\n')
        self.write('mod/modinfo.lua', ('version = "' + BUILDER.VERSION + '"\n').encode('ascii'))
        self.write('mod/music_workshop_identity.json', json.dumps(BUILDER.IDENTITY).encode('utf-8'))
        for name in self.legacy.DOCS:
            self.write('release/' + name, b'original release notice\n')
        for name in (*BUILDER.WORKSHOP_DOCS, 'preview.svg'):
            self.write('release/workshop/' + name, ('workshop ' + name).encode('utf-8'))
        for source, _ in BUILDER.WORKSHOP_LAUNCHER:
            self.write(source, ('launcher ' + source).encode('utf-8'))
        for name in ('prepare-runtime.py', 'runtime-lock.json', 'build-release.py', 'build-workshop.py', 'build-complete-release.py', 'create-workshop-art.py'):
            self.write('tools/' + name, b'synthetic build source\n')
        for name in ('DangoMusic.LICENSE.txt', 'NAudio.LICENSE.txt', 'SOURCES.md', 'EnvironmentAudio.reference.kt', 'MusicPlayer.reference.kt', 'NAudio.Core.dll'):
            self.write('helper/native-deps/' + name, ('upstream ' + name).encode('utf-8'))
        for name in ('qrcode.js', 'qrcode-LICENSE.txt'):
            self.write('helper/public/vendor/' + name, ('upstream ' + name).encode('utf-8'))
        self.write('helper/server.mjs', b'export const synthetic = true;\n')
        self.write('tests/native-player-silence.mp3', b'synthetic silence fixture')
        self.write('tests/test_synthetic.py', b'assert True\n')
        self.write('mod/tests/test_synthetic.py', b'assert True\n')
        self.write('mod/scripts/widgets/music_synthetic.lua', b'return {}\n')
        runtime = {'node/node.exe': b'synthetic node', 'python/python.exe': b'synthetic python', 'SOURCES.json': b'{}'}
        for name, data in runtime.items():
            self.write('runtime/' + name, data)
        self.write('runtime/RUNTIME-FILES.json', json.dumps({name: BUILDER.sha(data) for name, data in runtime.items()}).encode('ascii'))

    def write(self, name, data):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)

    def build(self):
        with contextlib.redirect_stdout(io.StringIO()):
            return BUILDER.build(self.root)

    def payload(self, folder, package):
        with zipfile.ZipFile(folder / (package + '.zip')) as archive:
            self.assertIsNone(archive.testzip())
            return {name.removeprefix(package + '/'): archive.read(name) for name in archive.namelist()}

    def test_product_payloads_exclude_private_state_and_include_rebuild_inputs(self):
        private = b'private-fixture-payload-that-must-never-ship'
        for name in (
            '.state/account.json', 'mod/scripts/dangomusic_connection.lua',
            'mod/images/music_cache/private.tex', 'mod/font-source/private.lua',
            'mod/scripts/music_cache/private.lua', 'helper/.state/private.mjs',
            'helper/artifacts/private.py', 'helper/__pycache__/private.py',
            'helper/private-song.mp3', 'artifacts/private-screen.png', '.game/fonts.zip',
        ):
            self.write(name, private if not name.endswith('account.json') else b'{"cookie":""}')
        folder = self.build()
        companion = self.payload(folder, BUILDER.COMPANION)
        source = self.payload(folder, BUILDER.SOURCE)
        workshop = {path.relative_to(folder / 'workshop-mod').as_posix(): path.read_bytes() for path in (folder / 'workshop-mod').rglob('*') if path.is_file()}
        for entries in (workshop, companion, source):
            for name, data in entries.items():
                self.assertNotIn(private, data, name)
                BUILDER.safe_name(name)
        self.assertIn('runtime/node/node.exe', companion)
        self.assertIn('runtime/python/python.exe', companion)
        self.assertFalse(any(name.startswith('runtime/') for name in source))
        self.assertNotIn('安装客户端Mod.cmd', companion)
        self.assertIn('安装客户端Mod.cmd', source)
        self.assertIn('Connect-Workshop.ps1', companion)
        self.assertIn('连接工坊Mod.cmd', companion)
        self.assertEqual(companion['README.md'], source['release/workshop/README.zh-CN.md'])
        self.assertEqual(source['README.md'], (self.root / 'README.md').read_bytes())
        for name in ('helper/native-deps/EnvironmentAudio.reference.kt', 'helper/native-deps/DangoMusic.LICENSE.txt', 'mod/tests/test_synthetic.py', 'tools/build-workshop.py', 'tools/build-release.py', 'tools/create-workshop-art.py', 'tools/prepare-runtime.py', 'tools/runtime-lock.json', 'release/workshop/modpreview.gif', 'release/workshop/ARTWORK.json'):
            self.assertIn(name, source)
        self.assertNotIn('release/workshop/preview.svg', source)
        self.assertEqual(json.loads(workshop['music_workshop_identity.json']), BUILDER.IDENTITY)
        self.assertIn('scripts/widgets/music_synthetic.lua', workshop)
        self.assertEqual(workshop['windows-player/README.zh-CN.md'], companion['README.md'])
        self.assertIn('licenses/DangoMusic.LICENSE.txt', workshop)
        self.assertFalse(any(name.startswith(('helper/', 'runtime/', 'tests/')) for name in workshop))
        self.assertEqual(workshop['images/music/ui.tex'], (self.root / 'mod/images/music/ui.tex').read_bytes())
        manifest = json.loads((folder / 'BUILD-MANIFEST.json').read_text('utf-8'))
        self.assertFalse(manifest['uploaded'])
        self.assertEqual(manifest['overallLicenseDecision'], BUILDER.LICENSE_DECISION)
        for name, entries in (('workshopMod', workshop), ('companionPayload', companion), ('sourcePayload', source)):
            self.assertEqual(manifest[name], BUILDER.inventory(entries))
        for payload in (companion, source):
            payload_manifest = json.loads(payload['MANIFEST.json'])
            self.assertEqual(payload_manifest['overallLicenseDecision'], BUILDER.LICENSE_DECISION)
            expected = payload_manifest['files']
            self.assertEqual(expected, BUILDER.inventory({name: data for name, data in payload.items() if name != 'MANIFEST.json'}))
        checksums = (folder / 'SHA256SUMS.txt').read_text('utf-8').splitlines()
        for line in checksums:
            digest, name = line.split('  ', 1)
            self.assertEqual(digest, hashlib.sha256((folder / name).read_bytes()).hexdigest())
        expected_outputs = set(manifest['outputs']) | {'BUILD-MANIFEST.json'}
        self.assertEqual({line.split('  ', 1)[1] for line in checksums}, expected_outputs)
        actual_outputs = {
            path.relative_to(folder).as_posix(): path.read_bytes()
            for path in folder.rglob('*')
            if path.is_file() and path.name not in {'BUILD-MANIFEST.json', 'SHA256SUMS.txt'}
        }
        self.assertEqual(manifest['outputs'], BUILDER.inventory(actual_outputs))
        self.assertNotEqual(self.build(), folder)

    def test_embedded_packages_equal_standalone_archives_without_recursive_bundles(self):
        folder = self.build()
        for directory, package in (('windows-player', BUILDER.COMPANION), ('source', BUILDER.SOURCE)):
            with self.subTest(package=package):
                standalone = (folder / (package + '.zip')).read_bytes()
                embedded = folder / 'workshop-mod' / directory / (package + '.zip')
                self.assertEqual(embedded.read_bytes(), standalone)
                with zipfile.ZipFile(io.BytesIO(embedded.read_bytes())) as archive:
                    self.assertIsNone(archive.testzip())
                    names = [name.removeprefix(package + '/') for name in archive.namelist()]
                    self.assertFalse(any(name.lower().endswith('.zip') for name in names))
                    bundle_prefixes = ('windows-player/', 'source/', 'workshop-mod/', 'mod/windows-player/', 'mod/source/')
                    self.assertFalse(any(name.startswith(bundle_prefixes) for name in names))
                    for name in names:
                        BUILDER.safe_name(name)
                payload = self.payload(folder, package)
                license_data = (self.root / 'release/workshop/LICENSE-DECISION.md').read_bytes()
                self.assertEqual(payload['LICENSE-DECISION.md'], license_data)
                for name in BUILDER.WORKSHOP_DOCS:
                    self.assertEqual(payload['release/workshop/' + name], (self.root / 'release/workshop' / name).read_bytes())
        workshop = folder / 'workshop-mod'
        self.assertEqual((workshop / 'START-HERE.txt').read_bytes(), (self.root / 'release/workshop/START-HERE.txt').read_bytes())
        for source, destination in BUILDER.WORKSHOP_LAUNCHER:
            self.assertEqual((workshop / destination).read_bytes(), (self.root / source).read_bytes())
        self.assertEqual((workshop / 'windows-player/Runtime-Paths.ps1').read_bytes(), (self.root / 'Runtime-Paths.ps1').read_bytes())
        self.assertEqual(json.loads((workshop / 'windows-player/companion.json').read_bytes()), {
            'schema': 1, 'package': BUILDER.COMPANION,
            'sha256': BUILDER.sha((folder / (BUILDER.COMPANION + '.zip')).read_bytes()),
        })
        self.assertEqual((workshop / 'LICENSE-DECISION.md').read_bytes(), license_data)
        self.assertNotIn('全项目发布许可仍待作者决定', (workshop / 'THIRD-PARTY-NOTICES.md').read_text('utf-8'))

    def test_upload_archive_matches_final_workshop_tree_and_all_hashes_cover_bundles(self):
        folder = self.build()
        workshop = {
            path.relative_to(folder / 'workshop-mod').as_posix(): path.read_bytes()
            for path in (folder / 'workshop-mod').rglob('*') if path.is_file()
        }
        upload_path = folder / (BUILDER.UPLOAD + '.zip')
        BUILDER.verify_zip(upload_path, 'workshop-mod', workshop)
        with zipfile.ZipFile(upload_path) as archive:
            self.assertIsNone(archive.testzip())
            self.assertEqual({name.removeprefix('workshop-mod/'): archive.read(name) for name in archive.namelist()}, workshop)
            embedded_names = [name for name in archive.namelist() if name.lower().endswith('.zip')]
            self.assertEqual(set(embedded_names), {
                'workshop-mod/windows-player/' + BUILDER.COMPANION + '.zip',
                'workshop-mod/source/' + BUILDER.SOURCE + '.zip',
            })
            for name in embedded_names:
                self.assertEqual(archive.getinfo(name).compress_type, zipfile.ZIP_STORED)
        self.assertNotIn(upload_path.name, workshop)
        manifest = json.loads((folder / 'BUILD-MANIFEST.json').read_text('utf-8'))
        self.assertEqual(manifest['workshopMod'], BUILDER.inventory(workshop))
        checksum_lines = (folder / 'SHA256SUMS.txt').read_text('utf-8').splitlines()
        checksums = {name: digest for digest, name in (line.split('  ', 1) for line in checksum_lines)}
        expected_checksum_paths = {
            path.relative_to(folder).as_posix() for path in folder.rglob('*')
            if path.is_file() and path.name != 'SHA256SUMS.txt'
        }
        self.assertEqual(set(checksums), expected_checksum_paths)
        for name, digest in checksums.items():
            self.assertEqual(digest, BUILDER.sha((folder / name).read_bytes()))
        self.assertIn(upload_path.name, manifest['outputs'])
        for name in embedded_names:
            self.assertIn(name, manifest['outputs'])
            self.assertIn(name.removeprefix('workshop-mod/'), manifest['workshopMod'])

    def test_source_version_and_public_marker_are_required_before_output(self):
        cases = (
            ('mod/modinfo.lua', b'version = "0.5.0"\n'),
            ('mod/music_workshop_identity.json', json.dumps({**BUILDER.IDENTITY, 'id': 'unrelated-mod'}).encode('ascii')),
            ('mod/music_workshop_identity.json', json.dumps({**BUILDER.IDENTITY, 'version': '0.5.0'}).encode('ascii')),
        )
        for name, data in cases:
            with self.subTest(name=name, data=data):
                original = (self.root / name).read_bytes()
                self.write(name, data)
                try:
                    with self.assertRaises(ValueError):
                        self.build()
                    self.assertFalse((self.root / 'dist').exists())
                finally:
                    self.write(name, original)

    def test_credentials_are_rejected_without_reporting_values(self):
        secret = 'private_account_fixture_123456789'
        self.write('.state/bridge.json', json.dumps({'token': secret}).encode('ascii'))
        for encoding in ('utf-8', 'utf-16-le'):
            with self.subTest(encoding=encoding):
                self.write('helper/server.mjs', secret.encode(encoding))
                with self.assertRaises(ValueError) as error:
                    self.build()
                self.assertNotIn(secret, str(error.exception))
                self.assertIn('helper/server.mjs', str(error.exception))
                self.assertFalse((self.root / 'dist').exists())
        self.write('.state/account.json', b'{"cookie":"MUSIC_U=private_cookie_fixture_123456789; other=123"}')
        self.write('helper/server.mjs', b'private_cookie_fixture_123456789')
        with self.assertRaisesRegex(ValueError, 'Known local credential'):
            self.build()

    def test_runtime_hash_and_unsafe_inventory_paths_are_rejected(self):
        self.write('runtime/node/node.exe', b'different runtime')
        with self.assertRaisesRegex(ValueError, 'Runtime differs'):
            self.build()
        for name in ('../outside', '/outside', 'C:/outside', 'a\\b', '.state/token'):
            with self.subTest(name=name):
                self.write('runtime/RUNTIME-FILES.json', json.dumps({name: '0' * 64}).encode('ascii'))
                with self.assertRaises(ValueError):
                    self.build()
        self.assertFalse((self.root / 'dist').exists())

    def test_zip_reopen_rejects_member_or_payload_changes(self):
        path = self.root / 'verification.zip'
        expected = {'modinfo.lua': b'version = "fixture"'}
        BUILDER.write_zip(path, 'Fixture', expected)
        with zipfile.ZipFile(path, 'w') as archive:
            archive.writestr('Fixture/modinfo.lua', b'tampered')
        with self.assertRaisesRegex(ValueError, 'ZIP payload differs'):
            BUILDER.verify_zip(path, 'Fixture', expected)
        with zipfile.ZipFile(path, 'w') as archive:
            archive.writestr('Fixture/modinfo.lua', expected['modinfo.lua'])
            archive.writestr('Fixture/private-extra.txt', b'extra')
        with self.assertRaisesRegex(ValueError, 'ZIP member list differs'):
            BUILDER.verify_zip(path, 'Fixture', expected)


if __name__ == '__main__':
    unittest.main()
