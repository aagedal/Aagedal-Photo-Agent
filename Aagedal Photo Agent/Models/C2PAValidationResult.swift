import Foundation

/// The app's verification state. This is intentionally separate from SwiftExif's
/// parsed C2PA manifest representation: a manifest can be present without being valid.
nonisolated enum C2PAValidationStatus: String, Codable, Sendable, Equatable {
    case trusted
    case untrusted
    case invalid
    case unsupported
    case notPresent
    /// The credential is structurally valid, but no trust list was available to
    /// determine whether its signer should be trusted.
    case trustNotConfigured
    case validationFailed
}

/// Identifies the trust policy that recognized a credential's signer. The
/// interim list remains useful for older assets but is frozen, so it must not
/// be presented as equivalent to current official-program trust.
nonisolated enum C2PATrustSource: String, Codable, Sendable, Equatable {
    case official
    case legacy
}

nonisolated struct C2PAValidationResult: Codable, Sendable, Equatable {
    let status: C2PAValidationStatus
    let signer: String?
    let issuer: String?
    let message: String
    let rawValidationCodes: [String]
    let trustSource: C2PATrustSource?

    init(
        status: C2PAValidationStatus,
        signer: String? = nil,
        issuer: String? = nil,
        message: String,
        rawValidationCodes: [String] = [],
        trustSource: C2PATrustSource? = nil
    ) {
        self.status = status
        self.signer = signer
        self.issuer = issuer
        self.message = message
        self.rawValidationCodes = rawValidationCodes
        self.trustSource = trustSource
    }
}

extension C2PAValidationResult {
    static let unavailable = C2PAValidationResult(
        status: .unsupported,
        message: "Validation is unavailable because c2patool is not bundled with this app."
    )
}

/// Recoverable failures shown by the Content Credentials inspector. Messages are
/// deliberately generic: parser and process errors can contain source paths or
/// claim data, neither of which belongs in an error banner.
nonisolated enum C2PAInspectionFailure: Sendable, Equatable {
    case malformed
    case unavailableTool
    case accessDenied
    case validationFailed

    var title: String {
        switch self {
        case .malformed: "Malformed Content Credentials"
        case .unavailableTool: "Validation Tool Unavailable"
        case .accessDenied: "Access Denied"
        case .validationFailed: "Validation Failed"
        }
    }

    var message: String {
        switch self {
        case .malformed:
            "The image's Content Credentials data is malformed or uses an unsupported structure."
        case .unavailableTool:
            "Content Credentials validation is unavailable because the required validation tool is not included in this app."
        case .accessDenied:
            "The image cannot be read with the current permission. Reopen its folder or file, then try again."
        case .validationFailed:
            "Content Credentials could not be validated. The image was not changed. Try again."
        }
    }

    static func metadataRead(error: any Error) -> C2PAInspectionFailure {
        isAccessDenied(error) ? .accessDenied : .malformed
    }

    static func validation(error: any Error) -> C2PAInspectionFailure {
        if case C2PASigningError.c2patoolMissing = error {
            return .unavailableTool
        }
        if case C2PAValidationError.malformedOutput = error {
            return .malformed
        }
        return isAccessDenied(error) ? .accessDenied : .validationFailed
    }

    private static func isAccessDenied(_ error: any Error) -> Bool {
        var cursor: NSError? = error as NSError
        // Foundation errors can wrap a POSIX or Cocoa permission error. Cap the
        // traversal so a malformed underlying-error chain cannot loop forever.
        for _ in 0..<8 {
            guard let candidate = cursor else { return false }
            if candidate.domain == NSCocoaErrorDomain,
               candidate.code == CocoaError.Code.fileReadNoPermission.rawValue {
                return true
            }
            if candidate.domain == NSPOSIXErrorDomain,
               (candidate.code == POSIXErrorCode.EACCES.rawValue
                || candidate.code == POSIXErrorCode.EPERM.rawValue) {
                return true
            }
            if candidate.domain == NSURLErrorDomain,
               candidate.code == URLError.Code.noPermissionsToReadFile.rawValue {
                return true
            }
            cursor = candidate.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }
}
