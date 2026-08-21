import Foundation

extension SwiftExifReadService {
    /// Reads a completed write through the same production parser used by the rest of the app,
    /// then compares canonical values. The report is `Sendable` and contains no UI state.
    func verifyReadBack(
        at url: URL,
        expected: IPTCMetadata,
        fields: [IPTCMetadataVerificationField] = IPTCMetadataVerificationField.writableFields
    ) async throws -> IPTCMetadataVerificationReport {
        let actual = try await readFullMetadata(url: url)
        return IPTCMetadataVerifier.compare(expected: expected, actual: actual, fields: fields)
    }
}

