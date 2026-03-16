import SwiftUI

@main
struct Aagedal_Photo_AgentApp: App {
    var body: some Scene {
        Window("Aagedal Photo Agent", id: "main") {
            ContentView()
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open Folder...") {
                    NotificationCenter.default.post(name: .openFolder, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)

                Button("Import Photos...") {
                    NotificationCenter.default.post(name: .showImport, object: nil)
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            }

            CommandGroup(replacing: .printItem) { }

            CommandMenu("Rating & Label") {
                Button("No Rating") {
                    NotificationCenter.default.post(name: .setRating, object: StarRating.none)
                }
                .keyboardShortcut("0", modifiers: .command)

                ForEach(1...5, id: \.self) { rating in
                    Button("\(rating) Star\(rating > 1 ? "s" : "")") {
                        NotificationCenter.default.post(
                            name: .setRating,
                            object: StarRating(rawValue: rating)
                        )
                    }
                    .keyboardShortcut(KeyEquivalent(Character(String(rating))), modifiers: .command)
                }

                Divider()

                Button("No Label") {
                    NotificationCenter.default.post(name: .setLabel, object: ColorLabel.none)
                }
                .keyboardShortcut("0", modifiers: .option)

                ForEach(Array(ColorLabel.allCases.dropFirst().enumerated()), id: \.element) { index, label in
                    Button(label.displayName) {
                        NotificationCenter.default.post(name: .setLabel, object: label)
                    }
                    .keyboardShortcut(
                        KeyEquivalent(Character(String(index + 1))),
                        modifiers: .option
                    )
                }
            }

            CommandGroup(after: .newItem) {
                Button("Open in Editor") {
                    let raw = UserDefaults.standard.string(forKey: UserDefaultsKeys.defaultEditDestination)
                        ?? DefaultEditDestination.internalEditor.rawValue
                    let destination = DefaultEditDestination(rawValue: raw) ?? .internalEditor
                    if destination == .internalEditor {
                        NotificationCenter.default.post(name: .openInInternalEditor, object: nil)
                    } else {
                        NotificationCenter.default.post(name: .openInExternalEditor, object: nil)
                    }
                }
                .keyboardShortcut("e", modifiers: .command)
            }

            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Move to Trash") {
                    NotificationCenter.default.post(name: .deleteSelected, object: nil)
                }
                .keyboardShortcut(.delete, modifiers: .command)
            }




            CommandMenu("Metadata") {
                Button("Process Variables") {
                    NotificationCenter.default.post(name: .processVariablesSelected, object: nil)
                }
                .keyboardShortcut("p", modifiers: .command)

                Button("Process Variables in All Images") {
                    NotificationCenter.default.post(name: .processVariablesAll, object: nil)
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])

                Divider()

                Button("Write All Pending Metadata") {
                    NotificationCenter.default.post(name: .writeAllPendingMetadata, object: nil)
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])

                Divider()

                Button("Apply Template...") {
                    NotificationCenter.default.post(name: .showTemplatePalette, object: nil)
                }
                .keyboardShortcut("t", modifiers: .command)
            }

            CommandMenu("Image") {
                Button("Previous Image") {
                    NotificationCenter.default.post(name: .selectPreviousImage, object: nil)
                }
                .keyboardShortcut("b", modifiers: .command)

                Button("Next Image") {
                    NotificationCenter.default.post(name: .selectNextImage, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)

                Divider()

                Button("Rotate Right") {
                    NotificationCenter.default.post(name: .rotateClockwise, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)

                Button("Rotate Left") {
                    NotificationCenter.default.post(name: .rotateCounterclockwise, object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Divider()

                Button("Render Selected") {
                    NotificationCenter.default.post(name: .renderSelected, object: nil)
                }
                .keyboardShortcut("s", modifiers: .command)

                Button("Render All") {
                    NotificationCenter.default.post(name: .renderAll, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Divider()

                Button("Save as JPEG") {
                    NotificationCenter.default.post(name: .saveAsJPEG, object: nil)
                }

                Button("Save as PNG") {
                    NotificationCenter.default.post(name: .saveAsPNG, object: nil)
                }

                Divider()

                Button("Rename...") {
                    NotificationCenter.default.post(name: .renameSelected, object: nil)
                }

                Button("Duplicate") {
                    NotificationCenter.default.post(name: .duplicateSelected, object: nil)
                }
                .keyboardShortcut("d", modifiers: .command)

                Divider()

                Button("Reset All Edits") {
                    NotificationCenter.default.post(name: .resetAllEdits, object: nil)
                }

                Button("Remove All IPTC Metadata") {
                    NotificationCenter.default.post(name: .removeAllIPTC, object: nil)
                }
            }

            CommandMenu("Upload") {
                Button("Upload Selected") {
                    NotificationCenter.default.post(name: .uploadSelected, object: nil)
                }
                .keyboardShortcut("u", modifiers: .command)

                Button("Upload All") {
                    NotificationCenter.default.post(name: .uploadAll, object: nil)
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
        }
    }
}

extension Notification.Name {
    static let openFolder = Notification.Name("openFolder")
    static let setRating = Notification.Name("setRating")
    static let setLabel = Notification.Name("setLabel")
    static let faceMetadataDidChange = Notification.Name("faceMetadataDidChange")
    static let openInExternalEditor = Notification.Name("openInExternalEditor")
    static let openInInternalEditor = Notification.Name("openInInternalEditor")
    static let deleteSelected = Notification.Name("deleteSelected")
    static let showImport = Notification.Name("showImport")
    static let importCompleted = Notification.Name("importCompleted")
    static let selectPreviousImage = Notification.Name("selectPreviousImage")
    static let selectNextImage = Notification.Name("selectNextImage")
    static let processVariablesSelected = Notification.Name("processVariablesSelected")
    static let processVariablesAll = Notification.Name("processVariablesAll")
    static let showTemplatePalette = Notification.Name("showTemplatePalette")
    static let uploadSelected = Notification.Name("uploadSelected")
    static let uploadAll = Notification.Name("uploadAll")
    static let showKnownPeopleDatabase = Notification.Name("showKnownPeopleDatabase")
    static let knownPeopleDatabaseDidChange = Notification.Name("knownPeopleDatabaseDidChange")
    static let rotateClockwise = Notification.Name("rotateClockwise")
    static let rotateCounterclockwise = Notification.Name("rotateCounterclockwise")
    static let writeAllPendingMetadata = Notification.Name("writeAllPendingMetadata")
    static let renderSelected = Notification.Name("renderSelected")
    static let renderAll = Notification.Name("renderAll")
    static let saveAsJPEG = Notification.Name("saveAsJPEG")
    static let saveAsPNG = Notification.Name("saveAsPNG")
    static let renameSelected = Notification.Name("renameSelected")
    static let duplicateSelected = Notification.Name("duplicateSelected")
    static let resetAllEdits = Notification.Name("resetAllEdits")
    static let removeAllIPTC = Notification.Name("removeAllIPTC")
    static let scopeSourceImageDidChange = Notification.Name("scopeSourceImageDidChange")
    static let showAllFilesChanged = Notification.Name("showAllFilesChanged")
}
