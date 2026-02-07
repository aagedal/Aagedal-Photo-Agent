import SwiftUI

struct FTPServerForm: View {
    @Bindable var viewModel: FTPViewModel

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
            }

            TextField("Username", text: $viewModel.editingConnection.username)
                .textFieldStyle(.roundedBorder)

            SecureField("Password", text: $viewModel.editingPassword)
                .textFieldStyle(.roundedBorder)

            TextField("Remote Path", text: $viewModel.editingConnection.remotePath)
                .textFieldStyle(.roundedBorder)

            Toggle("Use SFTP", isOn: $viewModel.editingConnection.useSFTP)

            if viewModel.editingConnection.useSFTP {
                Toggle("Allow insecure host verification", isOn: $viewModel.editingConnection.allowInsecureHostVerification)
                    .font(.caption)
                Text("Only enable this for legacy servers or testing.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel") {
                    viewModel.isShowingServerForm = false
                }
                Button("Save") {
                    viewModel.saveEditingConnection()
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.editingConnection.name.isEmpty || viewModel.editingConnection.host.isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 380)
    }
}
