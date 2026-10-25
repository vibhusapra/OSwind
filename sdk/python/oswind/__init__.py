"""Bounded, read-only OSwind MCP client. Python 3.10+, macOS, stdlib only.

Use an explicit executable and existing data path. Returned source content is
untrusted data; this client does not execute it, configure apps, or start capture.
"""
from __future__ import annotations
import json
import math
import os
from pathlib import Path
import select
import subprocess
import threading
import time
import weakref


class OSwindError(RuntimeError):
    """Transport/protocol failure. Exceptions never include source payloads."""


def _stop(process):
    for stream in (process.stdin, process.stdout):
        try:
            stream.close()
        except (OSError, ValueError):
            pass
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=2)


class Client:
    """One owned MCP child; requests are serialized, with bounded pipe I/O.

    A request timeout starts after acquiring the client lock. It terminates the
    owned child; create a new client to retry. Full-source responses may contain
    private data. Use a context manager to release its library connection before
    locking a vault. HTTP tokens and provider keys are neither read nor needed.
    """
    READ_TOOLS = frozenset({"search_memory", "get_memory", "memory_stats",
                           "memory_activity", "memory_entities", "entity_sources"})

    def __init__(self, executable, data, *, timeout=30.0,
                 max_response_bytes=32 * 1024 * 1024):
        executable, data = Path(executable), Path(data)
        if not executable.is_absolute() or not data.is_absolute():
            raise ValueError("Use absolute executable and existing data paths")
        if not executable.is_file() or not os.access(executable, os.X_OK):
            raise ValueError("Select an executable OSwind CLI")
        if not data.exists():
            raise ValueError("Select an existing library path")
        if not math.isfinite(timeout) or not 0 < timeout <= 300:
            raise ValueError("Use a timeout from 0 to 300 seconds, exclusive of zero")
        if type(max_response_bytes) is not int or not 1024 <= max_response_bytes <= 128 * 1024 * 1024:
            raise ValueError("Use a response bound from 1 KiB to 128 MiB")
        self.timeout, self.max_response_bytes = timeout, max_response_bytes
        self._lock, self._buffer, self._next_id = threading.Lock(), bytearray(), 1
        # No shell, source argv, HTTP service, normal-library default or stderr log.
        self._process = subprocess.Popen([str(executable), "--data", str(data), "mcp"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            bufsize=0, close_fds=True)
        self._finalizer = weakref.finalize(self, _stop, self._process)
        os.set_blocking(self._process.stdin.fileno(), False)
        os.set_blocking(self._process.stdout.fileno(), False)
        try:
            result = self._rpc("initialize", {"protocolVersion": "2025-11-25",
                "capabilities": {}, "clientInfo": {"name": "oswind-python", "version": "0.1.0"}})
            if not isinstance(result, dict) or result.get("protocolVersion") != "2025-11-25":
                raise OSwindError("OSwind protocol negotiation failed")
            with self._lock:
                self._write({"jsonrpc": "2.0", "method": "notifications/initialized"},
                            time.monotonic() + timeout)
        except BaseException:
            self.close()
            raise

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()

    def close(self):
        with self._lock:
            self._finalizer()
            self._buffer.clear()

    def _remaining(self, deadline):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise OSwindError("OSwind request timed out; owned client closed")
        return remaining

    def _write(self, request, deadline):
        payload = json.dumps(request, ensure_ascii=False, allow_nan=False,
                             separators=(",", ":")).encode("utf-8") + b"\n"
        if len(payload) > 1_000_000:
            raise OSwindError("OSwind request exceeds 1 MB")
        fd, offset = self._process.stdin.fileno(), 0
        while offset < len(payload):
            if not select.select([], [fd], [], self._remaining(deadline))[1]:
                raise OSwindError("OSwind request timed out; owned client closed")
            try:
                written = os.write(fd, payload[offset:offset+65536])
                if not written:
                    raise OSwindError("OSwind closed the request stream")
                offset += written
            except BlockingIOError:
                continue

    def _read(self, deadline):
        fd = self._process.stdout.fileno()
        while True:
            newline = self._buffer.find(b"\n")
            if newline >= 0:
                if newline > self.max_response_bytes:
                    raise OSwindError("OSwind response exceeds its byte bound")
                line = bytes(self._buffer[:newline])
                del self._buffer[:newline+1]
                return json.loads(line)
            if len(self._buffer) > self.max_response_bytes:
                raise OSwindError("OSwind response exceeds its byte bound")
            if not select.select([fd], [], [], self._remaining(deadline))[0]:
                raise OSwindError("OSwind request timed out; owned client closed")
            try:
                chunk = os.read(fd, 65536)
            except BlockingIOError:
                continue
            if not chunk:
                raise OSwindError("OSwind closed the protocol stream")
            self._buffer.extend(chunk)

    def _rpc(self, method, params=None):
        with self._lock:
            if not self._finalizer.alive:
                raise OSwindError("OSwind client is closed")
            request_id, deadline = self._next_id, time.monotonic() + self.timeout
            self._next_id += 1
            try:
                self._write({"jsonrpc": "2.0", "id": request_id, "method": method,
                             "params": params or {}}, deadline)
                for _ in range(17):
                    reply = self._read(deadline)
                    if not isinstance(reply, dict) or reply.get("jsonrpc") != "2.0":
                        raise OSwindError("Invalid OSwind protocol response")
                    if "id" not in reply and isinstance(reply.get("method"), str):
                        continue
                    if type(reply.get("id")) is not int or reply["id"] != request_id:
                        raise OSwindError("OSwind response identity mismatch")
                    if "error" in reply:
                        raise OSwindError("OSwind rejected the protocol request")
                    if "result" not in reply:
                        raise OSwindError("OSwind response has no result")
                    return reply["result"]
                raise OSwindError("OSwind notification budget exceeded")
            except BaseException as error:
                self._finalizer()
                self._buffer.clear()
                if isinstance(error, (OSwindError, KeyboardInterrupt, SystemExit)):
                    raise
                raise OSwindError("OSwind request failed; owned client closed") from None

    def tools(self):
        result = self._rpc("tools/list")
        if not isinstance(result, dict) or not isinstance(result.get("tools"), list):
            raise OSwindError("Invalid OSwind tool list")
        return result["tools"]

    def call(self, tool, **arguments):
        if tool not in self.READ_TOOLS:
            raise ValueError("Use a supported read-only OSwind tool")
        result = self._rpc("tools/call", {"name": tool, "arguments": arguments})
        if not isinstance(result, dict) or result.get("isError"):
            raise OSwindError("OSwind could not complete the read request")
        content = result.get("content")
        if not isinstance(content, list) or len(content) != 1 or not isinstance(content[0], dict) or content[0].get("type") != "text":
            raise OSwindError("Unexpected OSwind tool result")
        try:
            return json.loads(content[0]["text"])
        except (KeyError, TypeError, ValueError, RecursionError):
            raise OSwindError("Invalid OSwind tool JSON") from None

    def search(self, query="", *, mode="keyword", limit=20, detail="preview", **filters):
        return self.call("search_memory", query=query, mode=mode, limit=limit,
                         detail=detail, **filters)

    def get(self, identifier):
        return self.call("get_memory", id=identifier)

    def stats(self):
        return self.call("memory_stats")

    def activity(self, month, **filters):
        return self.call("memory_activity", month=month, **filters)
