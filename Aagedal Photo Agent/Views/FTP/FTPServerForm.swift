import SwiftUI

struct FTPServerForm: View {
    @Bindable var viewModel: FTPViewModel
    @State private var isConfirmingInsecureSave = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("FTP Server")
                .font(.headline)

            TextField("Connection Name", text: $viewModel.editingConnection.name)
                .textFieldStyle(.roundedBorder)

            HStack {
                TextField("Host", text: $viewModel.editingConnection.host)
                    .textFieldStyle(.roundedBorder)
                TextField("Port", value: $viewModel.editingConnection.port, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                    .onChange(of: viewModel.editingConnection.port) {
                        viewModel.editingConnection.port = min(max(viewModel.editingConnection.port, 1), 65535)
                    }
            }

            TextField("Username", text: $viewModel.editingConnection.username)
                .textFieldStyle(.roundedBorder)

            SecureField("Password", text: $viewModel.editingPassword)
                .textFieldStyle(.roundedBorder)

            TextField("Remote Path", text: $viewModel.editingConnection.remotePath)
                .textFieldStyle(.roundedBorder)

            if viewModel.editingConnection.useSFTP {
                // Legacy profile: SFTP can't work with macOS's curl, so the only offered
                // action is switching it off (to FTPS, on the FTP port if still on 22).
                Label(FTPConnection.sftpUnavailableMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Switch to FTPS") {
                    viewModel.editingConnection.useSFTP = false
                    viewModel.editingConnection.useTLS = true
                    if viewModel.editingConnection.port == 22 {
                        viewModel.editingConnection.port = 21
                    }
                }
            } else {
                Toggle("Use TLS (FTPS)", isOn: $viewModel.editingConnection.useTLS)

                if viewModel.editingConnection.useTLS {
                    Toggle("Allow insecure certificate verification", isOn: $viewModel.editingConnection.allowInsecureHostVerification)
                        .font(.caption)
                    Text("Only enable this for self-signed certificates or testing.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Label(
                        "Plain FTP sends your username, password, and files unencrypted. Enable TLS.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Text("SFTP isn't available with macOS's built-in curl; use FTPS.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Label(
                viewModel.editingConnection.transportSecurity.badgeTitle,
                systemImage: viewModel.editingConnection.transportSecurity.isInsecure
                    ? "exclamationmark.shield.fill"
                    : "checkmark.shield.fill"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(
                viewModel.editingConnection.transportSecurity.isInsecure ? .orange : .green
            )
            .accessibilityLabel(
                "Transport security, \(viewModel.editingConnection.transportSecurity.evidenceDescription)"
            )

            connectionTestStatus

            if let serverFormError = viewModel.serverFormError {
                Label(serverFormError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack {
                Button("Test Connection") {
                    viewModel.testConnection()
                }
                .disabled(
                    viewModel.editingConnection.host.isEmpty ||
                    viewModel.editingConnection.username.isEmpty ||
                    viewModel.editingPassword.isEmpty ||
                    viewModel.editingConnection.useSFTP ||
                    viewModel.connectionTest == .testing
                )
                Spacer()
                Button("Cancel") {
                    viewModel.isShowingServerForm = false
                }
                Button("Save") {
                    if viewModel.editingConnection.transportSecurity.isInsecure {
                        isConfirmingInsecureSave = true
                    } else {
                        viewModel.saveEditingConnection()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(saveValidationMessage != nil)
                .help(saveValidationMessage ?? "")
            }
        }
        .padding()
        .frame(minWidth: 380)
        // A stale "Connected"/error result is misleading once any field changes.
        .onChange(of: viewModel.editingConnection) { viewModel.resetConnectionTest() }
        .onChange(of: viewModel.editingPassword) { viewModel.resetConnectionTest() }
        .confirmationDialog(
            "Save an insecure delivery profile?",
            isPresented: $isConfirmingInsecureSave,
            titleVisibility: .visible
        ) {
            Button("Save Insecure Profile", role: .destructive) {
                viewModel.saveEditingConnection(acknowledgingInsecureTransport: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(insecureSaveMessage)
        }
    }

    @ViewBuilder
    private var connectionTestStatus: some View {
        switch viewModel.connectionTest {
        case .idle:
            EmptyView()
        case .testing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Testing connection…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .success(let note):
            Label(note ?? "Connected", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
                .fixedSize(horizontal: false, vertical: true)
        case .failure(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Save stays disabled until the profile could actually authenticate (non-empty user name
    /// and password, a usable host), rather than failing later for every file at upload time.
    private var saveValidationMessage: String? {
        viewModel.editingConnection.saveValidationMessage(password: viewModel.editingPassword)
    }

    private var insecureSaveMessage: String {
        switch viewModel.editingConnection.transportSecurity.protocolKind {
        case .ftp:
            "Plain FTP exposes the username, password, and files in transit. Verified FTPS is recommended."
        case .sftp:
            "Host verification is disabled, so the server identity is not authenticated. SFTP isn't available with macOS's built-in curl; verified FTPS is recommended."
        case .explicitFTPS:
            "Certificate verification is disabled, so the server identity is not authenticated. Verified FTPS is recommended."
        }
    }
}
