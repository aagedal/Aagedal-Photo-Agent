import SwiftUI

/// Decides, once per major release, whether to show What's New. Only people upgrading from an
/// earlier version see it; a fresh install records the release as seen without showing it.
nonisolated enum WhatsNewPresentation {
    static let currentRelease = "3.0"
    /// Local only: not in `PreferencesSyncService.syncedKeys`, so each Mac shows it once.
    static let seenReleaseKey = "whatsNew.seenRelease"
    static let featureGuideURL = URL(string: "https://github.com/aagedal/Aagedal-Photo-Agent/blob/main/docs/feature-help-3.0.md")!
    static let limitationsURL = URL(string: "https://github.com/aagedal/Aagedal-Photo-Agent/blob/main/docs/limitations-3.0.md")!

    /// Must run at launch, before this run writes folder history or thumbnail settings, which
    /// are the signs of an earlier installation.
    static func decideAtLaunch(in store: UserDefaults) -> Bool {
        guard store.string(forKey: seenReleaseKey) != currentRelease else { return false }
        let upgraded = MetadataFieldID.earlierInstallationKeys.contains { store.object(forKey: $0) != nil }
        if !upgraded { markSeen(in: store) }
        return upgraded
    }

    static func markSeen(in store: UserDefaults) {
        store.set(currentRelease, forKey: seenReleaseKey)
    }
}

/// Launch decision shared by every window, so only the first window shows the sheet.
@MainActor
final class WhatsNewLaunchState {
    static let shared = WhatsNewLaunchState()
    private var pending = false

    func decide(in store: UserDefaults) {
        pending = WhatsNewPresentation.decideAtLaunch(in: store)
    }

    /// Returns true once, and records the release as seen.
    func consume(in store: UserDefaults) -> Bool {
        guard pending else { return false }
        pending = false
        WhatsNewPresentation.markSeen(in: store)
        return true
    }
}

struct WhatsNewView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                WhatsNewContent()
                    .padding(24)
            }
            Divider()
            HStack {
                Button("Feature Guide") { openURL(WhatsNewPresentation.featureGuideURL) }
                Button("Known Limitations") { openURL(WhatsNewPresentation.limitationsURL) }
                Spacer()
                Button("Continue") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 560, height: 600)
    }
}

struct WhatsNewContent: View {
    private struct Item: Identifiable {
        let symbol: String
        let title: String
        let detail: String
        var id: String { title }
    }

    private let items: [Item] = [
        Item(symbol: "text.bubble", title: "Caption Workspace",
             detail: "Work through a folder field by field with checks, Save & Next and Copy Previous."),
        Item(symbol: "waveform", title: "Voice memos",
             detail: "Sony voice memos stay with their photos, play in Caption and can be transcribed on this Mac."),
        Item(symbol: "sparkles", title: "Description Assistant",
             detail: "Fix grammar or draft a caption in Bokmål, Nynorsk or English. You review every suggestion."),
        Item(symbol: "magnifyingglass", title: "Image Analysis",
             detail: "Inspect pixels, metadata and content credentials, with map, timeline and PDF reports."),
        Item(symbol: "square.split.2x1", title: "Compare and named versions",
             detail: "Compare two photos side by side and keep alternative Develop versions of a photo."),
        Item(symbol: "character.cursor.ibeam", title: "Batch Rename",
             detail: "Reusable rename recipes that keep RAW+JPEG pairs, sidecars and voice memos together."),
    ]

    private let changes = [
        "Face scans default to Fast. Choose Thorough in Settings ▸ Face Recognition for small or turned faces.",
        "Develop Save writes to the Export Location folder (for example Edited_JPEG) and never overwrites a file.",
        "SFTP never worked. Existing SFTP servers are flagged with a one-click switch to FTPS.",
        "Your metadata panel still shows every field it did before. New fields can be hidden in Settings ▸ Metadata.",
        "If you sync through iCloud, update every Mac to 3.0.",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("What's New in Photo Agent 3.0")
                .font(.title.bold())
            VStack(alignment: .leading, spacing: 14) {
                ForEach(items) { item in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: item.symbol)
                            .font(.title2)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 30)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.headline)
                            Text(item.detail).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Changes from 2.x").font(.headline)
                ForEach(changes, id: \.self) { change in
                    Label(change, systemImage: "arrow.right.circle")
                        .labelStyle(WhatsNewBulletLabelStyle())
                }
            }
        }
    }
}

private struct WhatsNewBulletLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.icon.foregroundStyle(.secondary).accessibilityHidden(true)
            configuration.title.fixedSize(horizontal: false, vertical: true)
        }
    }
}
