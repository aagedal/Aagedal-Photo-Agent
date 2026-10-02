#!/usr/bin/env python3
"""Exercise production authorization preferences across independent macOS processes.

Compiles the actual value types and MCPAuthorizationStore from MCPServerCore.swift
into a small command-line fixture. A warm reader stays alive while short-lived
writers revoke and regrant authority in a unique test-only CFPreferences domain.
Never reads or writes the application's preferences domain or user photos.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import selectors
import subprocess
import sys
import tempfile
import uuid


DRIVER = r'''
let arguments = CommandLine.arguments
guard arguments.count == 3, arguments[1].hasPrefix("com.aagedal.mcp-authorization-probe.") else {
    fatalError("An isolated probe domain and fixture root are required")
}
let suite = arguments[1]
let root = URL(fileURLWithPath: arguments[2], isDirectory: true)
let photo = root.appendingPathComponent("frame.jpg")
let store = MCPAuthorizationStore(preferencesSuiteName: suite)
while let command = readLine() {
    var response: [String: Any] = [:]
    do {
        switch command {
        case "grant":
            _ = try store.addRoot(root)
            try store.setEnabled(true)
        case "disable": try store.setEnabled(false)
        case "removeRoot":
            for grant in try store.load().roots { try store.removeRoot(id: grant.id) }
        case "failedGrant":
            // A real dirty CFPreferences cache with an injected failed flush. The first
            // synchronization succeeds; the next sees the newly pending grant and fails.
            var configuration = MCPAuthorizationConfiguration()
            configuration.isEnabled = true
            let bytes = try JSONEncoder().encode(configuration)
            try MCPAuthorizationStore.writePreferences(bytes, in: suite, synchronize: { name in
                let domain = name as CFString
                if CFPreferencesCopyAppValue(MCPServerConstants.configurationKey as CFString, domain) != nil {
                    return false
                }
                return CFPreferencesAppSynchronize(domain)
            })
        case "corrupt", "wrongType", "delete":
            let value: CFPropertyList?
            if command == "delete" { value = nil }
            else if command == "corrupt" { value = Data("invalid-json".utf8) as CFData }
            else { value = "invalid-type" as CFString }
            CFPreferencesSetAppValue(MCPServerConstants.configurationKey as CFString, value, suite as CFString)
            guard CFPreferencesAppSynchronize(suite as CFString) else {
                throw MCPAuthorizationStore.PersistenceError.writeFailed
            }
        case "read": break
        default: fatalError("Unknown probe command")
        }
        let configuration = try store.load()
        response["enabled"] = configuration.isEnabled
        response["revision"] = configuration.authorizationRevision?.uuidString ?? "absent"
        response["rootCount"] = configuration.roots.count
        do {
            _ = try store.authorizeExistingPath(photo.path)
            response["authorization"] = "admitted"
        } catch MCPAuthorizationError.disabled { response["authorization"] = "disabled" }
          catch MCPAuthorizationError.outsideAuthorizedRoots { response["authorization"] = "outsideRoots" }
          catch { response["authorization"] = "error" }
    } catch MCPAuthorizationError.invalidConfiguration {
        response = ["error": "invalidConfiguration"]
    } catch MCPAuthorizationStore.PersistenceError.writeFailed {
        // Flush the cleared cache through the normal production reader before exiting,
        // then an independent process verifies no unacknowledged grant was persisted.
        response = ["error": "writeFailed", "enabledAfterRefresh": try store.load().isEnabled]
    } catch {
        response = ["error": "persistenceOrAuthorizationFailure"]
    }
    let bytes = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
    FileHandle.standardOutput.write(bytes + Data([10]))
}
'''


def production_fixture(source):
    """Use exact production declarations; marker changes intentionally fail the probe."""
    boundaries = [
        ("nonisolated enum MCPServerConstants", "/// The input-format catalog"),
        ("nonisolated struct MCPFileIdentity", "/// Stable across rename"),
        ("nonisolated struct MCPAuthorizedRoot", "/// A process-wide filesystem reservation"),
        ("nonisolated struct MCPAuthorizationStore", "nonisolated protocol MCPToolServing"),
    ]
    declarations = []
    for start, end in boundaries:
        position = source.index(start)
        declarations.append(source[position:source.index(end, position)])
    return "import Darwin\nimport CoreFoundation\nimport Foundation\n" + "\n".join(declarations) + DRIVER


class Reader:
    def __init__(self, executable, suite, root):
        self.process = subprocess.Popen([str(executable), suite, str(root)], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)

    def read(self):
        self.process.stdin.write(b"read\n")
        self.process.stdin.flush()
        if not self.selector.select(timeout=15):
            raise RuntimeError("Warm authorization reader timed out")
        line = self.process.stdout.readline()
        if not line:
            raise RuntimeError("Warm authorization reader exited unexpectedly")
        return json.loads(line)

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=5)
            raise
        finally:
            self.selector.close()
        error = self.process.stderr.read()
        self.process.stdout.close()
        self.process.stderr.close()
        if self.process.returncode or error:
            raise RuntimeError("Authorization reader did not exit cleanly")


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def probe(repo):
    require(sys.platform == "darwin", "CFPreferences probe requires macOS")
    source = (repo / "Aagedal Photo Agent/Services/Automation/MCPServerCore.swift").read_text()
    fixture = production_fixture(source)
    suite = "com.aagedal.mcp-authorization-probe." + str(uuid.uuid4())
    evidence = {"sourceSHA256": hashlib.sha256(source.encode()).hexdigest(), "checks": []}
    with tempfile.TemporaryDirectory(prefix="apa-authority-probe-", dir="/private/tmp") as directory:
        folder = Path(directory).resolve()
        swift = folder / "main.swift"
        executable = folder / "authorization-probe"
        swift.write_text(fixture)
        # Keep generated compiler caches within the disposable fixture directory.
        environment = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(folder / "module-cache"))
        subprocess.run(["xcrun", "swiftc", "-swift-version", "6", str(swift), "-o", str(executable)],
                       env=environment, check=True, timeout=90, capture_output=True)
        root = folder / "photos"
        root.mkdir()
        (root / "frame.jpg").write_bytes(b"probe-photo")

        def writer(command):
            result = subprocess.run([str(executable), suite, str(root)], input=(command + "\n").encode(),
                                    capture_output=True, check=True, timeout=15)
            require(not result.stderr, "Authorization writer unexpectedly wrote diagnostics: " +
                    result.stderr.decode(errors="replace"))
            return json.loads(result.stdout)

        reader = Reader(executable, suite, root)
        try:
            require(reader.read()["authorization"] == "disabled", "Missing preferences admitted authority")
            writer("grant")
            granted = reader.read()
            require(granted["authorization"] == "admitted", "Warm reader missed a fresh grant")
            evidence["checks"].append("grant-after-warm-disabled-cache")
            writer("disable")
            require(reader.read()["authorization"] == "disabled", "Warm reader retained revoked enablement")
            evidence["checks"].append("disable-after-warm-granted-cache")
            writer("grant")
            regranted = reader.read()
            require(regranted["authorization"] == "admitted" and regranted["revision"] != granted["revision"],
                    "Regrant did not publish a fresh generation")
            evidence["checks"].append("regrant-rotates-persisted-revision")
            writer("disable")
            writer("grant")
            require(reader.read()["revision"] != regranted["revision"],
                    "An unobserved revoke/regrant restored retained authority")
            evidence["checks"].append("unobserved-revoke-regrant-invalidates-retained-generation")
            writer("removeRoot")
            require(reader.read()["authorization"] == "outsideRoots", "Warm reader retained a removed root")
            evidence["checks"].append("root-removal-after-warm-granted-cache")
            for command in ("corrupt", "wrongType"):
                writer("grant")
                require(reader.read()["authorization"] == "admitted", "Pre-corruption grant failed")
                writer(command)
                require(reader.read() == {"error": "invalidConfiguration"}, "Invalid preferences admitted stale authority")
                evidence["checks"].append(command + "-refuses-warm-authority")
                writer("delete")
            writer("grant")
            require(reader.read()["authorization"] == "admitted", "Pre-deletion grant failed")
            writer("delete")
            require(reader.read()["authorization"] == "disabled", "Deleted preferences retained warm authority")
            evidence["checks"].append("deletion-refuses-warm-authority")
            require(writer("failedGrant") == {"error": "writeFailed", "enabledAfterRefresh": False},
                    "Failed persistence left an enabled dirty grant in the writer")
            require(reader.read()["authorization"] == "disabled", "Failed grant was published to another process")
            evidence["checks"].append("failed-flush-discards-dirty-grant-before-refresh")
            writer("grant")
            durable = reader.read()
            restarted = Reader(executable, suite, root)
            try:
                require(restarted.read() == durable, "Fresh process lost durable authorization generation")
                evidence["checks"].append("fresh-process-observes-durable-generation")
            finally:
                restarted.close()
        finally:
            try:
                reader.close()
            finally:
                require(writer("delete").get("authorization") == "disabled",
                        "Could not remove the isolated authorization preference")
    return evidence


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    arguments = parser.parse_args()
    try:
        evidence = probe(Path(__file__).resolve().parents[2])
    except subprocess.CalledProcessError as error:
        sys.stderr.write(error.stderr.decode(errors="replace") if error.stderr else str(error))
        raise SystemExit(1)
    if arguments.output:
        arguments.output.parent.mkdir(parents=True, exist_ok=True)
        arguments.output.write_text(json.dumps(evidence, indent=2) + "\n")
    print(json.dumps(evidence, indent=2))


if __name__ == "__main__":
    main()
