#!/usr/bin/env python3
"""Qualify local FFmpeg Whisper with the exact production Swift runner/provider.

Uses only local supplied artifacts and PCM fixtures. Never downloads anything,
changes application preferences, or logs recognized text. The default model and
speech fixture are optional existing QA files, not release-distributed models.
This CLI evidence does not qualify native signed-app review, recognition accuracy,
GPU acceleration, distribution signing, or external companion persistence.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import wave

ROOT = Path(__file__).resolve().parents[2]
SOURCES = (
    "Aagedal Photo Agent/Services/FFmpegWhisperJobRunner.swift",
    "Aagedal Photo Agent/Services/FFmpegWhisperOutputReader.swift",
    "Aagedal Photo Agent/Services/FFmpegWhisperJSONParser.swift",
    "Aagedal Photo Agent/Services/FFmpegWhisperTranscriptionProvider.swift",
    "Aagedal Photo Agent/Models/FFmpegWhisperTranscriptProvenance.swift",
)
ERROR_SOURCE = "Aagedal Photo Agent/Services/VoiceMemoTranscriptionService.swift"
CASES = ("cpu-explicit", "cpu-auto", "no-speech", "timeout", "cancellation",
         "changed-audio", "changed-model", "changed-executable", "authorization-revoked")

HARNESS = r'''
import CryptoKit
import Darwin
import Foundation

struct ProbeFailure: Error {}
struct AuthorizationRevoked: Error {}

struct ProbeInput: Codable {
    let mode: String
    let binary: String
    let model: String
    let audio: String
    let timeoutSeconds: Double
    let durationMilliseconds: Int64
    let useGPU: Bool
}

func require(_ condition: Bool) throws {
    guard condition else { throw ProbeFailure() }
}

func identity(_ url: URL) throws -> FFmpegWhisperJobInput {
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    var hash = SHA256(), size: Int64 = 0
    while let bytes = try file.read(upToCount: 65536), !bytes.isEmpty {
        hash.update(data: bytes)
        size += Int64(bytes.count)
    }
    return .init(url: url, byteCount: size,
                 sha256: hash.finalize().map { String(format: "%02x", $0) }.joined())
}

actor Authorization {
    var calls = 0
    let revoke: Bool
    init(revoke: Bool) { self.revoke = revoke }
    func authorize(_ configuration: FFmpegWhisperTranscriptionProvider.Configuration) throws {
        calls += 1
        if revoke && calls > 1 { throw AuthorizationRevoked() }
        try require(identity(configuration.executable.url) == configuration.executable)
        try require(identity(configuration.model.url) == configuration.model)
    }
}

@main struct WhisperProviderProbe {
    static func runningChildren() throws -> [Int32] {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,command="]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try require(process.terminationStatus == 0)
        return String(decoding: bytes, as: UTF8.self).split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3, Int32(fields[1]) == getpid(),
                  fields[2].contains("/photo-whisper-"), let pid = Int32(fields[0]) else { return nil }
            return pid
        }
    }

    static func run(_ input: ProbeInput) async throws -> [String: Any] {
        let executable = try identity(URL(fileURLWithPath: input.binary))
        let model = try identity(URL(fileURLWithPath: input.model))
        let audio = try identity(URL(fileURLWithPath: input.audio))
        let language = input.mode == "cpu-auto" ? "auto" : "en"
        let request = FFmpegWhisperJobRequest(executable: executable, audio: audio, model: model,
            language: language, useGPU: input.useGPU,
            timeoutSeconds: input.mode == "timeout" ? 0.05 : input.timeoutSeconds)
        let runner = FFmpegWhisperJobRunner()
        var report: [String: Any] = ["name": input.mode, "passed": true]

        if input.mode.hasPrefix("changed-") {
            let target = input.mode == "changed-model" ? model :
                (input.mode == "changed-executable" ? executable : audio)
            let file = try FileHandle(forUpdating: target.url)
            let first = try file.read(upToCount: 1)!
            try file.seek(toOffset: 0)
            try file.write(contentsOf: Data([first[0] ^ 1]))
            try file.close()
            do { _ = try await runner.run(request); throw ProbeFailure() }
            catch FFmpegWhisperJobError.identityMismatch {
                report["refusal"] = "identityMismatch"
            }
            return report
        }

        if input.mode == "timeout" {
            do { _ = try await runner.run(request); throw ProbeFailure() }
            catch FFmpegWhisperJobError.timedOut { report["refusal"] = "timedOut" }
            return report
        }

        if input.mode == "cancellation" {
            let task = Task { try await runner.run(request) }
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(15))
            var children: [Int32] = []
            do {
                while children.isEmpty && clock.now < deadline {
                    children = try runningChildren()
                    if children.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
                }
                try require(!children.isEmpty)
            } catch {
                task.cancel()
                _ = try? await task.value
                throw error
            }
            task.cancel()
            do { _ = try await task.value; throw ProbeFailure() }
            catch is CancellationError { report["refusal"] = "cancelled" }
            try require(children.allSatisfy { kill($0, 0) == -1 && errno == ESRCH })
            report["observedRealChildReaped"] = true
            return report
        }

        let authorization = Authorization(revoke: input.mode == "authorization-revoked")
        let configuration = FFmpegWhisperTranscriptionProvider.Configuration(
            executable: executable, buildIdentifier: "local-provider-probe",
            model: model, modelIdentifier: "local-provider-probe-model",
            language: language, useGPU: input.useGPU, timeoutSeconds: input.timeoutSeconds)
        // This uses the provider's production default runner; no inference injection.
        let provider = FFmpegWhisperTranscriptionProvider(configuration: configuration,
            authorizeArtifacts: { try await authorization.authorize($0) })
        do {
            let result = try await provider.transcribe(audio: audio)
            try require(input.mode != "no-speech" && input.mode != "authorization-revoked")
            let provenance = result.provenance
            try provenance.validate()
            try require(provenance.executableSHA256 == executable.sha256 &&
                provenance.executableByteCount == executable.byteCount &&
                provenance.modelSHA256 == model.sha256 && provenance.modelByteCount == model.byteCount &&
                provenance.buildIdentifier == configuration.buildIdentifier &&
                provenance.modelIdentifier == configuration.modelIdentifier &&
                provenance.requestedLanguage == language && provenance.useGPU == input.useGPU &&
                !provenance.translate && provenance.schemaVersion == 1 && provenance.detectedLanguage == nil &&
                provenance.editableText == result.text && !result.text.isEmpty)
            try require(provenance.segments.allSatisfy {
                $0.start >= 0 && $0.end >= $0.start && $0.end <= input.durationMilliseconds
            })
            let encoded = try JSONEncoder().encode(provenance)
            let decoded = try JSONDecoder().decode(FFmpegWhisperTranscriptProvenance.self, from: encoded)
            try require(decoded == provenance)
            try require(await authorization.calls == 2)
            report["segments"] = provenance.segments.count
            report["requestedLanguage"] = language
            report["exactProvenanceValidated"] = true
            report["provenanceRoundTripValidated"] = true
            report["authorizationCalls"] = 2
        } catch VoiceMemoTranscriptionError.noSpeech {
            try require(input.mode == "no-speech")
            report["refusal"] = "noSpeech"
        } catch FFmpegWhisperJSONError.noSpeech {
            try require(input.mode == "no-speech")
            report["refusal"] = "noSpeech"
        } catch is AuthorizationRevoked {
            try require(input.mode == "authorization-revoked")
            try require(await authorization.calls == 2)
            report["refusal"] = "authorizationRevokedAfterInference"
            report["authorizationCalls"] = 2
        }
        return report
    }

    static func main() async {
        do {
            try require(CommandLine.arguments.count == 2)
            let input = try JSONDecoder().decode(ProbeInput.self,
                from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
            let result = try await run(input)
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result,
                options: [.sortedKeys]) + Data([10]))
        } catch {
            // Error values/recognized text never leave the CLI; fail closed with a fixed message.
            FileHandle.standardError.write(Data("Production Whisper provider probe failed.\n".utf8))
            exit(1)
        }
    }
}
'''


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def error_declaration(text: str) -> str:
    """Extract a complete unchanged declaration; fail if its sentinel changes."""
    start = text.index("nonisolated enum VoiceMemoTranscriptionError:")
    end = text.index("\n}\n", start) + 2
    return text[start:end] + "\n"


def audio_duration(path: Path) -> int:
    with wave.open(str(path), "rb") as audio:
        require(audio.getcomptype() == "NONE" and audio.getnframes() > 0,
                "probe audio must be a nonempty PCM WAV")
        return audio.getnframes() * 1000 // audio.getframerate()


def silence(path: Path, seconds: int) -> None:
    with wave.open(str(path), "wb") as audio:
        audio.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
        audio.writeframes(b"\0" * 16000 * 2 * seconds)


def stranded_children(directory: Path) -> list[int]:
    result = subprocess.run(["/bin/ps", "-axo", "pid=,command="], capture_output=True,
                            check=True, timeout=10, text=True)
    prefix = str(directory / "photo-whisper-")
    return [int(fields[0]) for line in result.stdout.splitlines()
            if len(fields := line.strip().split(maxsplit=1)) == 2 and prefix in fields[1]]


def execute_case(cli: Path, config: dict, directory: Path, timeout: float) -> dict:
    jobs = directory / "jobs"
    jobs.mkdir()
    config_path = directory / "request.json"
    config_path.write_text(json.dumps(config), encoding="utf-8")
    environment = {**os.environ, "TMPDIR": str(jobs) + "/"}
    started = time.monotonic()
    process = subprocess.Popen([str(cli), str(config_path)], env=environment,
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        start_new_session=True)
    timed_out = False
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        timed_out = True
        os.killpg(process.pid, signal.SIGKILL)
        stdout, stderr = process.communicate(timeout=10)
    finally:
        stranded = stranded_children(jobs)
        for pid in stranded:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
    require(not timed_out, f"{config['mode']} exceeded the external deadline")
    require(not stranded, f"{config['mode']} stranded an FFmpeg child")
    require(not list(jobs.iterdir()), f"{config['mode']} stranded a private job directory")
    require(process.returncode == 0 and not stderr,
            f"{config['mode']} production harness failed (exit {process.returncode})")
    report = validate_case_report(json.loads(stdout), config["mode"])
    report["elapsedSeconds"] = round(time.monotonic() - started, 3)
    report["noStrandedJobDirectory"] = True
    report["noStrandedFFmpegProcess"] = True
    report["audioSHA256"] = sha256(Path(config["audio"])) if not config["mode"].startswith("changed-") else config["audioSHA256"]
    report["durationMilliseconds"] = config["durationMilliseconds"]
    return report


def validate_case_report(report: dict, mode: str) -> dict:
    allowed = {"name", "passed"}
    if mode in {"cpu-explicit", "cpu-auto", "gpu-opt-in"}:
        allowed |= {"segments", "requestedLanguage", "exactProvenanceValidated",
                    "provenanceRoundTripValidated", "authorizationCalls"}
    else:
        allowed.add("refusal")
        if mode == "cancellation":
            allowed.add("observedRealChildReaped")
        if mode == "authorization-revoked":
            allowed.add("authorizationCalls")
    require(isinstance(report, dict) and set(report) == allowed,
            "harness returned unexpected fields (recognized text is prohibited)")
    require(report.get("name") == mode and report.get("passed") is True,
            "harness did not qualify the requested case")
    expected = {"no-speech": "noSpeech", "timeout": "timedOut", "cancellation": "cancelled",
                "authorization-revoked": "authorizationRevokedAfterInference"}
    if mode.startswith("changed-"):
        expected[mode] = "identityMismatch"
    if mode in expected:
        require(report.get("refusal") == expected[mode], "wrong refusal cannot qualify a negative case")
        if mode == "cancellation":
            require(report.get("observedRealChildReaped") is True, "cancellation must reap a real child")
        if mode == "authorization-revoked":
            require(report.get("authorizationCalls") == 2, "publication requires reauthorization")
    else:
        require(mode in {"cpu-explicit", "cpu-auto", "gpu-opt-in"}, "unknown probe case")
        require(report.get("exactProvenanceValidated") is True and
                report.get("provenanceRoundTripValidated") is True and
                report.get("authorizationCalls") == 2 and
                type(report.get("segments")) is int and report["segments"] > 0 and
                report.get("requestedLanguage") == ("auto" if mode == "cpu-auto" else "en") and
                "refusal" not in report, "speech must validate exact provenance and reauthorization")
    return report


def probe(binary: Path, model: Path, audio: Path, directory: Path, *,
          timeout: float = 120, gpu: bool = False) -> dict:
    require(math.isfinite(timeout) and 0 < timeout <= 3600, "timeout must be in (0, 3600]")
    for path in (binary, model, audio):
        require(path.is_file(), f"required local fixture is absent: {path}")
    require(os.access(binary, os.X_OK), "FFmpeg must be executable")
    duration = audio_duration(audio)
    sources = directory / "production-sources"
    sources.mkdir()
    identities = []
    compile_sources = []
    for relative in SOURCES:
        source = ROOT / relative
        destination = sources / source.name
        shutil.copyfile(source, destination)
        identities.append({"path": relative, "sha256": sha256(destination), "selection": "entire file"})
        compile_sources.append(str(destination))
    error_path = sources / "VoiceMemoTranscriptionError.swift"
    error_source_bytes = (ROOT / ERROR_SOURCE).read_bytes()
    declaration = error_declaration(error_source_bytes.decode("utf-8"))
    error_path.write_text("import Foundation\n" + declaration, encoding="utf-8")
    identities.append({"path": ERROR_SOURCE, "sha256": hashlib.sha256(error_source_bytes).hexdigest(),
                       "selection": "exact VoiceMemoTranscriptionError declaration",
                       "declarationSHA256": hashlib.sha256(declaration.encode()).hexdigest()})
    harness = directory / "Harness.swift"
    harness.write_text(HARNESS, encoding="utf-8")
    cli = directory / "provider-probe"
    command = ["/usr/bin/xcrun", "swiftc", "-swift-version", "6", "-strict-concurrency=complete",
               "-parse-as-library", "-module-cache-path", str(directory / "module-cache"),
               *compile_sources, str(error_path), str(harness), "-o", str(cli)]
    compilation = subprocess.run(command, capture_output=True, timeout=120)
    (directory / "compile.log").write_bytes(compilation.stdout + compilation.stderr)
    require(compilation.returncode == 0, "production source compilation failed; inspect compile.log")
    report = {"schemaVersion": 1, "passed": False,
              "artifactSHA256": sha256(binary), "artifactByteCount": binary.stat().st_size,
              "modelSHA256": sha256(model), "modelByteCount": model.stat().st_size,
              "speechAudioSHA256": sha256(audio), "productionSources": identities,
              "harnessSHA256": sha256(harness), "cases": [],
              "scope": "Exact production runner/provider/parser/reader/provenance CLI with real local inference; no native signed-app, consent, persistence, accuracy, clean-rebuild or distribution claim",
              "gpuQualification": "opt-in process/provenance only; does not prove acceleration, GPU availability or backend use" if gpu else "not executed"}
    for mode in (*CASES, *(("gpu-opt-in",) if gpu else ())):
        case_directory = directory / mode
        case_directory.mkdir()
        case_binary, case_model, case_audio = (case_directory / name for name in ("ffmpeg", "model.bin", "input.wav"))
        shutil.copyfile(binary, case_binary)
        case_binary.chmod(0o700)
        shutil.copyfile(model, case_model)
        if mode in {"no-speech", "timeout", "cancellation"}:
            silence(case_audio, 5 if mode == "no-speech" else 60)
            case_duration = 5000 if mode == "no-speech" else 60000
        else:
            shutil.copyfile(audio, case_audio)
            case_duration = duration
        config = {"mode": mode, "binary": str(case_binary), "model": str(case_model),
                  "audio": str(case_audio), "timeoutSeconds": timeout,
                  "durationMilliseconds": case_duration, "useGPU": mode == "gpu-opt-in",
                  "audioSHA256": sha256(case_audio)}
        try:
            require(sha256(case_binary) == report["artifactSHA256"] and
                    sha256(case_model) == report["modelSHA256"],
                    "artifact changed between qualification cases")
            if mode not in {"no-speech", "timeout", "cancellation"}:
                require(config["audioSHA256"] == report["speechAudioSHA256"],
                        "speech fixture changed between qualification cases")
            report["cases"].append(execute_case(cli, config, case_directory, timeout + 30))
        except (OSError, ValueError, subprocess.SubprocessError):
            report["cases"].append({"name": mode, "passed": False})
            (directory / "report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
            raise
        finally:
            # Keep only nonsensitive summaries, source copies and compilation diagnostics.
            for path in (case_binary, case_model, case_audio, case_directory / "request.json"):
                path.unlink(missing_ok=True)
    report["passed"] = True
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=ROOT / "Aagedal Photo Agent/Resources/ffmpeg")
    parser.add_argument("--model", type=Path, default=ROOT / "build/qa-v3-whisper-repeatable-final/model.bin")
    parser.add_argument("--audio", type=Path, default=ROOT / "build/qa-v3-cycle86-ffmpeg-runtime/synthetic-speech.wav")
    parser.add_argument("--output", type=Path, help="new evidence directory (otherwise temporary)")
    parser.add_argument("--timeout", type=float, default=120, help="per-inference limit, seconds")
    parser.add_argument("--gpu", action="store_true", help="opt-in GPU-request process case; cannot prove backend acceleration")
    args = parser.parse_args()
    try:
        with tempfile.TemporaryDirectory(prefix="photo-agent-provider-probe-") as temporary:
            directory = args.output.resolve() if args.output else Path(temporary).resolve()
            if args.output:
                directory.mkdir(parents=True, exist_ok=False)
            report = probe(args.binary.resolve(), args.model.resolve(), args.audio.resolve(), directory,
                           timeout=args.timeout, gpu=args.gpu)
            (directory / "report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
            print(json.dumps(report, indent=2))
    except (OSError, ValueError, wave.Error, subprocess.SubprocessError) as error:
        if args.output and args.output.resolve().is_dir():
            report_path = args.output.resolve() / "report.json"
            if not report_path.exists():
                report_path.write_text(json.dumps({"schemaVersion": 1, "passed": False,
                    "scope": "Production CLI qualification did not complete"}, indent=2) + "\n", encoding="utf-8")
        print(f"Whisper provider probe failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
