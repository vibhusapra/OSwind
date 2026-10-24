#!/usr/bin/env python3
"""Strict phrase/Boolean/literal/Ask contracts across owned CLI, HTTP and MCP data."""
import argparse
import json
import pathlib
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("binary")
options = parser.parse_args()
binary = pathlib.Path(options.binary).resolve()
with tempfile.TemporaryDirectory(prefix="oswind-expression-contract-") as temporary:
    root = pathlib.Path(temporary)
    library = root / "library"
    source = root / "input.json"
    fixture = [
        ("exact", "Frame 21. Maya owns archive launch. alpha beta", "Notes"),
        ("gap", "Frame number 21. Theo owns archive unrelated launch. alpha gamma", "Other"),
        ("prefix", "Frame 210. Jo reviews archive and launches. beta", "Notes"),
        ("comet", "Comet only. gamma", "Other"),
    ]
    source.write_text(json.dumps([dict(id=identifier, timestamp="2026-10-23T20:00:00Z", kind="note", app=app, bundleID="com.oswind.synthetic", title=identifier, text=text, favorite=False, tags=[], regions=[]) for identifier, text, app in fixture]))

    def cli(*args, ok=True):
        result = subprocess.run([str(binary), "--data", str(library), *map(str, args)], capture_output=True, text=True, timeout=90)
        assert (result.returncode == 0) == ok, (args, result.stderr)
        return result.stdout

    def ids(rows):
        return {row["memory"]["id"] for row in rows}

    cli("import", source)
    cases = [
        ('"Frame 21"', {"exact"}),
        ('“Frame 21”', {"exact"}),
        ('"archive launch"', {"exact"}),
        ("alpha AND (beta OR gamma)", {"exact", "gap"}),
        ("(alpha OR beta) NOT gamma", {"exact", "prefix"}),
        ('"Frame 21" app:Other', set()),
    ]
    for query, expected in cases:
        assert ids(json.loads(cli("search", "--mode", "keyword", query))) == expected, query
    assert ids(json.loads(cli("search", "--mode", "keyword", "--literal", '"Frame 21"'))) == {"exact", "gap", "prefix"}
    for query in ['"unclosed', "alpha AND", "alpha OR NOT beta"]:
        cli("search", "--mode", "keyword", query, ok=False)
    answer = json.loads(cli("ask", "--provider", "evidence", '"archive launch"'))
    assert ids(answer["sources"]) == {"exact"}
    chat = json.loads(cli("chat", "new"))
    first = json.loads(cli("chat", "ask", chat["id"], "--provider", "evidence", '"archive launch"'))
    assert ids(first["answer"]["sources"]) == {"exact"}
    followup = json.loads(cli("chat", "ask", chat["id"], "--provider", "evidence", "archive AND owns app:Other"))
    assert ids(followup["answer"]["sources"]) == {"gap"}
    server = subprocess.Popen([str(binary), "--data", str(library), "serve"], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        tokenpath = library / "api-token"
        for _ in range(200):
            if tokenpath.exists():
                break
            assert server.poll() is None
            time.sleep(.05)
        token = tokenpath.read_text()

        def http(query, literal=False):
            params = urllib.parse.urlencode(dict(query=query, mode="keyword", literal=str(literal).lower()))
            request = urllib.request.Request("http://127.0.0.1:47831/v1/search?"+params, headers={"Authorization": "Bearer "+token})
            try:
                with urllib.request.urlopen(request, timeout=15) as response:
                    return response.status, json.load(response)
            except urllib.error.HTTPError as error:
                return error.code, json.load(error)
        for _ in range(200):
            try:
                status, result = http('"Frame 21"')
                break
            except urllib.error.URLError:
                assert server.poll() is None
                time.sleep(.05)
        assert status == 200 and ids(result["hits"]) == {"exact"}
        for query, expected in cases:
            status, result = http(query)
            assert status == 200 and ids(result["hits"]) == expected, (query, result)
        status, result = http('"Frame 21"', literal=True)
        assert status == 200 and ids(result["hits"]) == {"exact", "gap", "prefix"}
        for query in ['"unclosed', "alpha AND", "alpha OR NOT beta"]:
            assert http(query)[0] == 400, query
    finally:
        server.terminate()
        try:
            server.wait(timeout=5)
        except subprocess.TimeoutExpired:
            server.kill(); server.wait(timeout=5)
        server.stdout.close(); server.stderr.close()
    requests = [dict(jsonrpc="2.0", id=1, method="initialize", params={"protocolVersion": "2025-11-25"}), dict(jsonrpc="2.0", method="notifications/initialized")]
    for i, (query, _) in enumerate(cases, 2):
        requests.append(dict(jsonrpc="2.0", id=i, method="tools/call", params={"name": "search_memory", "arguments": {"query": query, "mode": "keyword"}}))
    requests += [dict(jsonrpc="2.0", id=20, method="tools/call", params={"name": "search_memory", "arguments": {"query": '"Frame 21"', "mode": "keyword", "literal": True}}), dict(jsonrpc="2.0", id=21, method="tools/call", params={"name": "search_memory", "arguments": {"query": "alpha AND", "mode": "keyword"}})]
    process = subprocess.run([str(binary), "--data", str(library), "mcp"], input="\n".join(map(json.dumps, requests))+"\n", text=True, capture_output=True, check=True, timeout=90)
    responses = {row["id"]: row for row in map(json.loads, process.stdout.splitlines())}
    for i, (_, expected) in enumerate(cases, 2):
        result = json.loads(responses[i]["result"]["content"][0]["text"])
        assert ids(result["hits"]) == expected
    assert ids(json.loads(responses[20]["result"]["content"][0]["text"])["hits"]) == {"exact", "gap", "prefix"}
    assert responses[21]["result"]["isError"] is True
    assert "operator" in responses[21]["result"]["content"][0]["text"].lower()
    assert json.loads(cli("stats"))["count"] == 4
print("PASS: strict phrases/Boolean precedence/scopes/literal escape and typed errors across CLI/HTTP/MCP; current Ask constraint plus follow-up without inherited old constraints; source counts preserved")
