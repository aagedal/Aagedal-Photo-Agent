import SwiftUI

/// Offers to correct Person Shown after a face edit made an app-applied name wrong. Attached once
/// per window (main window, full-screen viewer); `isEnabled` keeps two windows from both asking.
struct PersonShownUpdatePromptModifier: ViewModifier {
    let viewModel: FaceRecognitionViewModel
    var isEnabled: Bool = true
    /// The window's photos, so the update knows each photo's content-credential status.
    var images: () -> [ImageFile] = { [] }

    func body(content: Content) -> some View {
        let proposal = viewModel.pendingPersonShownUpdate
        let count = proposal?.photoCount ?? 0
        content.alert(
            "Update Person Shown on \(count) \(count == 1 ? "photo" : "photos")?",
            isPresented: Binding(
                get: { isEnabled && viewModel.pendingPersonShownUpdate != nil },
                set: { _ in }
            ),
            presenting: proposal
        ) { _ in
            Button("Update") {
                let known = Dictionary(images().map { ($0.url, $0.hasC2PA) }, uniquingKeysWith: { first, _ in first })
                viewModel.confirmPersonShownUpdate(knownC2PA: known)
            }
            .keyboardShortcut(.defaultAction)
            Button("Leave Photos Unchanged", role: .cancel) { viewModel.declinePersonShownUpdate() }
        } message: { proposal in
            Text("""
            \(proposal.summary)

            Only names this app applied are changed, and only in photos that still contain them. \
            Names typed by hand are left as they are.
            """)
        }
    }
}

/// Small notice shown in face views while the folder is being scanned: edits are paused because
/// the scan publishes its own snapshot of the folder when it finishes.
struct FaceScanEditingPausedNote: View {
    var body: some View {
        Label("Scanning… Editing faces is paused until the scan finishes.", systemImage: "hourglass")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            .accessibilityIdentifier("faces.scanningEditingPaused")
    }
}
