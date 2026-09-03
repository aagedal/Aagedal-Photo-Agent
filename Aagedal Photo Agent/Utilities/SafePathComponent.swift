import Foundation
import os

nonisolated enum SafePathComponent {
    enum ValidationError: LocalizedError, Equatable {
        case empty(String)
        case invalid(String)

        var errorDescription: String? {
            switch self {
            case .empty(let label):
                return "\(label) can't be empty."
            case .invalid(let label):
                return "\(label) must be a single folder name and can't contain '/', ':', or be '.' or '..'."
            }
        }
    }

    static func validate(_ value: String, label: String = "Folder name") throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ValidationError.empty(label) }
        guard trimmed != ".",
              trimmed != "..",
              trimmed.rangeOfCharacter(from: CharacterSet(charactersIn: "/:\0")) == nil else {
            throw ValidationError.invalid(label)
        }
        return trimmed
    }

    static func appending(_ value: String, label: String = "Folder name", to parent: URL) throws -> URL {
        parent.appendingPathComponent(try validate(value, label: label), isDirectory: true)
    }

    static func isContained(_ candidate: URL, in root: URL) -> Bool {
        let candidateComponents = resolvingExistingSymlinks(in: candidate).pathComponents
        let rootComponents = resolvingExistingSymlinks(in: root).pathComponents
        guard candidateComponents.count >= rootComponents.count else { return false }
        return zip(rootComponents, candidateComponents).allSatisfy { $0.0 == $0.1 }
    }

    /// `URL.resolvingSymlinksInPath()` stops short when the final item does not yet
    /// exist. Resolve the nearest existing ancestor first, then restore the missing
    /// suffix so an existing symlinked directory cannot hide an out-of-root target.
    private static func resolvingExistingSymlinks(in url: URL) -> URL {
        var existingAncestor = url.standardizedFileURL
        var missingComponents: [String] = []
        while !FileManager.default.fileExists(atPath: existingAncestor.path),
              existingAncestor.pathComponents.count > 1 {
            missingComponents.insert(existingAncestor.lastPathComponent, at: 0)
            existingAncestor.deleteLastPathComponent()
        }
        return missingComponents.reduce(existingAncestor.resolvingSymlinksInPath()) {
            $0.appendingPathComponent($1)
        }.standardizedFileURL
    }
}

nonisolated struct SafePathContainmentRequest: Equatable, Sendable {
    let requestID: UUID
    let root: URL
    let candidates: [URL]
}

nonisolated struct SafePathContainmentEvidence: Equatable, Sendable {
    let requestID: UUID
    let root: URL
    let requestedCandidateCount: Int
    let checkedCandidateCount: Int
    let escapingCandidate: URL?
}

nonisolated enum SafePathContainmentResult: Equatable, Sendable {
    case complete(SafePathContainmentEvidence)
    case cancelled(SafePathContainmentEvidence)
}

/// Serializes path containment probes away from UI-isolated owners. Resolving the nearest
/// existing ancestor can synchronously query every path component on a slow or unavailable
/// volume, so callers receive immutable complete/cancelled evidence instead of invoking
/// `SafePathComponent.isContained` while building SwiftUI state.
actor SafePathContainmentService {
    typealias Contains = @Sendable (URL, URL) -> Bool

    static let shared = SafePathContainmentService()

    private let contains: Contains
    private let signposter = OSSignposter(
        subsystem: "com.aagedal.photo-agent",
        category: "SafePathContainment"
    )

    init(
        contains: @escaping Contains = { candidate, root in
            SafePathComponent.isContained(candidate, in: root)
        }
    ) {
        self.contains = contains
    }

    func inspect(_ request: SafePathContainmentRequest) -> SafePathContainmentResult {
        let signpostID = signposter.makeSignpostID()
        let interval = signposter.beginInterval("Inspect", id: signpostID)
        var checkedCandidateCount = 0

        func evidence(escapingCandidate: URL? = nil) -> SafePathContainmentEvidence {
            SafePathContainmentEvidence(
                requestID: request.requestID,
                root: request.root,
                requestedCandidateCount: request.candidates.count,
                checkedCandidateCount: checkedCandidateCount,
                escapingCandidate: escapingCandidate
            )
        }

        guard !Task.isCancelled else {
            signposter.endInterval("Inspect", interval, "result=cancelled checked=0")
            return .cancelled(evidence())
        }

        for candidate in request.candidates {
            guard !Task.isCancelled else {
                signposter.endInterval(
                    "Inspect",
                    interval,
                    "result=cancelled checked=\(checkedCandidateCount)"
                )
                return .cancelled(evidence())
            }

            let isContained = contains(candidate, request.root)
            guard !Task.isCancelled else {
                signposter.endInterval(
                    "Inspect",
                    interval,
                    "result=cancelled checked=\(checkedCandidateCount)"
                )
                return .cancelled(evidence())
            }

            checkedCandidateCount += 1
            guard isContained else {
                signposter.endInterval(
                    "Inspect",
                    interval,
                    "result=escaped checked=\(checkedCandidateCount)"
                )
                return .complete(evidence(escapingCandidate: candidate))
            }
        }

        signposter.endInterval(
            "Inspect",
            interval,
            "result=contained checked=\(checkedCandidateCount)"
        )
        return .complete(evidence())
    }
}
