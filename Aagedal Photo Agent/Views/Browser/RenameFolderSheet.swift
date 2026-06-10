import SwiftUI

/// Rename-folder dialog. A sheet rather than an `.alert` because alert text
/// fields on macOS don't re-read their binding after the first presentation —
/// the field comes back empty every time after that.
struct RenameFolderSheet: View {
    @Bindable var viewModel: BrowserViewModel
    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Folder")
                .font(.headline)

            TextField("Name", text: $viewModel.renameSubfolderNewName)
                .textFieldStyle(.roundedBorder)
                .focused($nameFieldFocused)
                .frame(width: 280)
                .onSubmit { commit() }

            HStack {
                Spacer()
                Button("Cancel") {
                    cancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("Rename") {
                    commit()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(viewModel.renameSubfolderNewName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .onAppear {
            // Focusing the field selects the whole name, so typing replaces it
            // while arrow keys still allow partial edits.
            nameFieldFocused = true
        }
    }

    private func commit() {
        viewModel.renamePendingSubfolder()
        viewModel.showRenameSubfolderAlert = false
    }

    private func cancel() {
        viewModel.pendingRenameSubfolderURL = nil
        viewModel.showRenameSubfolderAlert = false
    }
}
