import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @State private var settingsViewModel = SettingsViewModel()
    @State private var ftpViewModel = FTPViewModel()
    @State private var presetViewModel = PresetViewModel()

    var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            ftpTab
                .tabItem {
                    Label("FTP", systemImage: "arrow.up.to.line")
                }

            presetsTab
                .tabItem {
                    Label("Presets", systemImage: "doc.on.clipboard")
                }
        }
        .frame(width: 500, height: 400)
        .onAppear {
            ftpViewModel.loadConnections()
            presetViewModel.loadPresets()
        }
    }

    // MARK: - General Tab

    @ViewBuilder
    private var generalTab: some View {
        Form {
            Section("ExifTool") {
                LabeledContent("Auto-detected") {
                    if let path = settingsViewModel.detectedExifToolPath {
                        Text(path)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Not found")
                            .foregroundStyle(.orange)
                    }
                }

                LabeledContent("Override Path") {
                    HStack {
                        TextField("Leave empty for auto-detect", text: $settingsViewModel.exifToolPathOverride)
                            .textFieldStyle(.roundedBorder)
                        Button("Browse...") {
                            let panel = NSOpenPanel()
                            panel.canChooseFiles = true
                            panel.canChooseDirectories = false
                            panel.allowsMultipleSelection = false
                            if panel.runModal() == .OK, let url = panel.url {
                                settingsViewModel.exifToolPathOverride = url.path
                            }
                        }
                    }
                }
            }

            Section("External Editor") {
                LabeledContent("Default Editor") {
                    HStack {
                        Text(settingsViewModel.defaultExternalEditorName)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Choose...") {
                            let panel = NSOpenPanel()
                            panel.canChooseFiles = true
                            panel.canChooseDirectories = false
                            panel.allowsMultipleSelection = false
                            panel.allowedContentTypes = [.application]
                            if panel.runModal() == .OK, let url = panel.url {
                                settingsViewModel.defaultExternalEditor = url.path
                            }
                        }
                        if !settingsViewModel.defaultExternalEditor.isEmpty {
                            Button("Clear") {
                                settingsViewModel.defaultExternalEditor = ""
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - FTP Tab

    @ViewBuilder
    private var ftpTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("FTP Servers")
                    .font(.headline)
                Spacer()
                Button {
                    ftpViewModel.startEditingConnection()
                } label: {
                    Image(systemName: "plus")
                }
            }

            if ftpViewModel.connections.isEmpty {
                Text("No FTP servers configured")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                List {
                    ForEach(ftpViewModel.connections) { conn in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(conn.name)
                                    .font(.body)
                                Text("\(conn.useSFTP ? "sftp" : "ftp")://\(conn.host):\(conn.port)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Edit") {
                                ftpViewModel.startEditingConnection(conn)
                            }
                            Button("Delete", role: .destructive) {
                                ftpViewModel.deleteConnection(conn)
                            }
                        }
                    }
                }
            }
        }
        .padding()
        .sheet(isPresented: $ftpViewModel.isShowingServerForm) {
            FTPServerForm(viewModel: ftpViewModel)
        }
    }

    // MARK: - Presets Tab

    @ViewBuilder
    private var presetsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            PresetListView(viewModel: presetViewModel)
        }
        .padding()
        .sheet(isPresented: $presetViewModel.isEditing) {
            PresetEditorView(viewModel: presetViewModel)
        }
    }
}
