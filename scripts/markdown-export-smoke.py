#!/usr/bin/env python3
"""Portable export process contracts using only an owned generated replay library."""
import argparse
import hashlib
import json
import pathlib
import re
import subprocess
import tempfile
import urllib.parse

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("binary")
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
print("PASS: generated timed replay + cited conversation; every local link resolves; media byte identity; text-only default; existing destination preservation; source overlap refusal; current exclusion removes dependent turns; private files and staging cleanup")
