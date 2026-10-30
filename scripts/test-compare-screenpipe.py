#!/usr/bin/env python3
"""Model-free independent admission/identity/oracle checks; no vendor runtime."""
import importlib.util
import pathlib
import socket
import sqlite3
import sys
import tempfile
import unittest

path = pathlib.Path(__file__).with_name('compare-screenpipe.py')
spec = importlib.util.spec_from_file_location('comparison', path)
comparison = importlib.util.module_from_spec(spec)
spec.loader.exec_module(comparison)


class SourceIdentityTests(unittest.TestCase):
    def setUp(self):
        self.rows = [dict(id='oswbench000000', label='known', text='oswbench000000\nExact authored café.')]

    def screenpipe(self, text):
        return dict(data=[dict(type='Audio', content=dict(transcription=text))])

    def test_known_exact_text_maps_to_its_own_label(self):
        value = comparison.decode_hits('screenpipe', self.screenpipe(self.rows[0]['text']), self.rows)
        self.assertEqual(value, ['known'])

    def test_marker_cannot_hide_changed_text(self):
        with self.assertRaises(ValueError):
            comparison.decode_hits('screenpipe', self.screenpipe('oswbench000000\nChanged'), self.rows)

    def test_unknown_and_non_authored_text_refused(self):
        for text in ['oswbench000001\nUnknown', 'Normal non-authored source']:
            with self.assertRaises(ValueError):
                comparison.decode_hits('screenpipe', self.screenpipe(text), self.rows)

    def test_duplicate_identity_cannot_inflate_recall(self):
        value = self.screenpipe(self.rows[0]['text'])
        value['data'] *= 2
        with self.assertRaises(ValueError):
            comparison.decode_hits('screenpipe', value, self.rows)

    def test_source_id_and_text_must_agree(self):
        value = dict(hits=[dict(memory=dict(id='wrong', text=self.rows[0]['text']))])
        with self.assertRaises(ValueError):
            comparison.decode_hits('oswind', value, self.rows)

    def test_no_evidence_is_scored_separately_from_positive_recall(self):
        self.assertEqual(comparison.score([], []), dict(exactSet=True, recall=None, precision=None, hitAt1=None, absentReturnedEmpty=True))
        value = comparison.score(['a', 'b'], ['a', 'c'])
        self.assertEqual(value['recall'], .5)
        self.assertEqual(value['precision'], .5)
        self.assertFalse(value['exactSet'])
        self.assertTrue(value['hitAt1'])
        self.assertFalse(comparison.score(['a'], ['c', 'a'])['hitAt1'])
        self.assertFalse(comparison.score([], ['a'])['absentReturnedEmpty'])

    def test_quantiles_and_fixture_are_deterministic(self):
        self.assertEqual(comparison.quantiles([4, 1, 3, 2])['medianMS'], 2.5)
        self.assertEqual(comparison.quantiles([4, 1, 3, 2])['p95MS'], 4)
        first = comparison.corpus(64)
        self.assertEqual(first, comparison.corpus(64))
        self.assertEqual(len(first[0]), 64)
        self.assertEqual(len({row['id'] for row in first[0]}), 64)
        self.assertTrue(all('app' not in query for query in first[1]))
        self.assertTrue(all('app' in query for query in first[2]))


class IndependentStoredCorpusTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='oswind-comparison-oracle-')
        self.root = pathlib.Path(self.temporary.name)
        (self.root/'oswind/data').mkdir(parents=True)
        (self.root/'screenpipe/data/storage/owned').mkdir(parents=True)
        self.other_path = self.root/'screenpipe/data/storage/owned/index.sqlite'
        self.rows = [dict(id='oswbench000000', label='known', text='oswbench000000\nExact text')]
        with sqlite3.connect(self.root/'oswind/data/memory.sqlite') as db:
            db.execute('CREATE TABLE memories(id TEXT PRIMARY KEY,text TEXT,embedding BLOB)')
            db.execute('INSERT INTO memories(id,text) VALUES (?,?)', (self.rows[0]['id'], self.rows[0]['text']))
        with sqlite3.connect(self.other_path) as db:
            db.execute('CREATE TABLE audio_transcriptions(id INTEGER PRIMARY KEY,transcription TEXT,_archive_file INTEGER,_archive_mask INTEGER DEFAULT 1,_archive_generation INTEGER,_archive_digest BLOB)')
            db.execute('INSERT INTO audio_transcriptions(id,transcription) VALUES (1,?)', (self.rows[0]['text'],))
            db.execute('CREATE TABLE audio_chunks(file_path TEXT)')
            db.execute("INSERT INTO audio_chunks VALUES ('')")
            for table in ['frames', 'ui_events', '_bulk_element_lookup']:
                db.execute('CREATE TABLE '+table+'(id INTEGER)')

    def tearDown(self):
        self.temporary.cleanup()

    def test_exact_stored_originals_qualify(self):
        result = comparison.audit_sources(self.root, self.rows)
        self.assertTrue(result['originalTextsByteEqual'])
        self.assertEqual(result['mediaFiles'], 0)

    def test_silent_source_change_invalidates_run(self):
        with sqlite3.connect(self.other_path) as db:
            db.execute("UPDATE audio_transcriptions SET transcription='changed'")
        with self.assertRaises(ValueError):
            comparison.audit_sources(self.root, self.rows)

    def test_archived_payload_cannot_use_staging_only_oracle(self):
        with sqlite3.connect(self.other_path) as db:
            db.execute('UPDATE audio_transcriptions SET _archive_file=1')
        with self.assertRaises(ValueError):
            comparison.audit_sources(self.root, self.rows)

    def test_unexpected_capture_or_media_invalidates_run(self):
        with sqlite3.connect(self.other_path) as db:
            db.execute('INSERT INTO frames VALUES (1)')
        with self.assertRaises(ValueError):
            comparison.audit_sources(self.root, self.rows)
        with sqlite3.connect(self.other_path) as db:
            db.execute('DELETE FROM frames')
        (self.root/'screenpipe/data/unexpected.wav').write_bytes(b'authored-fault')
        with self.assertRaises(ValueError):
            comparison.audit_sources(self.root, self.rows)


@unittest.skipUnless(sys.platform == 'darwin', 'macOS sandbox negative control')
class PermissionBoundaryTests(unittest.TestCase):
    def test_metadata_allowance_is_rejected_before_vendor_start(self):
        if any(comparison.permission_ipc_status(name) != 0 for name in comparison.CONTROL_IPC):
            self.skipTest('Permission/Metadata service is not reachable for parent baseline')
        with tempfile.TemporaryDirectory(prefix='oswind-owned-metadata-control-', dir=pathlib.Path.home()) as temporary:
            root = pathlib.Path(temporary)
            allowed = root/'allowed'
            allowed.mkdir()
            (allowed/'tmp').mkdir()
            profile = root/'metadata-allowed.sb'
            original = (comparison.ROOT/'scripts/comparisons/screenpipe-backend.sb').read_text()
            changed = original.replace('|metadata', '')
            self.assertNotEqual(original, changed)
            profile.write_text(changed)
            with self.assertRaises(ValueError):
                comparison.sandbox_canary(pathlib.Path('/usr/bin/true'), allowed, comparison.port_available(0),
                                          pathlib.Path('/usr/bin/true'), root/'outside.txt', profile=profile)

    def test_valid_canary_leaves_api_port_immediately_bindable_without_reuse(self):
        if any(comparison.permission_ipc_status(name) != 0 for name in comparison.CONTROL_IPC):
            self.skipTest('Permission/Metadata service is not reachable for parent baseline')
        with tempfile.TemporaryDirectory(prefix='oswind-owned-port-control-', dir=pathlib.Path.home()) as temporary:
            root = pathlib.Path(temporary)
            allowed = root/'allowed'
            allowed.mkdir()
            (allowed/'tmp').mkdir()
            port = comparison.port_available(0)
            result = comparison.sandbox_canary(pathlib.Path('/usr/bin/true'), allowed, port,
                                               pathlib.Path('/usr/bin/true'), root/'outside.txt')
            self.assertTrue(all(result.values()))
            with socket.socket() as server:
                server.bind(('127.0.0.1', port))

    def test_overescaped_ipc_policy_is_rejected_before_vendor_start(self):
        if any(comparison.permission_ipc_status(name) != 0 for name in comparison.CONTROL_IPC):
            self.skipTest('Permission/Metadata service is not reachable for parent baseline')
        with tempfile.TemporaryDirectory(prefix='oswind-owned-ipc-control-', dir=pathlib.Path.home()) as temporary:
            root = pathlib.Path(temporary)
            allowed = root/'allowed'
            allowed.mkdir()
            (allowed/'tmp').mkdir()
            profile = root/'invalid.sb'
            original = (comparison.ROOT/'scripts/comparisons/screenpipe-backend.sb').read_text()
            changed = original.replace('com\\.apple\\.', 'com\\\\.apple\\\\.')
            self.assertNotEqual(original, changed)
            profile.write_text(changed)
            with self.assertRaises(ValueError):
                comparison.sandbox_canary(pathlib.Path('/usr/bin/true'), allowed, comparison.port_available(0),
                                          pathlib.Path('/usr/bin/true'), root/'outside.txt', profile=profile)


if __name__ == '__main__':
    unittest.main()
