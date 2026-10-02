#!/usr/bin/env python3
"""Exercise the production signed native handoff with disposable synthetic peers.

Requires an explicit Apple signing certificate for production team 3R5QGG9DW6.
Never changes app preferences, opens photos, grants consent, or invokes providers.
This qualifies local signature/audit-token transport, not distribution signing or
the actual app's native consent pipeline. All harnesses and sockets are removed.
"""

import argparse
import json
import os
from pathlib import Path
import plistlib
import selectors
import shutil
import subprocess
import tempfile


REVIEW_ID = "11111111-1111-4111-8111-111111111111"
LINKED_ID = "22222222-2222-4222-8222-222222222222"
EPOCH = "33333333-3333-4333-8333-333333333333"
OPERATION = "44444444-4444-4444-8444-444444444444"
REFUSAL_REASONS = {"invalidMessage", "invalidResponse", "unsafeEndpoint", "endpointOccupied",
                   "authenticationRequired", "unpairedExecutable", "unavailable", "timedOut",
                   "stopped", "unknownFailure"}

HARNESS = r'''
import Darwin
import Foundation

@main struct NativeInvocationProbe {
    struct RawProtocolFailure: Error {}
    static func rawFrame(_ descriptor: Int32) throws -> Data {
        var frame = Data()
        while frame.count <= AutomationNativeInvocationChannel.maximumMessageBytes {
            var byte: UInt8 = 0
            let count = Darwin.recv(descriptor, &byte, 1, 0)
            if count == 0 {
                guard frame.isEmpty else { throw RawProtocolFailure() }
                throw AutomationNativeInvocationChannel.Failure.authenticationRequired
            }
            if count < 0 {
                if errno == EINTR { continue }
                // A timeout or malformed handshake must never qualify a negative.
                throw RawProtocolFailure()
            }
            if byte == 10 {
                guard !frame.isEmpty else { throw RawProtocolFailure() }
                return frame
            }
            frame.append(byte)
        }
        throw RawProtocolFailure()
    }
    static func refusedReason(_ error: any Error) -> String {
        guard let failure = error as? AutomationNativeInvocationChannel.Failure else { return "unknownFailure" }
        switch failure {
        case .invalidMessage: return "invalidMessage"
        case .invalidResponse: return "invalidResponse"
        case .unsafeEndpoint: return "unsafeEndpoint"
        case .endpointOccupied: return "endpointOccupied"
        case .authenticationRequired: return "authenticationRequired"
        case .unpairedExecutable: return "unpairedExecutable"
        case .unavailable: return "unavailable"
        case .timedOut: return "timedOut"
        case .stopped: return "stopped"
        }
    }
    static func emit(_ data: Data) {
        FileHandle.standardOutput.write(data + Data([10]))
    }
    static func rawServer(_ directory: URL) throws {
        // A deliberately untrusted endpoint running the other correctly signed
        // app. The production Client must authenticate that actual kernel peer
        // before releasing any request handles. This is solely a negative fixture.
        guard Darwin.mkdir(directory.path, 0o700) == 0 else { throw RawProtocolFailure() }
        let socketPath = directory.appendingPathComponent("review.sock").path
        let listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw RawProtocolFailure() }
        defer { Darwin.close(listener); Darwin.unlink(socketPath); Darwin.rmdir(directory.path) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let path = Array(socketPath.utf8) + [0]
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw RawProtocolFailure() }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, Darwin.chmod(socketPath, 0o600) == 0,
              Darwin.listen(listener, 1) == 0 else { throw RawProtocolFailure() }
        emit(Data("{\"ready\":true}".utf8))
        let peer = Darwin.accept(listener, nil, nil)
        guard peer >= 0 else { throw RawProtocolFailure() }
        defer { Darwin.close(peer) }
        var timeout = timeval(tv_sec: 4, tv_usec: 0)
        guard setsockopt(peer, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            throw RawProtocolFailure()
        }
        var yes: Int32 = 1
        _ = setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        let greeting = Data("{\"schemaVersion\":1,\"status\":\"peerAccepted\"}\n".utf8)
        let sent = greeting.withUnsafeBytes { Darwin.send(peer, $0.baseAddress!, $0.count, 0) }
        guard sent == greeting.count else { throw RawProtocolFailure() }
        var bytes = [UInt8](repeating: 0, count: 513)
        let count = bytes.withUnsafeMutableBytes { Darwin.recv(peer, $0.baseAddress!, $0.count, 0) }
        // Never print received bytes. A clean close with zero bytes independently
        // proves the production client kept both opaque request handles private.
        guard count >= 0 else { throw RawProtocolFailure() }
        emit(try JSONSerialization.data(withJSONObject: ["observedRequestBytes": count], options: [.sortedKeys]))
    }
    static func main() {
        do {
            let args = CommandLine.arguments
            guard args.count >= 3 else { throw AutomationNativeInvocationChannel.Failure.invalidMessage }
            let directory = URL(fileURLWithPath: args[2], isDirectory: true)
            if args[1] == "raw-server" {
                try rawServer(directory)
                return
            }
            if args[1] == "server" {
                let listener = try AutomationNativeInvocationChannel.Listener(directory: directory) { request in
                    guard request.requestEpoch.uuidString.lowercased() == "33333333-3333-4333-8333-333333333333" else {
                        return try .init(status: .unavailable)
                    }
                    if request.requestID.uuidString.lowercased() == "22222222-2222-4222-8222-222222222222" {
                        return try .init(status: .linkedOperation,
                            operationID: UUID(uuidString: "44444444-4444-4444-8444-444444444444")!)
                    }
                    return try .init(status: .reviewRequired)
                }
                try listener.start()
                emit(Data("{\"ready\":true}".utf8))
                while readLine() != nil {}
                listener.stop()
                return
            }
            guard args.count == 5, let requestID = UUID(uuidString: args[3]),
                  let epoch = UUID(uuidString: args[4]) else {
                throw AutomationNativeInvocationChannel.Failure.invalidMessage
            }
            let request = AutomationNativeInvocationChannel.Request(requestID: requestID, requestEpoch: epoch)
            if args[1] == "raw" {
                // Negative peer probes bypass no production checks: the real listener
                // must reject this process through its kernel audit-token signature.
                let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
                guard fd >= 0 else { throw AutomationNativeInvocationChannel.Failure.unavailable }
                defer { Darwin.close(fd) }
                var timeout = timeval(tv_sec: 4, tv_usec: 0)
                _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                var yes: Int32 = 1
                _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
                var address = sockaddr_un()
                address.sun_family = sa_family_t(AF_UNIX)
                address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
                let path = Array(directory.appendingPathComponent("review.sock").path.utf8) + [0]
                guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else {
                    throw AutomationNativeInvocationChannel.Failure.unsafeEndpoint
                }
                withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
                let connected = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }
                guard connected == 0 else { throw AutomationNativeInvocationChannel.Failure.unavailable }
                let greeting = try rawFrame(fd)
                guard greeting == Data("{\"schemaVersion\":1,\"status\":\"peerAccepted\"}".utf8) else {
                    throw RawProtocolFailure()
                }
                let payload = try request.encoded() + Data([10])
                let sent = payload.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!, $0.count, 0) }
                if sent != payload.count {
                    if sent < 0 && errno == EPIPE { throw AutomationNativeInvocationChannel.Failure.authenticationRequired }
                    throw RawProtocolFailure()
                }
                let frame = try rawFrame(fd)
                let response: AutomationNativeInvocationChannel.Response
                do { response = try AutomationNativeInvocationChannel.Response.decode(frame) }
                catch { throw RawProtocolFailure() }
                // The receipt keeps the accepted connection alive through the real
                // client's final peer/witness check. Send only after a valid final
                // response; its presence never turns a negative into a refusal.
                let receipt = Data("{\"schemaVersion\":1,\"status\":\"peerReceipt\"}\n".utf8)
                let acknowledged = receipt.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!, $0.count, 0) }
                guard acknowledged == receipt.count else { throw RawProtocolFailure() }
                emit(try response.encoded())
            } else {
                let client = try AutomationNativeInvocationChannel.Client(directory: directory)
                emit(try client.invoke(request, timeout: 3).encoded())
            }
        } catch {
            // No signature, certificate identity, private path or arbitrary error
            // text escapes the harness. Exit distinguishes refusal from acceptance.
            if error is RawProtocolFailure {
                emit(Data("{\"probeProtocolFailure\":true}".utf8))
                Darwin.exit(3)
            } else if CommandLine.arguments.dropFirst().first != "raw" {
                emit(try! JSONSerialization.data(withJSONObject: ["refused": true, "refusedReason": refusedReason(error)],
                                                  options: [.sortedKeys]))
            } else {
                emit(Data("{\"refused\":true}".utf8))
            }
            Darwin.exit(2)
        }
    }
}
'''


