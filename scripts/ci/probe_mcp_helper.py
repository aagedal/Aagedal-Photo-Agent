#!/usr/bin/env python3
"""Read-only persistent-pipe smoke test for a built Photo Agent MCP executable.

Does not change automation preferences, authorize folders, or open user photos.
Checks the real transport before EOF, including pipelined messages and malformed input.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import selectors
import subprocess
import time


class Connection:
    def __init__(self, executable):
        self.process = subprocess.Popen([str(executable)], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.selector.register(self.process.stderr, selectors.EVENT_READ)
        self.buffer = bytearray()

    def send(self, *messages):
        for message in messages:
            data = message if isinstance(message, bytes) else json.dumps(message).encode()
            self.process.stdin.write(data + b"\n")
        self.process.stdin.flush()

    def receive(self, expected_id, timeout=10):
        deadline = time.monotonic() + timeout
        while b"\n" not in self.buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise RuntimeError("Helper response timed out while STDIN remained open")
            for key, _ in self.selector.select(remaining):
                chunk = os.read(key.fileobj.fileno(), 65536)
                if key.fileobj is self.process.stderr:
                    if chunk:
                        raise RuntimeError("Helper unexpectedly wrote to STDERR")
                    self.selector.unregister(key.fileobj)
                elif not chunk:
                    raise RuntimeError("Helper closed STDOUT before completing the request")
                else:
                    self.buffer.extend(chunk)
                    if len(self.buffer) > 1_048_576:
                        raise RuntimeError("Helper exceeded the response bound")
        line, _, rest = self.buffer.partition(b"\n")
        self.buffer = bytearray(rest)
        value = json.loads(line)
        if value.get("jsonrpc") != "2.0" or value.get("id") != expected_id:
            raise RuntimeError("Unexpected JSON-RPC response identity")
        return value

    def finish(self):
        self.process.stdin.close()
        self.process.wait(timeout=10)
        if self.process.returncode or self.buffer or self.process.stdout.read() or self.process.stderr.read():
            raise RuntimeError("Helper did not exit cleanly with empty protocol streams")

    def close(self):
        if self.process.poll() is None:
            self.process.kill()
            self.process.wait(timeout=10)
        self.selector.close()
        for stream in (self.process.stdin, self.process.stdout, self.process.stderr):
            stream.close()


def request(identifier, method, params=None):
    result = {"jsonrpc": "2.0", "id": identifier, "method": method}
    if params is not None:
        result["params"] = params
    return result


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def probe(executable):
    connection = Connection(executable)
    try:
        connection.send(request(1, "initialize", {
            "protocolVersion": "2025-11-25", "capabilities": {},
            "clientInfo": {"name": "photo-agent-release-probe", "version": "1"},
        }))
        initialized = connection.receive(1)
        require(initialized["result"]["protocolVersion"] == "2025-11-25", "Protocol negotiation failed")
        connection.send({"jsonrpc": "2.0", "method": "notifications/initialized"},
                        request(2, "tools/list", {}), request(3, "ping"))
        tools = connection.receive(2)["result"]["tools"]
        require(connection.receive(3)["result"] == {}, "Pipelined ping failed")
        names = [tool["name"] for tool in tools]
        require(len(names) == len(set(names)), "Duplicate tool identifiers")
        for tool in tools:
            require(tool["annotations"]["readOnlyHint"] is (tool["name"] != "create_team"),
                    "Incorrect read-only annotation")
            require(tool["annotations"]["destructiveHint"] is False, "Unexpected destructive tool")
        require("create_team" in names, "Missing team creation")
        require("get_iptc_patch_plan" in names, "Missing plan retrieval")
        require("commit_iptc_patch" not in names, "Update probe when verified mutation ships")
        connection.send(b"{invalid-json", request(4, "unsupported-probe-method"), request(5, "ping"))
        require(connection.receive(None)["error"]["code"] == -32700, "Malformed JSON was not refused")
        require(connection.receive(4)["error"]["code"] == -32601, "Unknown method was not refused")
        require(connection.receive(5)["result"] == {}, "Transport did not recover after invalid input")
        require("list_transcription_providers" in names, "Missing transcription provider discovery")
        connection.send(request(6, "tools/call", {"name": "list_transcription_providers", "arguments": {}}))
        catalog_result = connection.receive(6)["result"]
        require(catalog_result.get("isError") is False, "Provider discovery failed")
        catalog = catalog_result["structuredContent"]
        require(catalog["transcriptionToolsAvailable"] is False, "Unexpected transcription execution")
        providers = catalog["providers"]
        require({provider["id"] for provider in providers} == {"appleSpeech", "customWhisper"},
                "Unexpected provider identities")
        for provider in providers:
            require(provider["runtimeAvailability"] == "unknown" and
                    provider["transcriptionCallable"] is False, "Catalog overclaims runtime readiness")
        connection.send(request(7, "tools/call", {
            "name": "list_transcription_providers", "arguments": {"execute": True},
        }))
        refused = connection.receive(7)["result"]
        require(refused["isError"] is True and refused["structuredContent"]["code"] == "invalid_arguments",
                "Provider discovery accepted unexpected arguments")
        connection.finish()
        return {"helperSHA256": hashlib.sha256(executable.read_bytes()).hexdigest(),
                "toolCount": len(tools), "toolNames": names, "beforeEOF": True,
                "pipelinedRequests": True, "malformedInputRecovery": True,
                "providerDiscovery": True, "providerArgumentRefusal": True,
                "exit": 0, "stderrBytes": 0}
    finally:
        connection.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("helper", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    result = probe(args.helper.resolve(strict=True))
    encoded = json.dumps(result, indent=2) + "\n"
    if args.output:
        args.output.write_text(encoded)
    print(encoded, end="")


if __name__ == "__main__":
    main()
