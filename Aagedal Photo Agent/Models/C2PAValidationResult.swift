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
