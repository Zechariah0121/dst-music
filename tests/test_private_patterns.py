import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location('release_scanner', Path(__file__).resolve().parents[1] / 'tools/build-release.py')
builder = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(builder)


class QqCredentialScan(unittest.TestCase):
    def test_structured_short_and_json_escaped_secrets(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / '.state').mkdir()
            for secret in ('short-key', 'quoted"credential\\payload'):
                state = {'cookie': {'uin': '1', 'key': secret, 'renewal': {'refresh_key': 'renew-short'}}}
                (root / '.state/account-qq.json').write_text(json.dumps(state), encoding='utf-8')
                old_root = builder.ROOT
                try:
                    builder.ROOT = root
                    patterns = builder.private_patterns()
                finally:
                    builder.ROOT = old_root
                for separators in (None, (',', ':')):
                    payload = json.dumps(state, separators=separators).encode()
                    self.assertTrue(any(pattern in payload for pattern in patterns))
                    leaked = json.dumps({'key': secret}, separators=separators).encode()
                    self.assertTrue(any(pattern in leaked for pattern in patterns))
            self.assertNotIn(b'1', patterns, 'public short numeric IDs must not match every source file')


if __name__ == '__main__':
    unittest.main()
