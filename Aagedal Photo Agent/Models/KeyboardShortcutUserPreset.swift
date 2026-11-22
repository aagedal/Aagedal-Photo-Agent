import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// A named keymap that can be saved, switched to, and shared as a file.
nonisolated struct KeyboardShortcutUserPreset: Codable, Equatable, Identifiable, Sendable {
    static let fileExtension = "apkeys"
    static let fileFormat = "com.aagedal.photoagent.keyboard-preset"
    static let fileVersion = 1

    var name: String
    /// Every command's shortcuts by command name, so the preset reads the same on any machine.
    var shortcuts: [String: [KeyboardShortcutChord]]
    var id: String { name }

    /// The preset's profile, and how many of its shortcuts this version cannot use.
    var resolved: (profile: KeyboardShortcutProfile, rejected: Int) {
        KeyboardShortcutProfile.restoring(
            shortcuts, name: name, defaults: KeyboardShortcutProfiles.profile(for: .photoAgent)
        )
    }

    private struct File: Codable {
        var format: String
        var version: Int
        var name: String
        var shortcuts: [String: [KeyboardShortcutChord]]
    }

    func fileData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(File(format: Self.fileFormat, version: Self.fileVersion, name: name, shortcuts: shortcuts))
    }
}

nonisolated extension KeyboardShortcutUserPreset {
    init(fileData data: Data) throws {
        guard let file = try? JSONDecoder().decode(File.self, from: data), file.format == Self.fileFormat else {
            throw KeyboardShortcutPresetError.notAPreset
        }
        guard file.version <= Self.fileVersion else { throw KeyboardShortcutPresetError.newerVersion }
        let name = file.name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(name: name.isEmpty ? "Imported Shortcuts" : name, shortcuts: file.shortcuts)
    }
}

nonisolated enum KeyboardShortcutPresetError: LocalizedError {
    case notAPreset, newerVersion

    var errorDescription: String? {
        switch self {
        case .notAPreset: "This file is not a Photo Agent keyboard preset."
        case .newerVersion: "This keyboard preset was made by a newer version of Photo Agent."
        }
    }
}

extension UTType {
    nonisolated static let photoAgentKeyboardPreset = UTType(
        exportedAs: KeyboardShortcutUserPreset.fileFormat, conformingTo: .json
    )
}

/// The current shortcuts as a preset file, for the share menu. The file is written only
/// when the preset is shared.
nonisolated struct KeyboardShortcutPresetShareItem: Transferable {
    let preset: KeyboardShortcutUserPreset

    static func fileName(for name: String) -> String {
        name.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
            + "." + KeyboardShortcutUserPreset.fileExtension
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .photoAgentKeyboardPreset) { item in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(fileName(for: item.preset.name))
            try item.preset.fileData().write(to: url)
            return SentTransferredFile(url)
        }
    }
}
