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
