import Foundation

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
