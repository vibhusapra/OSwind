#!/usr/bin/env python3
"""Offline asset admission tests; no real model downloads or inference."""
import hashlib, importlib.util, io, pathlib, tempfile, unittest
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('pii_assets', ROOT/'benchmarks/prototypes/pii/prepare-assets.py')
assets = importlib.util.module_from_spec(spec)
spec.loader.exec_module(assets)

class Assets(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.path = pathlib.Path(self.temporary.name)/'model.onnx'
        self.item = {'path': 'model.onnx', 'bytes': 5, 'sha256': hashlib.sha256(b'owned').hexdigest()}

    def test_missing_asset_requires_explicit_download_and_does_not_touch_network(self):
        with patch.object(assets.urllib.request, 'urlopen', side_effect=AssertionError('network')):
            self.assertEqual(assets.fetch(self.path, self.item, 'https://unused.test', False), 'missing')
        self.assertFalse(self.path.exists())

    def test_existing_verified_asset_needs_no_network(self):
        self.path.write_bytes(b'owned')
        with patch.object(assets.urllib.request, 'urlopen', side_effect=AssertionError('network')):
            self.assertEqual(assets.fetch(self.path, self.item, 'https://unused.test', True), 'verified')

    def test_existing_changed_asset_is_preserved(self):
        self.path.write_bytes(b'other')
        with patch.object(assets.urllib.request, 'urlopen', side_effect=AssertionError('network')):
            with self.assertRaisesRegex(ValueError, 'differs'):
                assets.fetch(self.path, self.item, 'https://unused.test', True)
        self.assertEqual(self.path.read_bytes(), b'other')

    def test_download_verifies_size_and_digest_before_exclusive_admission(self):
        with patch.object(assets.urllib.request, 'urlopen', return_value=io.BytesIO(b'owned')):
            self.assertEqual(assets.fetch(self.path, self.item, 'https://unused.test', True), 'downloaded')
        self.assertEqual(self.path.read_bytes(), b'owned')
        self.assertEqual(list(self.path.parent.iterdir()), [self.path])

    def test_truncated_overlong_and_wrong_digest_downloads_leave_no_assets(self):
        for data in (b'own', b'owned extra', b'other'):
            with self.subTest(data=data), patch.object(assets.urllib.request, 'urlopen', return_value=io.BytesIO(data)):
                with self.assertRaises(ValueError):
                    assets.fetch(self.path, self.item, 'https://unused.test', True)
            self.assertEqual(list(self.path.parent.iterdir()), [])

    def test_stage_never_replaces_changed_preparation_files(self):
        assets.put(self.path, b'owned'); assets.put(self.path, b'owned')
        with self.assertRaises(ValueError):
            assets.put(self.path, b'changed')
        self.assertEqual(self.path.read_bytes(), b'owned')

if __name__ == '__main__':
    unittest.main()
