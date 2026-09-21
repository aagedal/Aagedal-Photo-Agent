import AppKit
import SwiftUI

@MainActor
@Observable
private final class AutomationSettingsModel {
    private let store = MCPAuthorizationStore()

    var configuration = MCPAuthorizationConfiguration()
    var message: String?

    init() {
        reload()
    }

    func reload() {
        do {
            configuration = try store.load()
            message = nil
        } catch {
            configuration = MCPAuthorizationConfiguration()
            message = error.localizedDescription
        }
    }

    func setEnabled(_ enabled: Bool) {
        do {
            try store.setEnabled(enabled)
            reload()
        } catch {
            message = error.localizedDescription
        }
    }

    func setTeamCreation(_ enabled: Bool) {
        do {
            var current = try store.load()
            current.allowsTeamCreation = enabled
            try store.save(current)
            reload()
        } catch {
            message = error.localizedDescription
        }
    }

    func addFolder() {
        let panel = NSOpenPanel()
        panel.title = "Authorize Folder for Local Automation"
        panel.message = "Photo Agent automation will be able to inspect and, after separate tool confirmation, modify supported photos inside this folder."
        panel.prompt = "Authorize Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.addRoot(url)
            reload()
        } catch {
            message = error.localizedDescription
        }
    }

    func remove(_ root: MCPAuthorizedRoot) {
        do {
            try store.removeRoot(id: root.id)
            reload()
        } catch {
            message = error.localizedDescription
        }
    }

    var helperURL: URL? {
        Bundle.main.url(forAuxiliaryExecutable: "photo-agent-mcp")
            ?? Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("photo-agent-mcp")
    }

    var codexInstallCommand: String? {
        guard let helperURL else { return nil }
        return "codex mcp add aagedal-photo-agent -- \(shellQuote(helperURL.path))"
    }

    var claudeCodeInstallCommand: String? {
        guard let helperURL else { return nil }
        return "claude mcp add --transport stdio aagedal-photo-agent -- \(shellQuote(helperURL.path))"
    }

    var openCodeV2InstallCommand: String? {
        guard let helperURL else { return nil }
        return "opencode mcp add aagedal-photo-agent --global -- \(shellQuote(helperURL.path))"
    }

    var openCode1Configuration: String? {
        guard let helperURL else { return nil }
        let configuration: [String: Any] = [
            "mcp": [
                "aagedal-photo-agent": [
                    "type": "local",
                    "command": [helperURL.path],
                    "enabled": true,
                ] as [String: Any],
            ],
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: configuration,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

struct AutomationSettingsView: View {
    @State private var model = AutomationSettingsModel()

    var body: some View {
        Form {
            Section("Local MCP Server") {
                Toggle(
                    "Enable local automation",
                    isOn: Binding(
                        get: { model.configuration.isEnabled },
                        set: { model.setEnabled($0) }
                    )
                )
                Text("Off by default. When enabled, a local AI client can launch Photo Agent's bundled STDIO server. It does not listen on the network.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Allow team creation", isOn: Binding(
                    get: { model.configuration.allowsTeamCreation == true },
                    set: { model.setTeamCreation($0) }
                ))
                .disabled(!model.configuration.isEnabled)
                Text("Allows AI clients to add teams and player rosters. With Teams iCloud sync enabled, review each import in Teams → Review Imports before it is added and synced. Existing teams are never replaced.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Proofreading previews store existing and proposed text locally so they can survive a client restart. Plans expire after five minutes and are removed from the archive on the next successful preparation. Removing access immediately invalidates existing plans.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Authorized Folders") {
                if model.configuration.roots.isEmpty {
                    Text("No folders authorized")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.configuration.roots) { root in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(root.displayName)
                                Text(root.canonicalPath)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            Spacer()
                            Button("Remove", role: .destructive) { model.remove(root) }
                                .accessibilityLabel("Remove automation access to \(root.displayName)")
                        }
                    }
                }
                Button("Add Folder…") { model.addFolder() }
            }

            Section("Client Setup") {
                if let helperURL = model.helperURL,
                   let codexCommand = model.codexInstallCommand,
                   let claudeCommand = model.claudeCodeInstallCommand,
                   let openCode1Config = model.openCode1Configuration,
                   let openCodeV2Command = model.openCodeV2InstallCommand {
                    LabeledContent("Server executable") {
                        Text(helperURL.path).font(.caption).textSelection(.enabled)
                    }
                    clientSetup("Codex CLI", text: codexCommand, copyLabel: "Copy Codex Install Command")
                    clientSetup("Claude Code", text: claudeCommand, copyLabel: "Copy Claude Code Install Command")
                    clientSetup("OpenCode 1.x", text: openCode1Config, copyLabel: "Copy OpenCode 1.x Config")
                    Text("Merge the mcp entry into your existing opencode.json. OpenCode 1.x places server names directly under mcp.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    clientSetup("OpenCode v2", text: openCodeV2Command, copyLabel: "Copy OpenCode v2 Install Command")
                } else {
                    Text("The bundled MCP executable is unavailable in this build.")
                        .foregroundStyle(.secondary)
                }
                Text("Tools receive explicit photo or folder paths. Photo Agent rechecks the enabled setting, folder grant, path identity, and operation authority for every call. Removing a folder revokes later calls, including from a connected client.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Proofreading Plan Review") {
                AutomationPatchReviewView()
                    .id(model.configuration.authorizationRevision)
            }

            Section("Operation History") {
                AutomationOperationHistoryView()
            }

            Section("Privacy and activity") {
                Text("Filenames and metadata are treated as untrusted data and are never instructions. Tool output can contain private metadata from authorized photos. Mutating tools will use Photo Agent's preview, conflict, preservation, verification, and recovery boundaries; this implementation stage exposes read-only discovery, authorization, revision, owned-draft and effective editorial metadata inspection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Ordinary inspection results are not retained by Photo Agent. Proofreading previews use the local archive described above. Mutation tools will not become available until their privacy-safe operation history and recovery evidence are implemented.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let message = model.message {
                Section("Automation Error") {
                    Text(message).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Automation")
        .onAppear { model.reload() }
    }

    private func clientSetup(_ title: String, text: String, copyLabel: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(text).font(.caption.monospaced()).textSelection(.enabled)
            Button(copyLabel) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
    }
}
