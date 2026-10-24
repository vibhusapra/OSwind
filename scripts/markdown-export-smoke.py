#!/usr/bin/env python3
"""Portable export process contracts using only an owned generated replay library."""
import argparse
import hashlib
import json
import pathlib
import re
import os
import select
import signal
import sqlite3
import subprocess
import tempfile
import time
import urllib.parse

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("binary")
parser.add_argument("--interruptions", action="store_true")
options = parser.parse_args()
binary = pathlib.Path(options.binary).resolve()
with tempfile.TemporaryDirectory(prefix="oswind-markdown-contract-") as temporary:
    root = pathlib.Path(temporary)
    library = root / "probe" / "library"

    def cli(*args, ok=True):
        result = subprocess.run([str(binary), "--data", str(library), *map(str, args)], capture_output=True, text=True, timeout=90)
        assert (result.returncode == 0) == ok, (args, result.stderr)
        return result.stdout

    cli("probe-visual-replay", "--output", root / "probe", "--frames", "2", "--software")
    memory = json.loads(cli("search", "--mode", "keyword", "archive"))[0]["memory"]
    session = json.loads(cli("chat", "new"))
    answer = json.loads(cli("chat", "ask", session["id"], "--provider", "evidence", "Who owns archive?"))
    assert answer["answer"]["sources"], answer
    text_folder = root / "text"
    text = json.loads(cli("export-markdown", text_folder))
    assert text["memories"] == text["conversations"] == text["turns"] == 1 and text["mediaFiles"] == 0
    assert not (text_folder / "media").exists()
    destination = root / "media"
    media = json.loads(cli("export-markdown", destination, "--include-media"))
    assert media["mediaFiles"] == 2 and media["mediaBytes"] > 0
    key = hashlib.sha256(memory["id"].encode()).hexdigest()
    source = destination / "sources" / (key + ".md")
    page = source.read_text()
    assert "## Sampled replay frames" in page and "Frame token: visual-001" in page
    assert (destination / "media" / (key + "-video.mov")).read_bytes() == (library / memory["videoPath"]).read_bytes()
    assert (destination / "media" / (key + "-image.jpg")).read_bytes() == (library / memory["imagePath"]).read_bytes()
    for markdown in destination.rglob("*.md"):
        for relative in re.findall(r"\]\(([^)]+)\)", markdown.read_text()):
            assert (markdown.parent / urllib.parse.unquote(relative)).is_file(), (markdown, relative)
    original = hashlib.sha256((destination / "index.md").read_bytes()).hexdigest()
    cli("export-markdown", destination, ok=False)
    assert hashlib.sha256((destination / "index.md").read_bytes()).hexdigest() == original
    cli("export-markdown", library / "must-not-export-inside", ok=False)
    settings = json.loads(cli("config"))
    settings["privacy"]["excludedApps"].append(memory["bundleID"])
    (library / "settings.json").write_text(json.dumps(settings))
    excluded_folder = root / "excluded"
    excluded = json.loads(cli("export-markdown", excluded_folder, "--include-media"))
    assert excluded["memories"] == excluded["turns"] == excluded["mediaFiles"] == 0
    assert excluded["excludedMemories"] == excluded["excludedTurns"] == 1
    assert not (excluded_folder / "sources").exists() and not (excluded_folder / "media").exists()
    assert "Who owns archive?" not in next((excluded_folder / "conversations").glob("*.md")).read_text()
    assert all(path.stat().st_mode & 0o077 == 0 for path in destination.rglob("*"))
    assert not list(root.glob(".oswind-markdown-*")) and not list(root.glob(".oswind-job-*"))
    if options.interruptions:
        settings["privacy"]["excludedApps"].remove(memory["bundleID"])
        (library / "settings.json").write_text(json.dumps(settings))
        connection = sqlite3.connect(library / "memory.sqlite")
        template = json.loads(connection.execute("SELECT payload FROM memories LIMIT 1").fetchone()[0])
        now = time.time()
        def records():
            for i in range(5000):
                identifier = f"interrupt-{i}"
                text = "Synthetic interrupt-only source. " * 50
                value = dict(template, id=identifier, timestamp=now-i-978307200, kind="note", app="Notes", title=identifier, text=text, bundleID="com.oswind.synthetic")
                for key in ["visualRecording", "imagePath", "videoPath", "audioPath", "embedding", "embeddingModel"]:
                    value.pop(key, None)
                yield (identifier, now-i, "note", "Notes", identifier, None, text, 0, json.dumps(value).encode(), None, None)
        connection.executemany("INSERT INTO memories VALUES(?,?,?,?,?,?,?,?,?,?,?)", records()); connection.commit(); connection.close()
        for signum in [signal.SIGINT, signal.SIGKILL]:
            partial = root / ("interrupt-"+str(signum))
            process = subprocess.Popen([str(binary), "--data", str(library), "export-markdown", str(partial)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                observed = b""
                deadline = time.monotonic()+60
                while b"Exporting sources" not in observed:
                    assert time.monotonic() < deadline and process.poll() is None, observed
                    if select.select([process.stderr], [], [], .1)[0]:
                        observed += os.read(process.stderr.fileno(), 65536)
                process.send_signal(signum)
                stdout, stderr = process.communicate(timeout=30)
                assert process.returncode == (130 if signum == signal.SIGINT else -signal.SIGKILL), (process.returncode, observed+stderr)
                assert not partial.exists() and not stdout
                if signum == signal.SIGINT:
                    assert b"Operation cancelled" in stderr, stderr
                else:
                    assert list(root.glob(".oswind-markdown-*")), "Expected unpublished killed job"
                    cli("backup", "cleanup", "--directory", root)
                assert not list(root.glob(".oswind-markdown-*")) and not list(root.glob(".oswind-job-*"))
            finally:
                if process.poll() is None:
                    process.kill(); process.wait(timeout=5)
                process.stdout.close(); process.stderr.close()
        assert json.loads(cli("stats"))["count"] == 5001
        print("PASS: actual SIGINT exits130 with no output; SIGKILL leaves only leased staging, reclaimed by cleanup; source counts preserved")
print("PASS: generated timed replay + cited conversation; every local link resolves; media byte identity; text-only default; existing destination preservation; source overlap refusal; current exclusion removes dependent turns; private files and staging cleanup")
