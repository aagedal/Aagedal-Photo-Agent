import Foundation

/// The app's verification state. This is intentionally separate from SwiftExif's
/// parsed C2PA manifest representation: a manifest can be present without being valid.
nonisolated enum C2PAValidationStatus: String, Codable, Sendable, Equatable {
    case trusted
    case untrusted
    case invalid
    case unsupported
    case notPresent
    case validationFailed
}

nonisolated struct C2PAValidationResult: Codable, Sendable, Equatable {
    let status: C2PAValidationStatus
    let signer: String?
    let issuer: String?
    let message: String
    let rawValidationCodes: [String]

    init(
        status: C2PAValidationStatus,
        signer: String? = nil,
        issuer: String? = nil,
        message: String,
        rawValidationCodes: [String] = []
    ) {
        self.status = status
        self.signer = signer
        self.issuer = issuer
        self.message = message
        self.rawValidationCodes = rawValidationCodes
    }
}

extension C2PAValidationResult {
    static let unavailable = C2PAValidationResult(
        status: .unsupported,
        message: "Validation is unavailable because c2patool is not bundled with this app."
    )
}
