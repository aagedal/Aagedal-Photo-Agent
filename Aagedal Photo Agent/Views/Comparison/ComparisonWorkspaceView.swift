import SwiftUI

struct ComparisonWorkspaceView: View {
    @Bindable var model: ComparisonWorkspaceModel
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            workspace
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 12) {
            Label("Compare", systemImage: "rectangle.split.2x1")
                .font(.headline)

            if let session = model.session {
                Picker("Layout", selection: Binding(
                    get: { session.layout },
                    set: { model.setLayout($0) }
                )) {
                    Label("Side by Side", systemImage: "rectangle.split.2x1")
                        .tag(ComparisonLayout.sideBySide)
                    Label("Stacked", systemImage: "rectangle.split.1x2")
                        .tag(ComparisonLayout.stacked)
                    Label("A/B", systemImage: "square.on.square")
                        .tag(ComparisonLayout.single)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 340)

                if session.layout == .single {
                    Picker("Visible image", selection: Binding(
                        get: { session.focusedPane },
                        set: { model.focus($0) }
                    )) {
                        Text("A").tag(ComparisonPane.left)
                        Text("B").tag(ComparisonPane.right)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 90)
                    .help("Switch the visible comparison image")
                }
            }

            Spacer()

            Button("Close", systemImage: "xmark", action: onClose)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var workspace: some View {
        switch model.loadState {
        case .idle, .identifyingSources:
            progressState(
                title: "Identifying sources…",
                detail: "Computing exact source revisions before the comparison opens."
            )
        case .loadingPreviews:
            progressState(
                title: "Loading comparison…",
                detail: "Preparing bounded display previews for both panes."
            )
        case .failed(let message):
            ContentUnavailableView {
                Label("Comparison Unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { model.retry() }
            }
        case .ready:
            comparisonSurface
        }
    }

    private func progressState(title: String, detail: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var comparisonSurface: some View {
        if let session = model.session {
            switch session.layout {
            case .sideBySide:
                HSplitView {
                    pane(.left, session: session)
                        .frame(minWidth: 220)
                    pane(.right, session: session)
                        .frame(minWidth: 220)
                }
            case .stacked:
                VSplitView {
                    pane(.left, session: session)
                        .frame(minHeight: 180)
                    pane(.right, session: session)
                        .frame(minHeight: 180)
                }
            case .single:
                pane(session.focusedPane, session: session)
            }
        }
    }

    private func pane(_ pane: ComparisonPane, session: ComparisonSession) -> some View {
        ComparisonImagePane(
            pane: pane,
            source: session.source(for: pane),
            file: model.sourceFiles[pane],
            image: model.paneImages[pane],
            isFocused: session.focusedPane == pane,
            onFocus: { model.focus(pane) }
        )
    }
}

private struct ComparisonImagePane: View {
    let pane: ComparisonPane
    let source: ComparisonSource
    let file: ImageFile?
    let image: ComparisonWorkspaceModel.PaneImage?
    let isFocused: Bool
    let onFocus: () -> Void

    var body: some View {
        ZStack {
            Color.black

            if let image {
                HDRImageView(
                    cgImage: image.cgImage,
                    isHDR: image.isHDR,
                    useNearestNeighbor: false
                )
                .aspectRatio(
                    CGFloat(image.cgImage.width) / CGFloat(image.cgImage.height),
                    contentMode: .fit
                )
                .padding(1)
            } else {
                ContentUnavailableView(
                    "Preview Unavailable",
                    systemImage: "photo.badge.exclamationmark",
                    description: Text("The source remains identified. Return to Browser to choose another pair.")
                )
                .foregroundStyle(.white, .secondary)
            }

            VStack {
                HStack(alignment: .top, spacing: 8) {
                    Text(pane == .left ? "A" : "B")
                        .font(.caption.bold())
                        .foregroundStyle(.black)
                        .frame(width: 24, height: 24)
                        .background(.white, in: Circle())

                    VStack(alignment: .leading, spacing: 3) {
                        Text(file?.filename ?? source.revision.filenameAtCreation)
                            .font(.caption.bold())
                            .lineLimit(1)
                        Text(source.representation.label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.white)

                    Spacer()

                    if source.availability == .missing {
                        Label("Missing", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                    }
                }
                .padding(10)
                .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
                .padding(12)

                Spacer()
            }
        }
        .contentShape(Rectangle())
        .overlay {
            RoundedRectangle(cornerRadius: 2)
                .stroke(isFocused ? Color.accentColor : .clear, lineWidth: 3)
                .padding(2)
        }
        .onTapGesture(perform: onFocus)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "Image \(pane == .left ? "A" : "B"), \(file?.filename ?? source.revision.filenameAtCreation), \(source.representation.label)"
        )
        .accessibilityAddTraits(isFocused ? .isSelected : [])
    }
}
