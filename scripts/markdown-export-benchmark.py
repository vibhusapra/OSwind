#!/usr/bin/env python3
"""Synthetic text export size/scaling check; not a competitor or power benchmark."""
import argparse
import hashlib
import json
import pathlib
import re
import sqlite3
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("binary")
parser.add_argument("--count", type=int, default=20000)
parser.add_argument("--output", required=True)
options = parser.parse_args()
assert 1 <= options.count <= 1000000
binary = pathlib.Path(options.binary).resolve()
report = {"format": "OSwind synthetic Markdown export scaling v1", "records": options.count,
          "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
          "limits": ["One run; uncontrolled caches and concurrent machine activity", "Generated English text, no media, chats, models or natural desktop content", "Process RSS includes store open and SQLite snapshot; excludes harness", "No power, population tail or competitor result"]}
with tempfile.TemporaryDirectory(prefix="oswind-markdown-benchmark-") as temporary:
    root = pathlib.Path(temporary)
    library = root / "library"
    def cli(*args):
        return subprocess.run([str(binary), "--data", str(library), *map(str, args)], capture_output=True, text=True, check=True, timeout=1800).stdout
    identifier = cli("note", "Synthetic template").strip()
    connection = sqlite3.connect(library / "memory.sqlite")
    connection.execute("PRAGMA foreign_keys=ON")
    template = json.loads(connection.execute("SELECT payload FROM memories WHERE id=?", (identifier,)).fetchone()[0])
    connection.execute("DELETE FROM memories")
    now = time.time()
    def records():
        for i in range(options.count):
            identifier, title = f"synthetic-{i:07}", f"Synthetic source {i:07}"
            text = f"Unique source {i:07}. Maya owns capture; Theo owns archive. " + "This is generated desktop memory content. " * 80
            payload = dict(template, id=identifier, timestamp=now-i-978307200, app="Notes", bundleID="com.oswind.synthetic", title=title, text=text, tags=["benchmark"], regions=[])
            for name in ["embedding", "embeddingModel", "imagePath", "audioPath", "videoPath"]:
                payload.pop(name, None)
            yield (identifier, now-i, "note", "Notes", title, None, text, 0, json.dumps(payload).encode(), None, None)
    connection.executemany("INSERT INTO memories VALUES(?,?,?,?,?,?,?,?,?,?,?)", records())
    connection.commit(); connection.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    assert connection.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
    connection.close()
    report["database_bytes"] = (library / "memory.sqlite").stat().st_size
    start = time.monotonic()
    result = subprocess.run(["/usr/bin/time", "-l", str(binary), "--data", str(library), "export-markdown", str(root / "Markdown")], capture_output=True, text=True, timeout=1800)
    report["wall_seconds"] = time.monotonic()-start
    pathlib.Path(options.output).with_suffix(".process.log").write_text(result.stderr)
    assert result.returncode == 0, result.stderr
    match = re.search(r"^\s*(\d+)\s+maximum resident set size", result.stderr, re.M)
    report["peak_rss_bytes"] = int(match.group(1)) if match else None
    report["result"] = json.loads(result.stdout)
    assert report["result"]["memories"] == options.count
    files = list((root / "Markdown" / "sources").glob("*.md"))
    assert len(files) == options.count
    for i in range(options.count):
        key = hashlib.sha256(f"synthetic-{i:07}".encode()).hexdigest()
        assert f"Unique source {i:07}." in (root / "Markdown" / "sources" / (key+".md")).read_text()
    report["all_record_identity_checks_passed"] = len(files)
    report["export_bytes"] = sum(file.stat().st_size for file in (root / "Markdown").rglob("*") if file.is_file())
    report["passed"] = True
pathlib.Path(options.output).write_text(json.dumps(report, indent=2)+"\n")
print(json.dumps(report, indent=2))
