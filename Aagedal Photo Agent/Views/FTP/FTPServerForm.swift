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

            Toggle("Use SFTP", isOn: $viewModel.editingConnection.useSFTP)
                .onChange(of: viewModel.editingConnection.useSFTP) { _, isSFTP in
                    // Suggest the conventional port for the transport, but only when
                    // the user is still on the other mode's default — don't clobber a
                    // port they typed themselves.
                    if isSFTP, viewModel.editingConnection.port == 21 {
                        viewModel.editingConnection.port = 22
                    } else if !isSFTP, viewModel.editingConnection.port == 22 {
                        viewModel.editingConnection.port = 21
                    }
                }

            if viewModel.editingConnection.useSFTP {
                Toggle("Allow insecure host verification", isOn: $viewModel.editingConnection.allowInsecureHostVerification)
                    .font(.caption)
                Text("Only enable this for legacy servers or testing.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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
                        "Plain FTP sends your username, password, and files unencrypted. Enable TLS, or use SFTP.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                }
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

            Divider()

            HStack {
                Button("Test Connection") {
                    viewModel.testConnection()
                }
                .disabled(
                    viewModel.editingConnection.host.isEmpty ||
                    viewModel.editingConnection.username.isEmpty ||
                    viewModel.editingPassword.isEmpty ||
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
                .disabled(viewModel.editingConnection.name.isEmpty || viewModel.editingConnection.host.isEmpty || viewModel.editingConnection.port < 1 || viewModel.editingConnection.port > 65535)
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
        case .success:
            Label("Connected", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .failure(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var insecureSaveMessage: String {
        switch viewModel.editingConnection.transportSecurity.protocolKind {
        case .ftp:
            "Plain FTP exposes the username, password, and files in transit. SFTP or verified FTPS is recommended."
        case .sftp:
            "Host verification is disabled, so the server identity is not authenticated. Verified SFTP is recommended."
        case .explicitFTPS:
            "Certificate verification is disabled, so the server identity is not authenticated. Verified FTPS is recommended."
        }
    }
}
