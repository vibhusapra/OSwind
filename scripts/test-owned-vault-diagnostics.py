#!/usr/bin/env python3
"""Offline owned-boundary and bounded-reader contracts; no native images needed."""
import json
import os
import pathlib
import plistlib
import subprocess
import sys
import tempfile
import unittest
import unittest.mock as mock
import uuid

from owned_vault_diagnostics import OwnedVaultDiagnostics, command, parse_readers


class Diagnostics(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='owned-vault-diagnostic-contract-')
        self.addCleanup(self.temporary.cleanup)
        self.parent = pathlib.Path(self.temporary.name).resolve()
        self.diagnostic = OwnedVaultDiagnostics.create(self.parent / 'fixture', b'OWNED-FIXTURE-CREDENTIAL', 'a' * 64)
        self.root = self.diagnostic.root
        self.package = self.root / 'Busy.oswindvault'
        self.package.mkdir(mode=0o700)
        self.calls = []
        self.leaf = str(uuid.uuid4())
        self.mount = self.package / '.mounts' / self.leaf
        self.mount.mkdir(parents=True)
        self.original_stat = pathlib.Path.stat
        real = self.mount.stat()
        fields = list(real)
        fields[2] += 1
        self.stamp = os.stat_result(fields)
        self.session = dict(mountLeaf=self.leaf, phase='closing', rootDevice=self.stamp.st_dev,
                            rootInode=self.stamp.st_ino, device='/dev/disk123s1')
        self.write_session()

    def write_session(self):
        (self.package / 'session.json').write_text(json.dumps(self.session))

    def fake_stat(self, path, *args, **kwargs):
        return self.stamp if path == self.mount else self.original_stat(path, *args, **kwargs)

    def output(self, stdout=b'', status=0, **changes):
        return dict(status=status, stdout=stdout, stderr=b'', timedOut=False, clipped=False, seconds=.01, **changes)

    def run_tool(self, argv):
        self.calls.append(argv)
        if argv[0] == '/usr/bin/hdiutil':
            return self.output(plistlib.dumps({'images': [
                {'image-path': str(self.parent / 'UNRELATED-PRIVATE-IMAGE'), 'system-entities': []},
                {'image-path': str(self.package / 'contents.sparsebundle'), 'system-entities': [
                    {'mount-point': str(self.mount), 'dev-entry': '/dev/disk123s1'}]}]}))
        return self.output(('p123\0cOwnedReader\0\nf7\0tREG\0D%x\0i9\0n%s/Library/memory.sqlite\0\n' %
                            (self.stamp.st_dev, self.mount)).encode())

    def capture(self, run=None):
        with mock.patch.object(pathlib.Path, 'stat', lambda p, *a, **k: self.fake_stat(p, *a, **k)):
            return self.diagnostic.capture(self.package, run=run or self.run_tool)

    def test_observes_only_owned_filesystem_and_redacts_paths(self):
        result = self.capture()
        self.assertEqual(result['readers'][0]['path'], '<owned-mount>/Library/memory.sqlite')
        self.assertEqual(result['readers'][0]['pid'], 123)
        self.assertNotIn(str(self.root), json.dumps(result))
        self.assertNotIn('UNRELATED-PRIVATE-IMAGE', json.dumps(result))
        self.assertEqual(self.calls[1], ['/usr/sbin/lsof', '-nP', '-F0pcfntDi', '+f', '--', str(self.mount)])

    def test_existing_root_cannot_be_rebranded_owned(self):
        with self.assertRaises(FileExistsError):
            OwnedVaultDiagnostics.create(self.root, b'other', 'a' * 64)

    def test_changed_root_identity_refuses_before_native_query(self):
        self.root.rename(self.parent / 'old')
        self.root.mkdir(mode=0o700)
        with self.assertRaises(ValueError):
            self.capture()
        self.assertFalse(self.calls)

    def test_symlink_marker_is_not_read(self):
        marker = self.root / 'owned-fixture.json'
        original = marker.read_bytes()
        marker.unlink()
        outside = self.parent / 'outside'
        outside.write_bytes(original)
        marker.symlink_to(outside)
        with self.assertRaises(OSError):
            self.capture()
        self.assertFalse(self.calls)

    def test_modified_marker_and_permissions_refuse_before_native_query(self):
        (self.root / 'owned-fixture.json').write_text('{}')
        with self.assertRaises(ValueError):
            self.capture()
        (self.root / 'owned-fixture.json').write_bytes(self.diagnostic.marker)
        self.root.chmod(0o755)
        with self.assertRaises(ValueError):
            self.capture()
        self.root.chmod(0o700)
        self.assertFalse(self.calls)

    def test_unrelated_package_or_symlink_is_not_inspected(self):
        for package in [self.parent, self.root / 'Other.oswindvault']:
            with self.assertRaises(ValueError):
                self.diagnostic.capture(package, run=self.run_tool)
        self.package.rename(self.root / 'old-package')
        self.package.symlink_to(self.root / 'old-package')
        with self.assertRaises(ValueError):
            self.diagnostic.capture(self.package, run=self.run_tool)
        self.assertFalse(self.calls)

    def test_unmounted_directory_is_never_queried_as_host_filesystem(self):
        self.session.update(rootDevice=self.mount.stat().st_dev)
        self.write_session()
        with self.assertRaises(ValueError):
            self.diagnostic.capture(self.package, run=self.run_tool)
        self.assertFalse(self.calls)

    def test_unknown_inventory_never_implies_absence_or_runs_reader_query(self):
        result = self.capture(lambda argv: self.output(status=2))
        self.assertIn('unknown', result['mountObservation'])
        self.assertNotIn('readers', result)

    def test_other_image_and_wrong_mount_do_not_authorize_reader_query(self):
        result = self.capture(lambda argv: self.output(plistlib.dumps({'images': []})))
        self.assertIn('not confirmed', result['mountObservation'])
        self.assertNotIn('readers', result)

    def test_reader_scope_requires_both_exact_device_and_mount_prefix(self):
        data = b'p123\0cOwned\0f3\0D2\0n/owned/m/file\0f4\0D1\0n/PRIVATE/file\0f5\0D1\0n/owned/m/../PRIVATE\0f6\0D1\0n/owned/m/file\0'
        values = parse_readers(data, pathlib.Path('/owned/m'), 1)
        self.assertEqual([v['descriptor'] for v in values], ['6'])
        self.assertNotIn('PRIVATE', json.dumps(values))

    def test_reader_process_and_descriptor_boundaries_do_not_mix(self):
        data = b'p1\0cFirst\0f3\0D1\0n/owned/file\0\np2\0cSecond\0f4\0D1\0n/owned/other\0'
        result = parse_readers(data, pathlib.Path('/owned'), 1)
        self.assertEqual([(r['pid'], r['command']) for r in result], [(1, 'First'), (2, 'Second')])

    def test_reader_count_is_bounded_and_private_var_alias_is_normalized(self):
        data = b'p1\0cOwned\0' + b'f3\0D1\0n/var/folders/owned/memory.sqlite\0' * 300
        result = parse_readers(data, pathlib.Path('/private/var/folders/owned'), 1)
        self.assertEqual(len(result), 256)
        self.assertEqual(result[0]['path'], '<owned-mount>/memory.sqlite')

    def test_credential_bearing_reader_metadata_refuses_persistence(self):
        def run(argv):
            result = self.run_tool(argv)
            if argv[0].endswith('lsof'):
                result['stdout'] = result['stdout'].replace(b'OwnedReader', self.diagnostic.secret)
            return result
        with self.assertRaises(ValueError):
            self.capture(run)

    def test_failure_receipt_keeps_original_status_binary_and_refusal_without_exception_text(self):
        self.session['mountLeaf'] = '../PRIVATE'
        self.write_session()
        path = self.diagnostic.save_failure(self.package, 'lock', 16, stderr=b'owned native failure', run=self.run_tool)
        result = json.loads(path.read_text())
        self.assertEqual(result['exitCode'], 16)
        self.assertEqual(result['binarySHA256'], 'a' * 64)
        self.assertEqual(result['diagnosticRefused'], 'ValueError')
        self.assertNotIn('PRIVATE', path.read_text())
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_secret_output_refuses_receipt_and_does_not_run_native_query(self):
        with self.assertRaises(ValueError):
            self.diagnostic.save_failure(self.package, 'lock', 16, stdout=self.diagnostic.secret, run=self.run_tool)
        self.assertFalse(self.calls)
        self.assertFalse(list(self.root.glob('failure-*')))

    def test_reported_native_exit_and_signal_are_separate_from_cli_status(self):
        self.session['mountLeaf'] = '../invalid'
        self.write_session()
        path = self.diagnostic.save_failure(self.package, 'lock', 1,
            stderr=b'owned hdiutil exit 16; owned diskutil signal 2', run=self.run_tool)
        result = json.loads(path.read_text())
        self.assertEqual(result['exitCode'], 1)
        self.assertEqual(result['reportedNativeOutcomes'], [dict(tool='hdiutil', termination='exit', status=16), dict(tool='diskutil', termination='signal', status=2)])

    def test_cli_failure_does_not_invent_a_native_outcome(self):
        self.session['mountLeaf'] = '../invalid'
        self.write_session()
        path = self.diagnostic.save_failure(self.package, 'lock', 16, stderr=b'owned failure without native status', run=self.run_tool)
        self.assertEqual(json.loads(path.read_text())['reportedNativeOutcomes'], [])

    def test_query_timeout_is_bounded_and_owned_child_is_reaped(self):
        result = command([sys.executable, '-c', 'import time;time.sleep(10)'], timeout=.1)
        self.assertTrue(result['timedOut'])
        self.assertLess(result['seconds'], 3)
        self.assertNotEqual(result['status'], 0)

    def test_query_output_is_bounded_and_clipped_output_is_explicit(self):
        result = command([sys.executable, '-c', 'import os;os.write(1,b"x"*10000)'], limit=100)
        self.assertTrue(result['clipped'])
        self.assertLessEqual(len(result['stdout']) + len(result['stderr']), 100)


if __name__ == '__main__':
    unittest.main()
