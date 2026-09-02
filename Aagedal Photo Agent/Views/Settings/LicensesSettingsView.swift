import SwiftUI

struct LicensesSettingsView: View {
    private struct Component: Identifiable {
        let name: String
        let detail: String
        let licenseName: String
        let licenseResource: String
        let url: URL?

        var id: String { name }
    }

    private static let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""

    private static let components: [Component] = [
        Component(
            name: "Aagedal Photo Agent",
            detail: "Version \(appVersion) — © Truls Aagedal",
            licenseName: "GPL-3.0",
            licenseResource: "License-GPL-3.0",
            url: URL(string: "https://github.com/aagedal/Aagedal-Photo-Agent")
        ),
        Component(
            name: "FFmpeg",
            detail: "Bundled encoder for AVIF and JPEG XL export",
            licenseName: "GPL-3.0",
            licenseResource: "License-GPL-3.0",
            url: URL(string: "https://ffmpeg.org")
        ),
        Component(
            name: "c2patool",
            detail: "Bundled tool for C2PA content credentials — © Adobe",
            licenseName: "MIT",
            licenseResource: "License-c2patool",
            url: URL(string: "https://github.com/contentauth/c2pa-rs")
        ),
        Component(
            name: "Sparkle",
            detail: "Software update framework",
            licenseName: "MIT",
            licenseResource: "License-Sparkle",
            url: URL(string: "https://sparkle-project.org")
        ),
        Component(
            name: "SwiftMediaMetadata",
            detail: "Pure-Swift image, audio, and video metadata engine",
            licenseName: "GPL-3.0",
            licenseResource: "License-GPL-3.0",
            url: URL(string: "https://github.com/aagedal/SwiftMediaMetadata")
        ),
        Component(
            name: "AuraFace-v1",
            detail: "Face recognition model (ArcFace r100) — fal.ai",
            licenseName: "Apache-2.0",
            licenseResource: "AuraFace-LICENSE",
            url: URL(string: "https://huggingface.co/fal/AuraFace-v1")
        ),
    ]

    @State private var licenseTexts: [String: String] = [:]
    @State private var unavailableLicenseResources: Set<String> = []
    @State private var licenseLoadTasks: [String: Task<Void, Never>] = [:]
    @State private var licenseLoadRequestIDs: [String: UUID] = [:]
    @State private var expanded: Set<String> = []

    var body: some View {
        List {
            Section {
                Text("Aagedal Photo Agent is open source and bundles the following third-party components. Expand an entry to read its full license text.")
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
            }
            Section {
                ForEach(Self.components) { component in
                    DisclosureGroup(isExpanded: binding(for: component)) {
                        Text(licenseText(for: component.licenseResource))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(component.name)
                                Text(component.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(component.licenseName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.quaternary.opacity(0.5))
                                .clipShape(Capsule())
                            if let url = component.url {
                                Link(destination: url) {
                                    Image(systemName: "arrow.up.right.square")
                                }
                                .foregroundStyle(.secondary)
                                .help(url.absoluteString)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
        .onDisappear {
            cancelLicenseLoads()
        }
    }

    private func binding(for component: Component) -> Binding<Bool> {
        Binding {
            expanded.contains(component.id)
        } set: { isExpanded in
            if isExpanded {
                expanded.insert(component.id)
                loadLicenseText(component.licenseResource)
            } else {
                expanded.remove(component.id)
            }
        }
    }

    private func loadLicenseText(_ resource: String) {
        guard licenseTexts[resource] == nil,
              !unavailableLicenseResources.contains(resource),
              licenseLoadTasks[resource] == nil else { return }

        let requestID = UUID()
        licenseLoadRequestIDs[resource] = requestID
        licenseLoadTasks[resource] = Task {
            do {
                let result = try await BundleTextResourceService.shared.loadText(
                    resourceName: resource,
                    fileExtensions: ["txt", "md"],
                    requestID: requestID
                )
                guard licenseLoadRequestIDs[resource] == requestID else { return }
                licenseLoadTasks[resource] = nil
                licenseLoadRequestIDs[resource] = nil
                switch result {
                case .loaded(let snapshot):
                    licenseTexts[resource] = snapshot.text
                case .notFound:
                    unavailableLicenseResources.insert(resource)
                case .cancelled:
                    break
                }
            } catch {
                guard licenseLoadRequestIDs[resource] == requestID else { return }
                licenseLoadTasks[resource] = nil
                licenseLoadRequestIDs[resource] = nil
                unavailableLicenseResources.insert(resource)
            }
        }
    }

    private func licenseText(for resource: String) -> String {
        if let text = licenseTexts[resource] { return text }
        if unavailableLicenseResources.contains(resource) { return "License text not found." }
        return licenseLoadTasks[resource] == nil ? "License text not found." : "Loading license text…"
    }

    private func cancelLicenseLoads() {
        for task in licenseLoadTasks.values {
            task.cancel()
        }
        licenseLoadTasks.removeAll()
        licenseLoadRequestIDs.removeAll()
    }
}
