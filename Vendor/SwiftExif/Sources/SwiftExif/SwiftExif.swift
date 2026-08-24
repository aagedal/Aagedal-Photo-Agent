import Foundation

/// Read all metadata from an image file at the given URL.
/// Supports JPEG, TIFF, RAW (DNG, CR2, NEF, ARW), JPEG XL, PNG, and AVIF.
public func readMetadata(from url: URL) throws -> ImageMetadata {
    try ImageMetadata.read(from: url)
}

/// Read all metadata from image data in memory.
/// Format is automatically detected from magic bytes.
public func readMetadata(from data: Data) throws -> ImageMetadata {
    try ImageMetadata.read(from: data)
}

/// Read XMP metadata from a sidecar file (.xmp) alongside the given image URL.
public func readXMPSidecar(for imageURL: URL) throws -> XMPData {
    try XMPSidecar.read(from: XMPSidecar.sidecarURL(for: imageURL))
}

/// Read XMP metadata from a sidecar file at the given URL.
public func readXMPSidecar(from url: URL) throws -> XMPData {
    try XMPSidecar.read(from: url)
}

// MARK: - Video container convenience APIs

/// Read C2PA content provenance metadata from a video container (MP4, MOV, M4V, MXF).
/// Returns `nil` when the file exists but does not carry a C2PA manifest store.
///
/// Runs parsing on a detached task so callers can `await` without blocking
/// the main actor. Throws only for I/O errors and irrecoverable container
/// corruption — a malformed C2PA payload is reported via
/// `VideoMetadata.warnings` rather than an error, then surfaced here as `nil`.
public func readVideoC2PAMetadata(from url: URL) async throws -> C2PAData? {
    try await Task.detached(priority: .userInitiated) {
        let metadata = try VideoMetadata.read(from: url)
        return metadata.c2pa
    }.value
}

/// Read camera/clip metadata from a video container (MP4, MOV, M4V, MXF).
/// Automatically probes for a Sony NonRealTimeMeta sidecar `.XML` alongside
/// the file when no embedded metadata is present.
/// Returns `nil` when neither embedded nor sidecar metadata can be found.
public func readVideoCameraMetadata(from url: URL) async throws -> CameraMetadata? {
    try await Task.detached(priority: .userInitiated) {
        let metadata = try VideoMetadata.read(from: url)
        if let cam = metadata.camera, !cam.isEmpty { return cam }
        return nil
    }.value
}

/// Read both C2PA and camera metadata from a video container in a single pass.
///
/// This is cheaper than calling `readVideoC2PAMetadata` + `readVideoCameraMetadata`
/// separately because it parses the file only once.
public func readVideoMetadata(from url: URL) async throws -> VideoMetadata {
    try await Task.detached(priority: .userInitiated) {
        try VideoMetadata.read(from: url)
    }.value
}
