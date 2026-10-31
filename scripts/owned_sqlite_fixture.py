"""Connection names needed by disabled capture triggers in authored test fixtures.

Call only for a library the caller just created as its owned scratch fixture.
This is not a sync writer: callbacks always fail, and active/suppressed capture is
refused. Passing setup DML proves that disabled triggers never execute a callback.
Product writers register the real bounded framing functions in Swift.
"""


def register_inactive_sync_fixture(connection):
    version = connection.execute("PRAGMA user_version").fetchone()[0]
    if version < 25:
        return
    if version not in (25, 26):
        raise ValueError("Unsupported owned fixture schema")
    state = connection.execute(
        "SELECT enabled,suppressed FROM personal_sync_capture"
    ).fetchall()
    if state != [(0, 0)]:
        raise ValueError("Fixture setup requires disabled, unsuppressed sync capture")

    def refuse(*_):
        raise ValueError("Inactive fixture callback must never execute")

    # SQLite resolves function names when compiling even a disabled trigger.
    for name in ("oswind_sync_key_v1", "oswind_sync_row_v1"):
        connection.create_function(name, -1, refuse, deterministic=True)

    if version == 26:
        # Name resolution is eager even when the indexed no-history guard is
        # false. Never fabricate a source revision for a historical owner.
        connection.create_function("oswind_sync_source_revision_v1", 1, refuse, deterministic=True)

    # The v26 compatibility marker is deliberately implemented only after this
    # caller-owned, inactive fixture check. It grants no sync or archival API.
    if version == 26:
        def writer_marker():
            if connection.execute("PRAGMA user_version").fetchone() != (26,) or connection.execute(
                "SELECT enabled,suppressed FROM personal_sync_capture"
            ).fetchall() != [(0, 0)]:
                raise ValueError("Fixture marker requires unchanged inactive schema26")
            return 1
        connection.create_function("oswind_historical_writer_v1", 0, writer_marker)
