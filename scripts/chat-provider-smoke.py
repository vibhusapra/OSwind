#!/usr/bin/env python3
"""Offline Ollama contract through real CLI processes; no paid provider or keys."""
import argparse, json, pathlib, subprocess, tempfile, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

parser = argparse.ArgumentParser()
parser.add_argument("binary", nargs="?", default=".build/debug/oswindctl")
binary = pathlib.Path(parser.parse_args().binary).resolve()
model = "oswind-offline-chat:fixture"
state = {"limited": False, "requests": []}

class Fixture(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def send_json(self, body):
        data = json.dumps(body).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
    def do_GET(self):
        assert self.path == "/api/tags", self.path
        self.send_json({"models": [{"name": model, "digest": "offline-chat-fixture", "size": 1}]})
    def do_POST(self):
        assert self.path == "/api/chat", self.path
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        state["requests"].append(body)
        self.send_json({"message": {"role": "assistant", "content": "unfinished planning" if state["limited"] else "Lina owns the launch checklist [1]."}, "done": True, "done_reason": "length" if state["limited"] else "stop"})

server = ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    with tempfile.TemporaryDirectory(prefix="oswind-chat-provider-") as directory:
        prefix = [str(binary), "--data", directory]
        endpoint = "http://127.0.0.1:" + str(server.server_port)
        options = ["--provider", "ollama", "--model", model, "--endpoint", endpoint]
        def cli(*args, check=True): return subprocess.run(prefix + list(args), text=True, capture_output=True, timeout=30, check=check)
        cli("note", "Launch checklist: Lina is the owner; deadline Thursday.")
        session = json.loads(cli("chat", "new").stdout)["id"]
        first_question = "Who owns the launch checklist?"
        first = json.loads(cli("chat", "ask", session, *options, first_question).stdout)
        assert "Lina" in first["answer"]["text"]
        assert first_question in state["requests"][0]["messages"][-1]["content"]
        state["limited"] = True
        failed = cli("chat", "ask", session, *options, "And its deadline?", check=False)
        assert failed.returncode != 0 and "output limit" in failed.stderr
        assert len(json.loads(cli("chat", "show", session).stdout)["turns"]) == 1
        assert first_question not in state["requests"][-1]["messages"][-1]["content"]
        state["limited"] = False
        requests_before = len(state["requests"])
        empty = json.loads(cli("ask", *options, "--app", "Excluded fixture app", first_question).stdout)
        assert empty["sources"] == [] and len(state["requests"]) == requests_before
        answer = json.loads(cli("ask", *options, "--app", "OSwind", first_question).stdout)
        assert "Lina" in answer["text"] and answer["provider"] == "ollama"
        assert all(request["model"] == model for request in state["requests"])
        assert all("--model" not in request["messages"][-1]["content"] and endpoint not in request["messages"][-1]["content"] for request in state["requests"])
        print("PASS: explicit local model/endpoint, current-question prompt, scoped one-off Ask, output-limit failure and no partial chat persistence")
finally:
    server.shutdown(); server.server_close()
