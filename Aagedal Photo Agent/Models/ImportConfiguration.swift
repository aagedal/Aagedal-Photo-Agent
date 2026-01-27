import Foundation

enum ImportFileTypeFilter: String, CaseIterable, Sendable {
    case rawOnly = "RAW Only"
    case jpegOnly = "JPEG Only"
    case both = "Both"
}

struct ImportConfiguration {
    var sourceURL: URL?
    var destinationBaseURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Photos")
    var importTitle: String = ""
    var fileTypeFilter: ImportFileTypeFilter = .both
    var createSubFolders: Bool = true
    var applyMetadata: Bool = false
    var metadata: IPTCMetadata = IPTCMetadata()
    var openFolderAfterImport: Bool = true

    var destinationFolderName: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let dateStr = formatter.string(from: Date())
        let title = importTitle.trimmingCharacters(in: .whitespaces)
        if title.isEmpty {
            return dateStr
        }
        return "\(dateStr) \u{2013} \(title)"
    }

    var destinationFolderURL: URL {
        destinationBaseURL.appendingPathComponent(destinationFolderName)
    }
}
