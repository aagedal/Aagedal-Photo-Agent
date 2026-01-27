import SwiftUI

@main
struct Aagedal_Photo_AgentApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open Folder...") {
                    NotificationCenter.default.post(name: .openFolder, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
            }

            CommandMenu("Rating") {
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
            }

            CommandMenu("Label") {
                Button("No Label") {
                    NotificationCenter.default.post(name: .setLabel, object: ColorLabel.none)
                }
                .keyboardShortcut("0", modifiers: [.command, .option])

                ForEach(Array(ColorLabel.allCases.dropFirst().enumerated()), id: \.element) { index, label in
                    Button(label.displayName) {
                        NotificationCenter.default.post(name: .setLabel, object: label)
                    }
                    .keyboardShortcut(
                        KeyEquivalent(Character(String(index + 1))),
                        modifiers: [.command, .option]
                    )
                }
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
}
