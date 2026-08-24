import Foundation

/// Apple Photos `.aae` sidecar files describe a non-destructive edit that the Photos app
/// applied to an image. The file is a property list (binary or XML) with a small set of
/// well-known keys; the actual edit operations live in the opaque `adjustmentData` blob,
/// which only the Photos app knows how to interpret.
///
/// This reader extracts the metadata fields a photo-management app cares about: who made
/// the edit, when, and which format version. The opaque blob is preserved so callers can
/// hand it back unchanged.
public struct AAESidecar: Sendable, Equatable {
    public let adjustmentBaseVersion: Int?
    public let adjustmentEditorBundleID: String?
    public let adjustmentFormatIdentifier: String?
    public let adjustmentFormatVersion: String?
    public let adjustmentTimestamp: Date?
    public let adjustmentRenderTypes: Int?
    public let adjustmentData: Data?

    public init(
        adjustmentBaseVersion: Int? = nil,
        adjustmentEditorBundleID: String? = nil,
        adjustmentFormatIdentifier: String? = nil,
        adjustmentFormatVersion: String? = nil,
        adjustmentTimestamp: Date? = nil,
        adjustmentRenderTypes: Int? = nil,
        adjustmentData: Data? = nil
    ) {
        self.adjustmentBaseVersion = adjustmentBaseVersion
        self.adjustmentEditorBundleID = adjustmentEditorBundleID
        self.adjustmentFormatIdentifier = adjustmentFormatIdentifier
        self.adjustmentFormatVersion = adjustmentFormatVersion
        self.adjustmentTimestamp = adjustmentTimestamp
        self.adjustmentRenderTypes = adjustmentRenderTypes
        self.adjustmentData = adjustmentData
    }

    /// Read an .aae sidecar from disk.
    public static func read(from url: URL) throws -> AAESidecar {
        let data = try Data(contentsOf: url)
        return try read(data)
    }

    /// Parse an .aae sidecar from raw bytes (binary or XML plist).
    public static func read(_ data: Data) throws -> AAESidecar {
        let plist: Any
        do {
            plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        } catch {
            throw MetadataError.invalidAAE("AAE: not a valid property list (\(error))")
        }

        guard let dict = plist as? [String: Any] else {
            throw MetadataError.invalidAAE("AAE: top-level value is not a dictionary")
        }

        return AAESidecar(
            adjustmentBaseVersion:    dict["adjustmentBaseVersion"]    as? Int,
            adjustmentEditorBundleID: dict["adjustmentEditorBundleID"] as? String,
            adjustmentFormatIdentifier: dict["adjustmentFormatIdentifier"] as? String,
            adjustmentFormatVersion:  dict["adjustmentFormatVersion"]  as? String,
            adjustmentTimestamp:      dict["adjustmentTimestamp"]      as? Date,
            adjustmentRenderTypes:    dict["adjustmentRenderTypes"]    as? Int,
            adjustmentData:           dict["adjustmentData"]           as? Data
        )
    }
}
