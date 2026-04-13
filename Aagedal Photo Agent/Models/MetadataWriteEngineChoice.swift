import Foundation

enum MetadataWriteEngineChoice: String, CaseIterable, Sendable {
    case swiftExif = "swiftExif"
    case exifTool = "exifTool"

    var displayName: String {
        switch self {
        case .swiftExif: return "SwiftExif (Fast)"
        case .exifTool: return "ExifTool (Compatible)"
        }
    }

    var description: String {
        switch self {
        case .swiftExif: return "Fast native Swift metadata engine. Recommended for most workflows."
        case .exifTool: return "Industry-standard Perl-based engine. Use if you experience compatibility issues."
        }
    }
}