class ProbeFailure(RuntimeError):
    pass


def command(args, stage, timeout=60):
    result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            timeout=timeout, check=False)
    if result.returncode:
        # codesign can repeat the explicit certificate selector; never retain it.
        raise ProbeFailure(f"{stage} failed (exit {result.returncode})")
    return result


def sign(path, identity, identifier=None):
    args = ["/usr/bin/codesign", "--force", "--sign", identity,
            "--options", "runtime", "--timestamp=none"]
    if identifier:
        args += ["--identifier", identifier]
    command(args + [str(path)], "local certificate signing")
    command(["/usr/bin/codesign", "--verify", "--strict", str(path)], "signature verification")


def bundle(work, name, binary, identity, helper_identifier="photo-agent-mcp"):
    app = work / f"{name}.app"
    contents = app / "Contents"
    executables = contents / "MacOS"
    executables.mkdir(parents=True)
    with (contents / "Info.plist").open("wb") as stream:
        plistlib.dump({"CFBundleIdentifier": "aagedal.Aagedal-Photo-Agent",
                      "CFBundleExecutable": "Aagedal Photo Agent",
                      "CFBundleName": "Native Invocation Probe",
                      "CFBundlePackageType": "APPL", "CFBundleVersion": "1"}, stream)
    for name in ("Aagedal Photo Agent", "photo-agent-mcp"):
        shutil.copy2(binary, executables / name)
    sign(executables / "photo-agent-mcp", identity, helper_identifier)
    sign(app, identity)
    command(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], "nested signature verification")
    return executables / "Aagedal Photo Agent", executables / "photo-agent-mcp"


