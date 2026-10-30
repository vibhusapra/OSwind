#!/usr/bin/env python3
"""Independent physical payload oracle faults; requires pinned developer Arrow."""
import hashlib
import pathlib
import sqlite3
import tempfile
import unittest
import pyarrow as pa
import pyarrow.parquet as pq
from screenpipe_oracle import text_rows


class ParquetOracleTests(unittest.TestCase):
    def setUp(self):
        self.assertEqual(pa.__version__, '21.0.0')
        self.temporary = tempfile.TemporaryDirectory(prefix='oswind-authored-parquet-')
        self.root = pathlib.Path(self.temporary.name)
        self.data = self.root/'data'
        self.data.mkdir()
        self.path = self.data/'payload.parquet'
        self.index = self.data/'index.sqlite'
        self.text = 'oswbench000000\nAuthored café and exact punctuation.'
        with sqlite3.connect(self.index) as db:
            db.execute('CREATE TABLE audio_transcriptions(id INTEGER PRIMARY KEY,transcription TEXT,_archive_file INTEGER,_archive_mask INTEGER,_archive_generation INTEGER,_archive_digest BLOB)')
            db.execute('CREATE TABLE _bulk_files(id INTEGER PRIMARY KEY,table_name TEXT,path TEXT,checksum TEXT,state TEXT,rows INTEGER)')
            db.execute("INSERT INTO audio_transcriptions VALUES (1,'',7,0,1,?)", (hashlib.sha256(self.text.encode()).digest(),))
        self.payload([dict(id=1, generation=1, transcription=self.text)])

    def tearDown(self):
        self.temporary.cleanup()

    def payload(self, rows):
        schema = pa.schema([('id', pa.int64()), ('generation', pa.int64()), ('transcription', pa.string())])
        pq.write_table(pa.Table.from_pylist(rows, schema=schema), self.path)
        with sqlite3.connect(self.index) as db:
            db.execute('DELETE FROM _bulk_files')
            db.execute("INSERT INTO _bulk_files VALUES (7,'audio_transcriptions','payload.parquet',?,'published',?)",
                       (hashlib.sha256(self.path.read_bytes()).hexdigest(), len(rows)))

    def read(self):
        return text_rows(self.index, self.data, use_parquet=True)

    def test_physical_payload_and_inline_row_reconstruct_exact_identities(self):
        with sqlite3.connect(self.index) as db:
            db.execute("INSERT INTO audio_transcriptions VALUES (2,'inline authored text',NULL,1,NULL,NULL)")
        rows, info = self.read()
        self.assertEqual(rows, [(1, self.text), (2, 'inline authored text')])
        self.assertEqual(info['archivedRows'], 1)
        self.assertEqual(info['inlineRows'], 1)
        self.assertEqual(len(info['payloadFiles']), 1)

    def test_file_corruption_cannot_pass_index_checksum(self):
        with self.path.open('ab') as stream:
            stream.write(b'authored corruption')
        with self.assertRaisesRegex(ValueError, 'SHA256'):
            self.read()

    def test_wrong_generation_and_text_digest_are_rejected(self):
        self.payload([dict(id=1, generation=2, transcription=self.text)])
        with self.assertRaisesRegex(ValueError, 'generation'):
            self.read()
        self.payload([dict(id=1, generation=1, transcription='changed text')])
        with self.assertRaisesRegex(ValueError, 'digest'):
            self.read()

    def test_duplicate_row_id_cannot_replace_an_omitted_identity(self):
        with sqlite3.connect(self.index) as db:
            db.execute("INSERT INTO audio_transcriptions VALUES (2,'',7,0,1,?)", (hashlib.sha256(b'second').digest(),))
        self.payload([dict(id=1, generation=1, transcription=self.text), dict(id=1, generation=1, transcription=self.text)])
        with self.assertRaisesRegex(ValueError, 'Duplicate'):
            self.read()

    def test_path_escape_and_symlink_are_refused(self):
        outside = self.root/'outside.parquet'
        outside.write_bytes(self.path.read_bytes())
        with sqlite3.connect(self.index) as db:
            db.execute("UPDATE _bulk_files SET path='../outside.parquet'")
        with self.assertRaisesRegex(ValueError, 'path'):
            self.read()
        with sqlite3.connect(self.index) as db:
            db.execute("UPDATE _bulk_files SET path='payload.parquet'")
        self.path.unlink()
        self.path.symlink_to(outside)
        with self.assertRaisesRegex(ValueError, 'symlink'):
            self.read()

    def test_partial_overlay_and_unpublished_file_are_refused(self):
        with sqlite3.connect(self.index) as db:
            db.execute('UPDATE audio_transcriptions SET _archive_mask=1')
        with self.assertRaisesRegex(ValueError, 'overlay'):
            self.read()
        with sqlite3.connect(self.index) as db:
            db.execute('UPDATE audio_transcriptions SET _archive_mask=0')
            db.execute("UPDATE _bulk_files SET state='encoding'")
        with self.assertRaisesRegex(ValueError, 'unpublished'):
            self.read()

    def test_non_regular_payload_is_refused_without_blocking(self):
        import os
        self.path.unlink()
        os.mkfifo(self.path)
        with self.assertRaisesRegex(ValueError, 'regular'):
            self.read()


if __name__ == '__main__':
    unittest.main()
