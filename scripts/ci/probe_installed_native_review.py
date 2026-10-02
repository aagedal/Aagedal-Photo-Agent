#!/usr/bin/env python3
"""Qualify the actual signed bundled helper -> running app -> exact review UI.

XCTest's generated runner remains sandboxed. This standalone CLI launches the
actual nested helper normally; a private token-bound fixture rendezvous only
coordinates requests/results. Production signature and kernel peer checks apply.
The provider is reviewed but never submitted; host preferences/models stay intact.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import stat
import subprocess
import tempfile
import time
import uuid


SHARED_ROOT = Path("/private/tmp/apa-installed-qualification")
TEST = "Aagedal Photo Agent UI Smoke Tests/CoreWorkflowSmokeTests/testSignedBundledHelperOpensExactTranscriptionReviewWithoutExecution"
MAX_MESSAGE = 65_536
REQUEST_KEYS = {"schemaVersion", "token", "call", "helperURL", "applicationPID", "rootURL", "socketDirectory", "requestID", "requestEpoch"}


class ProbeFailure(Exception):
    pass


def canonical_uuid(value):
    try:
        return isinstance(value, str) and str(uuid.UUID(value)) == value
    except (ValueError, TypeError):
        return False


def private_directory(path):
    item = path.lstat()
    if not stat.S_ISDIR(item.st_mode) or item.st_uid != os.getuid() or item.st_mode & 0o077:
        raise ProbeFailure("unsafe_fixture_directory")


def read_private_json(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        item = os.fstat(descriptor)
        if not stat.S_ISREG(item.st_mode) or item.st_uid != os.getuid() or item.st_mode & 0o077 or item.st_size >= MAX_MESSAGE:
            raise ProbeFailure("unsafe_rendezvous_request")
        data = os.read(descriptor, MAX_MESSAGE)
        if len(data) != item.st_size:
            raise ProbeFailure("changed_rendezvous_request")
        return json.loads(data)
    finally:
        os.close(descriptor)


def atomic_json(path, value):
    descriptor, name = tempfile.mkstemp(prefix=".installed-helper-response-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w") as stream:
            json.dump(value, stream, sort_keys=True)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def file_hash(path):
    if path.resolve() != path:
        raise ProbeFailure("symlinked_fixture_file")
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        item = os.fstat(descriptor)
        if not stat.S_ISREG(item.st_mode) or item.st_uid != os.getuid():
            raise ProbeFailure("unsafe_fixture_file")
        digest = hashlib.sha256()
        while True:
            block = os.read(descriptor, 1_048_576)
            if not block:
                return digest.hexdigest()
            digest.update(block)
    finally:
        os.close(descriptor)


def protected_state(root):
    paths = [root / "transcription-review-authorization.json", root / "transcription-review-manifest.json",
             root / "transcription-review-plans/plans.json", root / "transcription-review-requests/operations.json"]
    for pattern in ("*.jpg", "*.wav", ".*.voice-memo.json"):
        paths.extend(root.glob(pattern))
    result = {str(path.relative_to(root)): file_hash(path) for path in paths}
    if (root / "transcription-review-operations/operations.json").exists() or (root / ".photo_metadata").exists():
        raise ProbeFailure("unexpected_operation_or_draft")
    return result


def validate_request(value, token, call, fixture, expected_helper):
    if not isinstance(value, dict) or set(value) != REQUEST_KEYS or value["schemaVersion"] != 1:
        raise ProbeFailure("invalid_rendezvous_schema")
    if value["token"] != token or type(value["call"]) is not int or value["call"] != call or not 1 <= call <= 4:
        raise ProbeFailure("invalid_rendezvous_token_or_call")
    if value["helperURL"] != str(expected_helper):
        raise ProbeFailure("unexpected_helper_location")
    if not canonical_uuid(value["requestID"]) or not canonical_uuid(value["requestEpoch"]):
        raise ProbeFailure("invalid_request_handle")
    if type(value["applicationPID"]) is not int or value["applicationPID"] <= 0:
        raise ProbeFailure("invalid_application_pid")
    os.kill(value["applicationPID"], 0)
    if not isinstance(value["rootURL"], str) or not value["rootURL"].startswith("/"):
        raise ProbeFailure("invalid_fixture_root")
    root = Path(value["rootURL"]).resolve()
    if root.parent != fixture or not root.name.startswith("Photos-"):
        raise ProbeFailure("unexpected_fixture_root")
    try:
        uuid.UUID(root.name.removeprefix("Photos-"))
    except ValueError:
        raise ProbeFailure("invalid_fixture_name") from None
    private_directory(fixture)
    if root.is_symlink() or not root.is_dir() or root.stat().st_uid != os.getuid():
        raise ProbeFailure("unsafe_fixture_root")
    socket = value["socketDirectory"]
    prefix = "/private/tmp/apa-integration-"
    if not isinstance(socket, str) or not socket.startswith(prefix) or not canonical_uuid(socket.removeprefix(prefix)):
        raise ProbeFailure("invalid_socket_location")
    private_directory(Path(socket))
    return root, Path(socket)


def helper_messages(request):
    messages = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": "2025-06-18", "capabilities": {},
            "clientInfo": {"name": "installed-pair-ui-qualification", "version": "1"}}},
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {
            "name": "open_voice_transcription_review", "arguments": {
                "requestID": request["requestID"], "requestEpoch": request["requestEpoch"]}}}]
    return b"".join(json.dumps(message, sort_keys=True).encode() + b"\n" for message in messages)


def verify_runner_entitlements(app):
    runner = app.with_name("Aagedal Photo Agent UI Smoke Tests-Runner.app")
    result = subprocess.run(["/usr/bin/codesign", "-d", "--entitlements", ":-", str(runner)], capture_output=True, timeout=10)
    if result.returncode or len(result.stdout) >= MAX_MESSAGE:
        raise ProbeFailure("runner_entitlements_unavailable")
    try:
        entitlements = plistlib.loads(result.stdout)
    except (ValueError, plistlib.InvalidFileException):
        raise ProbeFailure("runner_entitlements_invalid") from None
    exception = entitlements.get("com.apple.security.temporary-exception.files.absolute-path.read-write")
    if entitlements.get("com.apple.security.app-sandbox") is not True or exception != [str(SHARED_ROOT) + "/"]:
        raise ProbeFailure("runner_entitlement_scope_mismatch")
    return {"runnerSandboxEnabled": True, "testRunnerAbsoluteReadWriteExceptions": exception}


def invoke_helper(helper, root, socket, request, pair_hashes, app_executable):
    if [file_hash(app_executable), file_hash(helper)] != pair_hashes:
        raise ProbeFailure("built_pair_changed")
    before = protected_state(root)
    environment = os.environ.copy()
    for key in ("OS_ACTIVITY_DT_MODE", "CFLOG_FORCE_STDERR", "IDEPreferLogStreaming"):
        environment.pop(key, None)
    environment["AAGEDAL_UI_TEST_NATIVE_INVOCATION"] = "1"
    result = subprocess.run([str(helper), "--ui-testing", "--ui-test-transcription-root", str(root),
                             "--ui-test-transcription-socket", str(socket)], input=helper_messages(request),
                            capture_output=True, timeout=8, env=environment, check=False)
    if len(result.stdout) >= MAX_MESSAGE or len(result.stderr) >= MAX_MESSAGE:
        raise ProbeFailure("helper_output_limit")
    if [file_hash(app_executable), file_hash(helper)] != pair_hashes or protected_state(root) != before:
        raise ProbeFailure("built_pair_or_sources_changed")
    return {"exitCode": result.returncode, "stdout": result.stdout.decode("utf-8"), "stderr": result.stderr.decode("utf-8")}


def validate_results(cases):
    if len(cases) != 4:
        return False
    for index, case in enumerate(cases):
        if case.get("error") or case.get("exitCode") != 0 or case.get("stderr"):
            return False
        try:
            lines = [json.loads(line) for line in case["stdout"].splitlines()]
            if len(lines) != 2 or lines[0].get("id") != 1 or "result" not in lines[0] or lines[1].get("id") != 2:
                return False
            result = lines[1]["result"]
            value = result["structuredContent"]
            if index in (0, 2):
                if result["isError"] is not True or value["code"] != "native_review_unavailable":
                    return False
            elif (result["isError"] is not False or value["status"] != "reviewRequired"
                  or value["operationID"] is not None or value["requestID"] != case["requestID"]
                  or value["requestEpoch"] != case["requestEpoch"]
                  or any(value[key] is not False for key in ("consentGranted", "executionStarted", "directHelperExecutionAvailable", "completionConfirmed"))):
                return False
        except (KeyError, TypeError, ValueError):
            return False
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--derived-data-path", type=Path, required=True)
    parser.add_argument("--result-bundle", type=Path, required=True)
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    token = str(uuid.uuid4())
    report = {"schemaVersion": 1, "passed": False, "authentication": "production signature requirements and kernel audit-token peers",
              "helperLaunch": "normal standalone subprocess outside XCTest runner sandbox", "runnerSandboxEnabled": None,
              "productionSandboxChanged": False, "testRunnerWritableFixtureRoot": str(SHARED_ROOT), "sharedParentRetained": True,
              "hostPreferencesChanged": False, "executionSubmitted": False, "cases": [], "cleanupComplete": False,
              "limitations": ["Debug disposable stores and deterministic provider preparation; no inference or draft publication",
                              "Does not qualify distribution signing or notarization"]}
    process = None
    validated_output = None
    socket_paths = set()
    fixture_paths = set()
    stage = "arguments"
    try:
        if os.uname().sysname != "Darwin":
            raise ProbeFailure("macOS_required")
        app = args.app.resolve()
        derived = args.derived_data_path.resolve()
        if app != derived / "Build/Products/Debug/Aagedal Photo Agent.app":
            raise ProbeFailure("app_must_match_selected_derived_debug_product")
        for path in (derived, args.result_bundle.resolve(), args.log.resolve(), args.output.resolve()):
            try:
                relative = path.relative_to(repo)
            except ValueError:
                raise ProbeFailure("evidence_and_products_must_be_inside_ignored_repository_build_tree") from None
            if not relative.parts or relative.parts[0] != "build" or subprocess.run(["git", "check-ignore", "--quiet", str(relative)], cwd=repo).returncode:
                raise ProbeFailure("evidence_and_products_must_be_ignored")
        args.output.parent.mkdir(parents=True, exist_ok=True)
        validated_output = args.output.resolve()
        if args.result_bundle.exists():
            raise ProbeFailure("result_bundle_already_exists")
        args.log.parent.mkdir(parents=True, exist_ok=True)
        helper = app / "Contents/MacOS/photo-agent-mcp"
        app_executable = app / "Contents/MacOS/Aagedal Photo Agent"
        # The sandboxed runner has a narrow test-only entitlement to this exact
        # shared root. Normal CLI processes need no access to its private container.
        stage = "shared_fixture_setup"
        try:
            SHARED_ROOT.mkdir(mode=0o700)
        except FileExistsError:
            pass
        private_directory(SHARED_ROOT)
        if SHARED_ROOT.resolve() != SHARED_ROOT:
            raise ProbeFailure("symlinked_shared_fixture_directory")
        candidates = [SHARED_ROOT / f"AagedalPhotoAgentUISmoke-{token}"]
        environment = os.environ.copy()
        environment["AAGEDAL_INSTALLED_HELPER_TOKEN"] = token
        environment["TEST_RUNNER_AAGEDAL_INSTALLED_HELPER_TOKEN"] = token
        environment["AAGEDAL_INSTALLED_HELPER_ROOT"] = str(SHARED_ROOT)
        environment["TEST_RUNNER_AAGEDAL_INSTALLED_HELPER_ROOT"] = str(SHARED_ROOT)
        command = ["/usr/bin/xcrun", "xcodebuild", "test", "-project", "Aagedal Photo Agent.xcodeproj",
                   "-scheme", "Aagedal Photo Agent UI Smoke Tests", "-configuration", "Debug", "-destination", "platform=macOS",
                   "-derivedDataPath", str(derived), "-disableAutomaticPackageResolution", "-parallel-testing-enabled", "NO",
                   "-test-timeouts-enabled", "YES", "-default-test-execution-time-allowance", "120",
                   "-maximum-test-execution-time-allowance", "180", f"-only-testing:{TEST}",
                   "-resultBundlePath", str(args.result_bundle.resolve())]
        pinned = None
        runner_checked = False
        deadline = time.monotonic() + 900
        with args.log.open("w") as log:
            stage = "xcodebuild_and_rendezvous"
            process = subprocess.Popen(command, cwd=repo, env=environment, stdout=log, stderr=subprocess.STDOUT)
            while process.poll() is None:
                if time.monotonic() >= deadline:
                    raise ProbeFailure("xcodebuild_timeout")
                found = [fixture for fixture in candidates if fixture.exists()]
                if len(found) > 1:
                    raise ProbeFailure("ambiguous_fixture_rendezvous")
                if found:
                    fixture = found[0]
                    private_directory(fixture)
                    fixture_paths.add(fixture)
                    if not runner_checked:
                        report.update(verify_runner_entitlements(app))
                        runner_checked = True
                    # Preserve a bounded fixture-only startup diagnosis before
                    # XCTest removes its disposable files on a failed launch.
                    for diagnostic in fixture.glob("Photos-*/transcription-helper-listener-failure.json"):
                        if diagnostic.resolve() != diagnostic or diagnostic.stat().st_uid != os.getuid() or diagnostic.stat().st_size >= MAX_MESSAGE:
                            raise ProbeFailure("unsafe_listener_diagnostic")
                        value = json.loads(diagnostic.read_bytes())
                        if isinstance(value, dict) and set(value) == {"stage", "error"}:
                            report["listenerStartupFailure"] = value
                    call = len(report["cases"]) + 1
                    request_path = fixture / f"installed-helper-request-{call}.json"
                    if call <= 4 and request_path.exists():
                        request = read_private_json(request_path)
                        root, socket = validate_request(request, token, call, fixture, helper)
                        socket_paths.add(socket)
                        response = {"schemaVersion": 1, "token": token, "call": call}
                        try:
                            if pinned is None:
                                verification = subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], capture_output=True, timeout=10)
                                if verification.returncode:
                                    raise ProbeFailure("built_pair_signature_verification_failed")
                                pinned = [file_hash(app_executable), file_hash(helper)]
                                report["appExecutableSHA256"], report["helperSHA256"] = pinned
                                report["appPath"] = str(app)
                            response.update(invoke_helper(helper, root, socket, request, pinned, app_executable))
                        except (ProbeFailure, subprocess.TimeoutExpired, UnicodeError, OSError) as error:
                            response["error"] = str(error) if isinstance(error, ProbeFailure) else type(error).__name__
                        report["cases"].append({"call": call, "requestID": request["requestID"], "requestEpoch": request["requestEpoch"],
                                                **{key: value for key, value in response.items() if key not in ("token", "schemaVersion", "call")}})
                        atomic_json(fixture / f"installed-helper-response-{call}.json", response)
                time.sleep(0.05)
        report["xcodebuildExitCode"] = process.returncode
        stage = "xcresult_summary"
        summary_result = subprocess.run(["/usr/bin/xcrun", "xcresulttool", "get", "test-results", "summary",
                                         "--path", str(args.result_bundle.resolve())], capture_output=True, timeout=20)
        if summary_result.returncode or len(summary_result.stdout) >= MAX_MESSAGE:
            raise ProbeFailure("xcresult_summary_unavailable")
        summary = json.loads(summary_result.stdout)
        counts = {key: summary.get(key) for key in ("totalTestCount", "passedTests", "failedTests", "skippedTests")}
        report["tests"] = counts
        executed = counts == {"totalTestCount": 1, "passedTests": 1, "failedTests": 0, "skippedTests": 0}
        report["helperInvocationCount"] = len(report["cases"])
        report["passed"] = process.returncode == 0 and executed and validate_results(report["cases"])
        if not report["passed"]:
            report["failure"] = "installed_native_review_qualification_failed"
    except (ProbeFailure, OSError, ValueError, subprocess.TimeoutExpired) as error:
        report["failure"] = str(error) if isinstance(error, ProbeFailure) else type(error).__name__
        report["failureStage"] = stage
    finally:
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
        # XCTest owns the app and fixture lifecycle; do not terminate any other
        # app installation. Remove an empty socket directory only after observing
        # normal listener teardown, never mask a live socket with forced removal.
        sockets_clean = True
        for socket in socket_paths:
            try:
                if not socket.exists():
                    continue
                private_directory(socket)
                if (socket / "review.sock").exists() or (socket / "review.sock").is_symlink():
                    sockets_clean = False
                else:
                    for lock in socket.iterdir():
                        item = lock.lstat()
                        if lock.name == "review.owner.lock" and stat.S_ISREG(item.st_mode) and item.st_uid == os.getuid() and not item.st_mode & 0o077:
                            lock.unlink()
                    socket.rmdir()
            except (OSError, ProbeFailure):
                sockets_clean = False
        report["cleanupComplete"] = sockets_clean and all(not fixture.exists() for fixture in fixture_paths)
        if not report["cleanupComplete"]:
            report["passed"] = False
            report.setdefault("failure", "fixture_cleanup_incomplete")
        if validated_output is not None:
            atomic_json(validated_output, report)
    print("Installed native review qualification: " + ("PASS" if report["passed"] else "FAIL"))
    if not report["passed"]:
        print("Reason: " + report.get("failure", "unknown_failure"))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