def start_server(executable, directory, mode="server"):
    process = subprocess.Popen([str(executable), mode, str(directory)],
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE)
    selector = selectors.DefaultSelector()
    try:
        selector.register(process.stdout, selectors.EVENT_READ)
        if not selector.select(timeout=10):
            raise ProbeFailure("production signed listener did not become ready")
        line = process.stdout.readline(1024)
        result = json.loads(line)
        if result != {"ready": True}:
            reason = result.get("refusedReason") if isinstance(result, dict) else None
            safe_reason = reason if reason in REFUSAL_REASONS else "unknownFailure"
            raise ProbeFailure(f"production signed listener refused ({safe_reason})")
        return process
    except Exception:
        stop_server(process)
        raise
    finally:
        selector.close()


def stop_server(process):
    if process.poll() is None:
        try:
            process.stdin.close()
        except OSError:
            pass
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
    for stream in (process.stdin, process.stdout, process.stderr):
        if not stream.closed:
            stream.close()


def call(executable, directory, request_id=REVIEW_ID, raw=False, allow_unsigned_launch_refusal=False):
    result = subprocess.run([str(executable), "raw" if raw else "client", str(directory), request_id, EPOCH],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=8, check=False)
    if allow_unsigned_launch_refusal and result.returncode in (-9, -6) and not result.stdout:
        # Apple silicon can reject an unsigned executable before main. Keep this
        # boundary explicit; a separate ad-hoc peer case exercises the listener.
        return result.returncode, {"unsignedLaunchRefused": True}
    try:
        value = json.loads(result.stdout)
    except (ValueError, UnicodeError):
        raise ProbeFailure("harness returned no bounded structured result") from None
    if result.stderr:
        raise ProbeFailure("harness emitted unexpected diagnostics")
    return result.returncode, value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--signing-identity", required=True,
                        help="Explicit local compatible Apple team certificate selector; no automatic identity discovery")
    parser.add_argument("--output", type=Path, required=True, help="JSON evidence report")
    parser.add_argument("--work-directory", type=Path, required=True, help="Ignored repository build directory")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    work_parent = args.work_directory.resolve()
    output = args.output.resolve()
    report = {"schemaVersion": 1, "passed": False, "cases": [],
              "authentication": "production constructors, Apple signature requirements, kernel audit-token peers",
              "scope": "disposable locally certificate-signed transport harnesses with synthetic read-only responses",
              "limitations": ["Does not qualify distribution signing or notarization",
                              "Does not qualify the actual app's native review, provider consent or execution pipeline"],
              "hostPreferencesChanged": False, "cleanupComplete": False}
    servers = []
    temporary_paths = []
    try:
        if os.uname().sysname != "Darwin":
            raise ProbeFailure("macOS is required for actual Security.framework peer authentication")
        if not args.signing_identity.strip() or args.signing_identity.strip() == "-":
            raise ProbeFailure("an explicit compatible certificate identity is required; ad-hoc signing is refused")
        try:
            relative = work_parent.relative_to(repo)
        except ValueError:
            raise ProbeFailure("work directory must be inside the repository's ignored build tree") from None
        ignored = subprocess.run(["git", "check-ignore", "--quiet", str(relative / "native-probe-placeholder")], cwd=repo)
        if ignored.returncode:
            raise ProbeFailure("work directory must be ignored by git")
        work_parent.mkdir(parents=True, exist_ok=True)
        work = Path(tempfile.mkdtemp(prefix="native-invocation-", dir=work_parent))
        temporary_paths.append(work)
        sockets = Path(tempfile.mkdtemp(prefix="apa-probe-", dir="/private/tmp"))
        temporary_paths.append(sockets)
        os.chmod(sockets, 0o700)
        source = work / "Harness.swift"
        source.write_text(HARNESS)
        binary = work / "harness"
        command(["/usr/bin/xcrun", "swiftc", "-swift-version", "6", "-strict-concurrency=complete",
                 "-parse-as-library", str(repo / "Aagedal Photo Agent/Services/Automation/AutomationNativeInvocationChannel.swift"),
                 str(source), "-o", str(binary)], "Swift transport harness compilation", timeout=120)
        app_a, helper_a = bundle(work, "PairA", binary, args.signing_identity)
        app_b, helper_b = bundle(work, "PairB", binary, args.signing_identity)
        _, wrong_helper = bundle(work, "WrongIdentifier", binary, args.signing_identity, "other-helper")
        unsigned = work / "unsigned-helper"
        shutil.copy2(helper_a, unsigned)
        command(["/usr/bin/codesign", "--remove-signature", str(unsigned)], "unsigned negative fixture creation")
        adhoc = work / "adhoc-helper"
        shutil.copy2(helper_a, adhoc)
        command(["/usr/bin/codesign", "--force", "--sign", "-", "--identifier", "photo-agent-mcp", str(adhoc)],
                "ad-hoc negative fixture creation")
        unpaired = work / "unpaired-helper"
        shutil.copy2(helper_a, unpaired)
        sign(unpaired, args.signing_identity, "photo-agent-mcp")
        endpoint_a = sockets / "a"
        endpoint_b = sockets / "b"
        servers.append(start_server(app_a, endpoint_a))
        servers.append(start_server(app_b, endpoint_b))

        def check(name, executable, directory, expected=None, request_id=REVIEW_ID, raw=False,
                  allow_unsigned_launch_refusal=False):
            code, value = call(executable, directory, request_id, raw, allow_unsigned_launch_refusal)
            if allow_unsigned_launch_refusal and value == {"unsignedLaunchRefused": True}:
                report["cases"].append({"name": name, "passed": True,
                                        "refusalBoundary": "operating_system_launch; channel not reached"})
                return
            refusal_reason = value.get("refusedReason") if isinstance(value, dict) else None
            refused = (value == {"refused": True}
                       or (isinstance(value, dict) and set(value) == {"refused", "refusedReason"}
                           and value["refused"] is True and refusal_reason in REFUSAL_REASONS))
            passed = (code == 0 and value == expected) if expected is not None else (code == 2 and refused)
            evidence = {"name": name, "passed": passed}
            if refusal_reason in REFUSAL_REASONS:
                evidence["clientRefusedReason"] = refusal_reason
            if value == {"probeProtocolFailure": True}:
                evidence["probeProtocolFailure"] = True
            report["cases"].append(evidence)

        check("valid_pair_review_required", helper_a, endpoint_a,
              {"schemaVersion": 1, "status": "reviewRequired"})
        check("valid_pair_raw_wire_baseline", helper_a, endpoint_a,
              {"schemaVersion": 1, "status": "reviewRequired"}, raw=True)
        check("valid_pair_exact_linked_operation", helper_a, endpoint_a,
              {"schemaVersion": 1, "status": "linkedOperation", "operationID": OPERATION}, LINKED_ID)
        check("unsigned_helper_refused", unsigned, endpoint_a, allow_unsigned_launch_refusal=True)
        check("unsigned_peer_refused", unsigned, endpoint_a, raw=True, allow_unsigned_launch_refusal=True)
        check("adhoc_helper_constructor_refused", adhoc, endpoint_a)
        check("adhoc_peer_listener_refused", adhoc, endpoint_a, raw=True)
        check("unpaired_signed_helper_constructor_refused", unpaired, endpoint_a)
        check("other_signed_identifier_listener_refused", wrong_helper, endpoint_a, raw=True)
        check("other_valid_pair_helper_listener_refused", helper_b, endpoint_a, raw=True)
        check("other_pair_listener_endpoint_refused", helper_a, endpoint_b)
        wrong_app_server = start_server(app_b, sockets / "wrong-app", mode="raw-server")
        servers.append(wrong_app_server)
        code, value = call(helper_a, sockets / "wrong-app")
        wrong_app_server.wait(timeout=8)
        observation = json.loads(wrong_app_server.stdout.readline(1024))
        report["cases"].append({
            "name": "production_client_wrong_application_refused_before_request",
            "passed": (code == 2 and value == {"refused": True, "refusedReason": "unpairedExecutable"}
                       and wrong_app_server.returncode == 0 and observation == {"observedRequestBytes": 0}),
            "clientRefusedReason": value.get("refusedReason") if value.get("refusedReason") in REFUSAL_REASONS else "unknownFailure",
            "zeroRequestBytesObserved": observation == {"observedRequestBytes": 0},
        })
        # Establish that refusals have not disabled or occupied the real listener.
        check("valid_pair_after_refusals", helper_a, endpoint_a,
              {"schemaVersion": 1, "status": "reviewRequired"})
        report["passed"] = all(case["passed"] for case in report["cases"])
    except (ProbeFailure, OSError, subprocess.SubprocessError, ValueError) as error:
        # All subprocess errors are summarized without argv/certificate material.
        report["failure"] = str(error) if isinstance(error, ProbeFailure) else type(error).__name__
    finally:
        for server in reversed(servers):
            stop_server(server)
        cleanup_errors = []
        for path in reversed(temporary_paths):
            try:
                shutil.rmtree(path)
            except OSError:
                cleanup_errors.append("temporary harness or socket cleanup failed")
        report["cleanupComplete"] = not cleanup_errors
        if cleanup_errors:
            report["cleanupErrors"] = cleanup_errors
            report["passed"] = False
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(json.dumps({"passed": report["passed"], "cases": len(report["cases"]),
                      "cleanupComplete": report["cleanupComplete"]}, sort_keys=True))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
