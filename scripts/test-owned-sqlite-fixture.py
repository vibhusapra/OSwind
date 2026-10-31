#!/usr/bin/env python3
"""Offline refusal contracts for disabled capture fixture setup; no disk/history."""
import sqlite3
import unittest
from owned_sqlite_fixture import register_inactive_sync_fixture


class FixtureFunctions(unittest.TestCase):
    def connection(self, state="0,0"):
        db = sqlite3.connect(":memory:")
        self.addCleanup(db.close)
        db.executescript("""
            PRAGMA user_version=25;
            CREATE TABLE personal_sync_capture(enabled INTEGER,suppressed INTEGER);
            CREATE TABLE source(id INTEGER);
            CREATE TRIGGER capture AFTER INSERT ON source
            WHEN (SELECT enabled FROM personal_sync_capture)=1
            BEGIN SELECT oswind_sync_key_v1(new.id),oswind_sync_row_v1(new.id); END;
        """)
        db.execute("INSERT INTO personal_sync_capture VALUES(" + state + ")")
        return db

    def test_disabled_setup_works_without_executing_callbacks(self):
        db = self.connection()
        with self.assertRaisesRegex(sqlite3.OperationalError, "no such function"):
            db.execute("INSERT INTO source VALUES(1)")
        register_inactive_sync_fixture(db)
        db.execute("INSERT INTO source VALUES(2)")
        self.assertEqual(db.execute("SELECT id FROM source").fetchall(), [(2,)])

    def test_callbacks_always_refuse_instead_of_fabricating_frames(self):
        db = self.connection()
        register_inactive_sync_fixture(db)
        for name in ("oswind_sync_key_v1", "oswind_sync_row_v1"):
            with self.assertRaises(sqlite3.OperationalError):
                db.execute("SELECT " + name + "('authored')")

    def test_later_activation_cannot_turn_helper_into_writer(self):
        db = self.connection()
        register_inactive_sync_fixture(db)
        db.execute("UPDATE personal_sync_capture SET enabled=1")
        with self.assertRaises(sqlite3.OperationalError):
            db.execute("INSERT INTO source VALUES(3)")
        self.assertEqual(db.execute("SELECT COUNT(*) FROM source").fetchone(), (0,))

    def test_active_suppressed_missing_or_duplicate_state_refuses(self):
        for state in ("1,0", "0,1"):
            with self.subTest(state=state):
                db = self.connection(state)
                with self.assertRaises(ValueError):
                    register_inactive_sync_fixture(db)
        for sql in ("DELETE FROM personal_sync_capture", "INSERT INTO personal_sync_capture VALUES(0,0)"):
            db = self.connection()
            db.execute(sql)
            with self.assertRaises(ValueError):
                register_inactive_sync_fixture(db)

    def test_older_schema_does_not_gain_functions(self):
        db = self.connection()
        db.execute("PRAGMA user_version=24")
        register_inactive_sync_fixture(db)
        with self.assertRaisesRegex(sqlite3.OperationalError, "no such function"):
            db.execute("SELECT oswind_sync_key_v1(1)")

    def test_schema26_marker_allows_inactive_setup_and_refuses_later_state_changes(self):
        db = self.connection()
        db.execute("PRAGMA user_version=26")
        db.execute("CREATE TRIGGER writer BEFORE INSERT ON source BEGIN SELECT oswind_historical_writer_v1(); END")
        register_inactive_sync_fixture(db)
        db.execute("INSERT INTO source VALUES(1)")
        with self.assertRaises(sqlite3.OperationalError):
            db.execute("SELECT oswind_sync_source_revision_v1(1)")
        for enabled, suppressed in [(1, 0), (0, 1), (1, 1)]:
            db.execute("UPDATE personal_sync_capture SET enabled=?,suppressed=?", (enabled, suppressed))
            with self.assertRaises(sqlite3.OperationalError):
                db.execute("INSERT INTO source VALUES(2)")
        self.assertEqual(db.execute("SELECT id FROM source").fetchall(), [(1,)])
        db.execute("UPDATE personal_sync_capture SET enabled=0,suppressed=0")
        db.execute("PRAGMA user_version=27")
        with self.assertRaises(sqlite3.OperationalError):
            db.execute("INSERT INTO source VALUES(3)")

    def test_unknown_future_schema_does_not_gain_fixture_functions(self):
        db = self.connection()
        db.execute("PRAGMA user_version=27")
        with self.assertRaises(ValueError):
            register_inactive_sync_fixture(db)
        with self.assertRaises(sqlite3.OperationalError):
            db.execute("SELECT oswind_sync_row_v1(1)")


if __name__ == "__main__":
    unittest.main()
