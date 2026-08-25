import SwiftUI
import UniformTypeIdentifiers
import AppKit

// MARK: - Selection State (Observable for fine-grained updates)

@Observable
final class FaceSelectionState {
    var selectedFaceIDs: Set<UUID> = []
    var draggedFaceIDs: Set<UUID> = []
    var draggedGroupID: UUID?
    var focusedFaceID: UUID?
    var selectionAnchorID: UUID?  // For shift-selection

    func isSelected(_ faceID: UUID) -> Bool {
        selectedFaceIDs.contains(faceID)
    }

    func isDragged(_ faceID: UUID) -> Bool {
        draggedFaceIDs.contains(faceID)
    }

    func isFocused(_ faceID: UUID) -> Bool {
        focusedFaceID == faceID
    }

    func toggleSelection(_ faceID: UUID, commandKey: Bool) {
        if commandKey {
            if selectedFaceIDs.contains(faceID) {
                selectedFaceIDs.remove(faceID)
            } else {
                selectedFaceIDs.insert(faceID)
            }
        } else {
            selectedFaceIDs.removeAll()
            selectedFaceIDs.insert(faceID)
        }
        focusedFaceID = faceID
        selectionAnchorID = faceID
    }

    /// Set by the face bar when in expanded mode to scroll to a group.
    var scrollToGroupID: UUID?

    func selectFace(_ faceID: UUID) {
        selectedFaceIDs.removeAll()
        selectedFaceIDs.insert(faceID)
        focusedFaceID = faceID
        selectionAnchorID = faceID
    }

    func extendSelection(to faceID: UUID, allFaces: [UUID]) {
        guard let anchorID = selectionAnchorID,
              let anchorIndex = allFaces.firstIndex(of: anchorID),
              let targetIndex = allFaces.firstIndex(of: faceID) else {
            selectFace(faceID)
            return
        }

        let range = min(anchorIndex, targetIndex)...max(anchorIndex, targetIndex)
        selectedFaceIDs = Set(allFaces[range])
        focusedFaceID = faceID
    }
}

// MARK: - Main View

struct ExpandedFaceManagementView: View {
    @Bindable var viewModel: FaceRecognitionViewModel
    let settingsViewModel: SettingsViewModel
    @Bindable var selectionState: FaceSelectionState
    let folderURL: URL?
    let images: [ImageFile]
    /// Apply a colour label to a set of images (wired to the browser's metadata pipeline).
    var onLabelImages: ((Set<URL>, ColorLabel) -> Void)?
    var onClose: () -> Void
    var onPhotosDeleted: ((Set<URL>) -> Void)?
    var onOpenFullScreen: ((URL, UUID?) -> Void)?
    @State private var groupToDelete: FaceGroup?
    @State private var showDeleteGroupAlert = false
    @State private var showingNameListFilePicker = false
    @State private var nameFromTeamSheetGroup: NamedGroupTarget?
    @State private var nameListImportMessage: String?
    /// True while the review sidebar is being live-resized — freezes the grid layout so cards don't
    /// stutter between column counts during the drag.
    @State private var sidebarResizing = false

    var body: some View {
        HStack(spacing: 0) {
            // Main face management area
            VStack(spacing: 0) {
                toolbar
                if let nameListImportMessage {
                    HStack {
                        Text(nameListImportMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
                Divider()
                if viewModel.activeLens.isPeopleLens {
                    // Lens assists augment the shared people grouping below.
                    if viewModel.activeLens == .redCarpet {
                        RedCarpetAssistStrip(viewModel: viewModel)
                        Divider()
                    } else if viewModel.activeLens == .sports {
                        SportsAssistStrip(viewModel: viewModel, folderURL: folderURL, onOpenFullScreen: onOpenFullScreen)
                        Divider()
                    }
                    // Live sharpness filter — hides too-blurry faces from the set without re-scanning.
                    HStack(spacing: 8) {
                        Image(systemName: "camera.filters")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Sharpness filter")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Slider(value: $viewModel.displayQualityThreshold,
                               in: 0...FaceRecognitionDefaults.minFaceQualityMax, step: 0.01)
                            .controlSize(.small)
                            .frame(maxWidth: 240)
                        Text(viewModel.displayQualityThreshold <= 0
                             ? "Off"
                             : String(format: "%.2f", viewModel.displayQualityThreshold))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 30, alignment: .trailing)
                        Spacer()
                        Text("Hides blurry faces • drag to taste")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    Divider()
                    FaceGroupCollectionRepresentable(
                        viewModel: viewModel,
                        selectionState: selectionState,
                        settingsViewModel: settingsViewModel,
                        callbacks: FaceGroupCardCallbacks(
                            onDeleteGroup: { group in
                                groupToDelete = group
                                showDeleteGroupAlert = true
                            },
                            onChooseListFile: { showingNameListFilePicker = true },
                            onToggleExpand: nil, // Handled internally by controller
                            onOpenFullScreen: onOpenFullScreen,
                            onPhotosDeleted: onPhotosDeleted,
                            onNameFromTeamSheet: { groupID in
                                nameFromTeamSheetGroup = NamedGroupTarget(id: groupID)
                            }
                        ),
                        isResizing: sidebarResizing
                    )
                } else {
                    // Expression: appearance-based collections, separate from the people
                    // grouping. Select faces and label the underlying photos.
                    ExpressionLensView(
                        viewModel: viewModel,
                        onOpenFullScreen: onOpenFullScreen,
                        onLabelImages: onLabelImages
                    )
                }
            }
            // Review queue lives in a dedicated right-side bar in the Sports lens, so the triage
            // list is vertical, roomier, and keyboard-drivable. Confirmed players stay in the strip.
            if viewModel.activeLens == .sports {
                SportsReviewSidebar(viewModel: viewModel,
                                    onOpenFullScreen: onOpenFullScreen,
                                    onResizingChanged: { sidebarResizing = $0 })
            }
        }
        .onChange(of: selectionState.focusedFaceID) { _, newValue in
            updateThumbnailReplacementSelection(for: newValue)
        }
        .sheet(item: $nameFromTeamSheetGroup) { target in
            NameFromTeamSheetView(viewModel: viewModel, groupID: target.id)
        }
        .alert(
            "Delete Group & Photos",
            isPresented: $showDeleteGroupAlert,
            presenting: groupToDelete
        ) { group in
            Button("Delete Faces Only") {
                let faceIDs = Set(group.faceIDs)
                viewModel.deleteFaces(faceIDs)
                groupToDelete = nil
            }
            Button("Move Photos to Trash", role: .destructive) {
                let trashed = viewModel.deleteGroup(group.id, includePhotos: true)
                onPhotosDeleted?(trashed)
                groupToDelete = nil
            }
            Button("Cancel", role: .cancel) {
                groupToDelete = nil
            }
        } message: { group in
            let photoCount = Set(group.faceIDs.compactMap { faceID in
                viewModel.face(byID: faceID)?.imageURL
            }).count
            Text("This will delete \(group.faceIDs.count) face(s) across \(photoCount) photo(s). Moving photos to Trash cannot be undone from this app.")
        }
        .fileImporter(
            isPresented: $showingNameListFilePicker,
            allowedContentTypes: [.plainText],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                do {
                    try settingsViewModel.setPersonShownListURL(url)
                    nameListImportMessage = nil
                } catch {
                    let description = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    nameListImportMessage = "Name list import failed: \(description)"
                }
            }
        }
    }

    private func updateThumbnailReplacementSelection(for faceID: UUID?) {
        guard let faceID,
              let groupID = viewModel.face(byID: faceID)?.groupID else {
            viewModel.selectGroupForThumbnailReplacement(nil)
            return
        }
        viewModel.selectGroupForThumbnailReplacement(groupID, faceID: faceID)
    }

    // MARK: - Toolbar

    @ViewBuilder
    private var toolbar: some View {
        HStack {
            // Lens switcher. Face/Red Carpet/Sports share the editable people grouping with
            // different assists; Expression is its own appearance grouping. Hidden when only one
            // lens is available (e.g. the 2.0 Face-only build), so no lone segment shows.
            if viewModel.availableLenses.count > 1 {
                Picker("Lens", selection: $viewModel.activeLens) {
                    ForEach(viewModel.availableLenses, id: \.self) { lens in
                        Text(lens.displayName).tag(lens)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                Divider()
                    .frame(height: 16)
            }

            if viewModel.activeLens.isPeopleLens {
                Button {
                    viewModel.createNewGroup(withFaces: selectionState.selectedFaceIDs)
                    selectionState.selectedFaceIDs.removeAll()
                } label: {
                    Label("New Group", systemImage: "plus")
                }
                .disabled(selectionState.selectedFaceIDs.isEmpty)

                Divider()
                    .frame(height: 16)

                Menu {
                    ForEach(FaceGroupSortMode.allCases, id: \.self) { mode in
                        Button {
                            viewModel.sortMode = mode
                        } label: {
                            HStack {
                                Text(mode.rawValue)
                                if viewModel.sortMode == mode {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Divider()
                    .frame(height: 16)
            }

            if let faceData = viewModel.faceData {
                let groupCount = faceData.groups(for: viewModel.activeLens).count
                Text("\(faceData.faces.count) faces in \(groupCount) groups")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            SelectionInfoView(selectionState: selectionState, viewModel: viewModel)

            Menu {
                Button("Rescan Folder (Force Full)") {
                    guard let folderURL else { return }
                    viewModel.scanFolder(imageURLs: images.map(\.url), folderURL: folderURL, forceFullScan: true)
                }
                Button("Delete Face Data", role: .destructive) {
                    guard let folderURL else { return }
                    viewModel.deleteFaceData(for: folderURL)
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(folderURL == nil)

            Button {
                onClose()
            } label: {
                Label("Close", systemImage: "xmark")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

// MARK: - Red Carpet Assist Strip

/// Clothing-assisted merge suggestions over the shared people grouping: pairs whose combined
/// face+clothing distance clears the Red Carpet threshold, surfaced for one-click merging.
struct RedCarpetAssistStrip: View {
    @Bindable var viewModel: FaceRecognitionViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(FaceLens.redCarpet.caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            if viewModel.lensState(for: .redCarpet).status != .complete {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Preparing clothing data in the background…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if viewModel.mergeSuggestions.isEmpty {
                Text("No clothing-based merge suggestions for this folder.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(viewModel.mergeSuggestions) { suggestion in
                            SuggestionRow(suggestion: suggestion, viewModel: viewModel)
                                .frame(width: 300)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// MARK: - Sports Assist Strip

/// Jersey-number assist over the shared people grouping: set up the match teams, resolve
/// numbers into player names, re-run the number merge, and surface unmatched (back-turned)
/// number detections that have no face to attach to.
struct SportsAssistStrip: View {
    @Bindable var viewModel: FaceRecognitionViewModel
    let folderURL: URL?
    var onOpenFullScreen: ((URL, UUID?) -> Void)?

    @State private var showMatchSetup = false

    /// Header label for the configured match/event: the startlist, "Home vs Away", or — when only
    /// one team is set up — just that team's name.
    private func matchLabel(_ roster: MatchRoster) -> String {
        if roster.effectiveMode == .event { return roster.eventStartlist?.name ?? "Startlist" }
        switch (roster.homeTeamSnapshot?.name, roster.awayTeamSnapshot?.name) {
        case let (home?, away?): return "\(home) vs \(away)"
        case let (home?, nil): return home
        case let (nil, away?): return away
        case (nil, nil): return "—"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(FaceLens.sports.caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                let mergeCount = viewModel.jerseyMergeCandidateCount
                if mergeCount > 0 {
                    Button("Merge \(mergeCount) split group\(mergeCount == 1 ? "" : "s")") {
                        viewModel.lastJerseyMergeCount = viewModel.applyJerseyNumberMerges()
                    }
                    .controlSize(.small)
                    .help("The same player was split into separate face groups that share one jersey number and kit colour — merge them into one group.")
                }
            }

            // Match setup → number-to-player-name resolution.
            HStack(spacing: 8) {
                if let roster = viewModel.matchRoster, roster.isReady {
                    Text(matchLabel(roster))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Button("Resolve Names") {
                        viewModel.runSportsResolution()
                        if viewModel.pendingColorClusterConfirmation != nil {
                            showMatchSetup = true
                        }
                    }
                    .controlSize(.small)
                    .help("Resolve numbers into player names; nothing is written until you confirm each claim")
                    if viewModel.pendingColorClusterConfirmation != nil {
                        Button("Confirm Colours…") { showMatchSetup = true }
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    Text("Pick the two teams to resolve numbers into player names.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Button("Match Setup…") { showMatchSetup = true }
                    .controlSize(.small)
                Spacer()
            }

            // Confirmed players — the names that Apply will write.
            let cards = viewModel.confirmedPlayerCards
            if !cards.isEmpty {
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal")
                        .font(.caption2)
                        .foregroundStyle(.green)
                    Text("Confirmed players")
                        .font(.caption.weight(.medium))
                    Text("· written on Apply")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(cards) { card in
                            SportsPlayerCardView(card: card, viewModel: viewModel, onOpenFullScreen: onOpenFullScreen)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .onAppear {
            if let folderURL, viewModel.matchRoster == nil {
                viewModel.loadMatchRoster(for: folderURL)
            }
        }
        .sheet(isPresented: $showMatchSetup) {
            MatchSetupView(viewModel: viewModel, folderURL: folderURL)
        }
    }
}

// MARK: - Sports player card

/// One confirmed player: face thumbnail (when a face is linked) badged with the jersey number in
/// the team colour. Right-click to remove the player (rejects their number claims).
private struct SportsPlayerCardView: View {
    let card: FaceRecognitionViewModel.SportsPlayerCard
    @Bindable var viewModel: FaceRecognitionViewModel
    var onOpenFullScreen: ((URL, UUID?) -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let faceID = card.representativeFaceID, let image = viewModel.thumbnailImage(for: faceID) {
                        Image(nsImage: image).resizable().scaledToFill()
                    } else {
                        Image(systemName: "person.fill")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(.quaternary.opacity(0.5))
                    }
                }
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(card.name)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Text("\(card.imageCount) photo\(card.imageCount == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .contextMenu {
            Button(role: .destructive) {
                for id in card.detectionIDs { viewModel.rejectNumberClaim(id) }
            } label: {
                Label("Remove player (reject numbers)", systemImage: "person.fill.xmark")
            }
        }
        .help("Confirmed from jersey number — right-click to remove")
    }
}

// MARK: - Sports review sidebar

/// The review queue as a dedicated right-side bar: a vertical, keyboard-drivable triage list.
/// The active card is highlighted and shows its key hints inline — ↑↓ (or J/K) move, ⏎/Y confirm,
/// ⌫/N reject, H/A pick a side for ambiguous numbers, O/Space open the photo. Each decision
/// auto-advances to the next card. Confirmed players stay in the bottom strip; this bar only holds
/// what still needs a decision, plus numbers with no roster match ("not on a team sheet").
private struct SportsReviewSidebar: View {
    @Bindable var viewModel: FaceRecognitionViewModel
    var onOpenFullScreen: ((URL, UUID?) -> Void)?
    /// Reports whether the user is mid-drag on the resize handle, so the parent can freeze the grid.
    var onResizingChanged: (Bool) -> Void = { _ in }

    @AppStorage("sportsReviewSidebarWidth") private var width: Double = 340
    @State private var dragStartWidth: Double?
    @State private var focusedID: UUID?
    @FocusState private var keyboardFocused: Bool

    private let minWidth: Double = 280
    private let maxWidth: Double = 540

    /// Standalone detections with no roster match (numbers not on either team sheet), grouped by
    /// number. Resolved-but-unconfirmed claims live in the review list above instead.
    private var unmatchedByNumber: [(number: Int, detections: [NumberDetection])] {
        let unresolved = viewModel.standaloneNumberDetections.filter { $0.resolvedPlayerName == nil }
        return Dictionary(grouping: unresolved, by: \.number)
            .map { (number: $0.key, detections: $0.value) }
            .sorted { ($0.detections.count, $1.number) > ($1.detections.count, $0.number) }
    }

    var body: some View {
        let review = viewModel.sportsReviewItems
        let unmatched = unmatchedByNumber
        if !review.isEmpty || !unmatched.isEmpty {
            HStack(spacing: 0) {
                resizeHandle
                content(review: review, unmatched: unmatched)
                    .frame(width: width)
            }
            .onChange(of: review.map(\.id)) { _, ids in
                if focusedID == nil || !ids.contains(focusedID!) {
                    focusedID = ids.first
                }
            }
            .onAppear {
                if focusedID == nil { focusedID = review.first?.id }
                keyboardFocused = true
            }
        }
    }

    @ViewBuilder
    private func content(review: [FaceRecognitionViewModel.SportsReviewItem],
                         unmatched: [(number: Int, detections: [NumberDetection])]) -> some View {
        VStack(spacing: 0) {
            header(reviewCount: review.count)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(review) { item in
                            SportsReviewSidebarRow(
                                item: item,
                                isActive: item.id == focusedID,
                                viewModel: viewModel,
                                onOpenFullScreen: onOpenFullScreen,
                                onActivate: { focusedID = item.id; keyboardFocused = true },
                                onConfirm: { confirm(item) },
                                onReject: { reject(item) },
                                onAssign: { side in assign(side, to: item) }
                            )
                            .id(item.id)
                        }

                        if !unmatched.isEmpty {
                            HStack(spacing: 6) {
                                Image(systemName: "nosign").font(.caption2).foregroundStyle(.secondary)
                                Text("Not on a team sheet").font(.caption.weight(.medium))
                                Spacer()
                            }
                            .padding(.top, 4)
                            ForEach(unmatched, id: \.number) { entry in
                                SportsUnmatchedCard(number: entry.number, detections: entry.detections,
                                                    viewModel: viewModel, onOpenFullScreen: onOpenFullScreen)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(8)
                }
                .onChange(of: focusedID) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
            if !review.isEmpty { legend }
        }
        .background(.background)
        .focusable()
        .focusEffectDisabled()
        .focused($keyboardFocused)
        .onKeyPress { handleKey($0, items: viewModel.sportsReviewItems) }
    }

    private func header(reviewCount: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "tray.full").font(.caption2).foregroundStyle(.secondary)
            Text("Review queue").font(.caption.weight(.semibold))
            Text("nothing written until confirmed")
                .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            Spacer()
            if reviewCount > 0 {
                Text("\(reviewCount)")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(.tint, in: Capsule())
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(.bar)
    }

    private var legend: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                legendItem("↑↓", "move")
                legendItem("⏎", "confirm")
                legendItem("N", "reject")
                legendItem("H/A", "side")
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
        }
    }

    private func legendItem(_ key: String, _ label: String) -> some View {
        HStack(spacing: 3) {
            KeyCap(key)
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private var resizeHandle: some View {
        // A visible separator down the left edge that also serves as the drag target. The hit area
        // is wider than the 1px line so it's easy to grab; the line brightens while dragging.
        let dragging = dragStartWidth != nil
        return Rectangle()
            .fill(dragging ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color(nsColor: .separatorColor)))
            .frame(width: dragging ? 2 : 1)
            .frame(maxWidth: 10, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if dragStartWidth == nil {
                            dragStartWidth = width
                            onResizingChanged(true)
                        }
                        let start = dragStartWidth ?? width
                        width = min(maxWidth, max(minWidth, start - Double(value.translation.width)))
                    }
                    .onEnded { _ in
                        dragStartWidth = nil
                        onResizingChanged(false)
                    }
            )
    }

    // MARK: Actions (each advances focus to the next still-pending card)

    private func nextFocus(after item: FaceRecognitionViewModel.SportsReviewItem,
                           in items: [FaceRecognitionViewModel.SportsReviewItem]) -> UUID? {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return items.first?.id }
        if idx + 1 < items.count { return items[idx + 1].id }
        if idx - 1 >= 0 { return items[idx - 1].id }
        return nil
    }

    private func confirm(_ item: FaceRecognitionViewModel.SportsReviewItem) {
        let next = nextFocus(after: item, in: viewModel.sportsReviewItems)
        viewModel.confirmNumberClaim(item.detection.id)
        focusedID = next
    }

    private func reject(_ item: FaceRecognitionViewModel.SportsReviewItem) {
        let next = nextFocus(after: item, in: viewModel.sportsReviewItems)
        viewModel.rejectNumberClaim(item.detection.id)
        focusedID = next
    }

    private func assign(_ side: TeamSide, to item: FaceRecognitionViewModel.SportsReviewItem) {
        let next = nextFocus(after: item, in: viewModel.sportsReviewItems)
        viewModel.assignSide(side, toNumberDetection: item.detection.id)
        focusedID = next
    }

    private func handleKey(_ press: KeyPress,
                           items: [FaceRecognitionViewModel.SportsReviewItem]) -> KeyPress.Result {
        guard !items.isEmpty else { return .ignored }
        let idx = items.firstIndex { $0.id == focusedID } ?? 0
        let current = items[idx]

        switch press.key {
        case .upArrow:
            focusedID = items[max(0, idx - 1)].id; return .handled
        case .downArrow:
            focusedID = items[min(items.count - 1, idx + 1)].id; return .handled
        case .return:
            if current.reason != .ambiguousSide { confirm(current) }
            return .handled
        case .delete, .deleteForward:
            reject(current); return .handled
        case .space:
            onOpenFullScreen?(current.detection.imageURL, nil); return .handled
        default:
            break
        }

        switch press.characters.lowercased() {
        case "k": focusedID = items[max(0, idx - 1)].id; return .handled
        case "j": focusedID = items[min(items.count - 1, idx + 1)].id; return .handled
        case "y": if current.reason != .ambiguousSide { confirm(current) }; return .handled
        case "n": reject(current); return .handled
        case "h": if current.reason == .ambiguousSide { assign(.home, to: current) }; return .handled
        case "a": if current.reason == .ambiguousSide { assign(.away, to: current) }; return .handled
        case "o": onOpenFullScreen?(current.detection.imageURL, nil); return .handled
        default: return .ignored
        }
    }
}

// MARK: - Key cap

/// A tiny keyboard-key glyph, shown next to an action on the active review card so the shortcut
/// is discoverable in place rather than hidden in a help string.
private struct KeyCap: View {
    let label: String
    init(_ label: String) { self.label = label }

    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.secondary.opacity(0.4), lineWidth: 0.5))
    }
}

// MARK: - Sports review sidebar row

/// One claim awaiting confirmation in the side bar: the number crop, the player it would name, and
/// why it isn't auto-confirmed. The active row is accent-highlighted and shows its key hints next
/// to each action. Confirm writes the name on Apply; reject removes it; drag binds it to a person.
private struct SportsReviewSidebarRow: View {
    let item: FaceRecognitionViewModel.SportsReviewItem
    let isActive: Bool
    @Bindable var viewModel: FaceRecognitionViewModel
    var onOpenFullScreen: ((URL, UUID?) -> Void)?
    var onActivate: () -> Void
    var onConfirm: () -> Void
    var onReject: () -> Void
    var onAssign: (TeamSide) -> Void
    @State private var hovering = false

    private var reasonText: String {
        switch item.reason {
        case .numberOnly: "number only — no face. Could be a supporter."
        case .unconfirmedFace: "face not yet identified — verify the number."
        case .ambiguousSide: "on both teams — pick a side."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Button {
                    onOpenFullScreen?(item.detection.imageURL, nil)
                } label: {
                    NumberCropThumbnail(detection: item.detection, size: 48)
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .popover(isPresented: $hovering, arrowEdge: .leading) {
                    NumberContextPreview(detection: item.detection).padding(8)
                }
                .help("Detected number in context — hover to preview, click to open the photo")

                VStack(alignment: .leading, spacing: 2) {
                    Text("#\(item.detection.number) → \(item.detection.resolvedPlayerName ?? "?")")
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(reasonText)
                        .font(.caption2)
                        .foregroundStyle(item.reason == .numberOnly ? .orange : .secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 6) {
                if item.reason == .ambiguousSide {
                    actionButton(title: "Home", systemImage: nil, key: "H", prominent: false) { onAssign(.home) }
                    actionButton(title: "Away", systemImage: nil, key: "A", prominent: false) { onAssign(.away) }
                } else {
                    actionButton(title: "Confirm", systemImage: "checkmark", key: "⏎", prominent: true, action: onConfirm)
                    actionButton(title: nil, systemImage: "xmark", key: "N", prominent: false, action: onReject)
                }
                Spacer(minLength: 0)
                NumberCorrectionButton(current: item.detection.number) { newNumber in
                    viewModel.correctNumber(item.detection.id, to: newNumber)
                }
            }
        }
        .padding(8)
        .background(
            isActive ? AnyShapeStyle(Color.accentColor.opacity(0.15)) : AnyShapeStyle(.quaternary.opacity(0.4)),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay {
            if isActive {
                RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 1.5)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onActivate() }
        .onDrag { NSItemProvider(object: NSString(string: "number:\(item.detection.id.uuidString)")) }
        .help("Click to make active, then use the keyboard — or drag onto a person to assign this number")
    }

    @ViewBuilder
    private func actionButton(title: String?, systemImage: String?, key: String,
                              prominent: Bool, action: @escaping () -> Void) -> some View {
        let button = Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage { Image(systemName: systemImage) }
                if let title { Text(title).font(.caption) }
                if isActive { KeyCap(key) }
            }
        }
        .controlSize(.small)

        if prominent {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }
}

// MARK: - Name from team sheet

/// Identifiable wrapper so a group id can drive a `.sheet(item:)`.
private struct NamedGroupTarget: Identifiable { let id: UUID }

/// Sports lens: name a face group from the roster by entering a jersey number + team. For the
/// case where the photographer can read the number on the shirt but can't place the name, or OCR
/// missed a stylised number. Shows the suggested player and confirms before naming.
private struct NameFromTeamSheetView: View {
    @Bindable var viewModel: FaceRecognitionViewModel
    let groupID: UUID
    @Environment(\.dismiss) private var dismiss

    @State private var numberText = ""
    @State private var side: TeamSide = .home

    private var isEvent: Bool { viewModel.matchRoster?.effectiveMode == .event }
    private var number: Int? {
        guard let n = Int(numberText.trimmingCharacters(in: .whitespaces)), (0...99).contains(n) else { return nil }
        return n
    }
    private var resolvedSide: TeamSide? { isEvent ? nil : side }
    private var suggested: String? { number.flatMap { viewModel.rosterName(forNumber: $0, side: resolvedSide) } }

    private var homeName: String { viewModel.matchRoster?.homeTeamSnapshot?.name ?? "Home" }
    private var awayName: String { viewModel.matchRoster?.awayTeamSnapshot?.name ?? "Away" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("Number") {
                    TextField("Jersey number", text: $numberText)
                        .frame(width: 120)
                    if !isEvent {
                        Picker("Team", selection: $side) {
                            Text(homeName).tag(TeamSide.home)
                            Text(awayName).tag(TeamSide.away)
                        }
                        .pickerStyle(.segmented)
                    }
                }

                Section("Player") {
                    if let suggested {
                        Label(suggested, systemImage: "person.fill")
                            .font(.body.weight(.medium))
                    } else if number != nil {
                        Label(isEvent ? "No athlete with that bib on the startlist"
                                      : "No player with #\(number!) on \(side == .home ? homeName : awayName)",
                              systemImage: "questionmark.circle")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Enter a number to look up the player.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Assign Name") {
                    if let number { viewModel.nameGroup(groupID, fromNumber: number, side: resolvedSide) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(suggested == nil)
            }
            .padding()
        }
        .frame(width: 380, height: 300)
    }
}

// MARK: - Number context preview

/// The whole (downsampled) image with a box drawn around the detected number, so the number can
/// be judged in context — which player, where on the pitch — not just as an isolated crop.
private struct NumberContextPreview: View {
    let detection: NumberDetection
    var maxWidth: CGFloat = 460
    var maxHeight: CGFloat = 380
    @State private var image: NSImage?
    @State private var pixelSize: CGSize = .zero

    private var fitted: CGSize {
        guard pixelSize.width > 0, pixelSize.height > 0 else { return CGSize(width: maxWidth, height: maxWidth * 0.66) }
        let aspect = pixelSize.width / pixelSize.height
        var w = maxWidth, h = maxWidth / aspect
        if h > maxHeight { h = maxHeight; w = maxHeight * aspect }
        return CGSize(width: w, height: h)
    }

    var body: some View {
        Group {
            if let image {
                let size = fitted
                let box = detection.boundingBox
                Image(nsImage: image)
                    .resizable()
                    .frame(width: size.width, height: size.height)
                    .overlay {
                        // Vision box is normalised, origin bottom-left → flip y for SwiftUI.
                        // Double stroke (dark under, yellow over) so the box reads on any background.
                        ZStack {
                            Rectangle().strokeBorder(Color.black.opacity(0.7), lineWidth: 4)
                            Rectangle().strokeBorder(Color.yellow, lineWidth: 2)
                        }
                        .frame(width: max(8, box.width * size.width),
                               height: max(8, box.height * size.height))
                        .position(x: box.midX * size.width,
                                  y: (1 - box.midY) * size.height)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                ProgressView()
                    .frame(width: maxWidth, height: maxWidth * 0.66)
            }
        }
        .task(id: detection.id) {
            if let cg = await NumberCropCache.shared.preview(imageURL: detection.imageURL) {
                pixelSize = CGSize(width: cg.width, height: cg.height)
                image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
        }
    }
}

// MARK: - Number correction

/// Pencil button → popover to fix a misread number (OCR read "1" but the shirt shows "21").
/// Commits 0–99; the caller re-resolves the corrected number against the roster.
private struct NumberCorrectionButton: View {
    let current: Int
    let onSet: (Int) -> Void
    @State private var editing = false
    @State private var text = ""

    private var parsed: Int? {
        guard let n = Int(text.trimmingCharacters(in: .whitespaces)), (0...99).contains(n) else { return nil }
        return n
    }

    private func commit() {
        if let n = parsed { onSet(n) }
        editing = false
    }

    var body: some View {
        Button {
            text = "\(current)"
            editing = true
        } label: {
            Image(systemName: "pencil")
        }
        .controlSize(.small)
        .help("Correct the number")
        .popover(isPresented: $editing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Correct number").font(.caption.weight(.medium))
                HStack(spacing: 6) {
                    TextField("0–99", text: $text)
                        .frame(width: 56)
                        .onSubmit(commit)
                    Button("Set", action: commit)
                        .keyboardShortcut(.defaultAction)
                        .disabled(parsed == nil)
                }
            }
            .padding(12)
        }
    }
}

// MARK: - Unmatched number card

/// A detected number with no roster match, shown as a card alongside the review queue (after the
/// divider). Hover previews it in context; the pencil corrects a misread; drag binds it to a
/// person; click opens the photo.
private struct SportsUnmatchedCard: View {
    let number: Int
    let detections: [NumberDetection]
    @Bindable var viewModel: FaceRecognitionViewModel
    var onOpenFullScreen: ((URL, UUID?) -> Void)?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            if let first = detections.first {
                Button { onOpenFullScreen?(first.imageURL, nil) } label: {
                    NumberCropThumbnail(detection: first, size: 40)
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .popover(isPresented: $hovering, arrowEdge: .top) {
                    NumberContextPreview(detection: first).padding(8)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(detections.count > 1 ? "#\(number) ×\(detections.count)" : "#\(number)")
                    .font(.caption.weight(.medium))
                Text("not on a team sheet")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 120, alignment: .leading)
            Spacer(minLength: 0)
            NumberCorrectionButton(current: number) { newNumber in
                for det in detections { viewModel.correctNumber(det.id, to: newNumber) }
            }
            Button {
                for det in detections { viewModel.rejectNumberClaim(det.id) }
            } label: {
                Image(systemName: "xmark")
            }
            .controlSize(.small)
            .help("Not a real number — dismiss this detection (won't reappear)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .onDrag { NSItemProvider(object: NSString(string: "number:\(detections.first?.id.uuidString ?? "")")) }
        .help("No roster match — correct the number, dismiss it, or drag onto a person")
    }
}

// MARK: - Number crop thumbnail

/// A small crop of the detected number from the source image, so the read can be eyeballed
/// ("6" vs "8") rather than trusted. Falls back to the parsed digit while loading or if the
/// image can't be decoded.
private struct NumberCropThumbnail: View {
    let detection: NumberDetection
    var size: CGFloat = 40
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Text("#\(detection.number)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary.opacity(0.6))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: detection.id) {
            if let cg = await NumberCropCache.shared.crop(imageURL: detection.imageURL, box: detection.boundingBox) {
                image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
        }
    }
}

// MARK: - Expression Lens View

/// Appearance-based collections, separate from the people grouping: faces grouped by look
/// and expression. Click to select (⌘-click for multi), double-click to open the photo, and
/// apply a colour label to the selected faces' photos.
struct ExpressionLensView: View {
    @Bindable var viewModel: FaceRecognitionViewModel
    var onOpenFullScreen: ((URL, UUID?) -> Void)?
    var onLabelImages: ((Set<URL>, ColorLabel) -> Void)?

    @State private var selectedFaceIDs: Set<UUID> = []

    var body: some View {
        let state = viewModel.lensState(for: .expression)

        VStack(spacing: 0) {
            HStack {
                Text(FaceLens.expression.caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if selectedFaceIDs.isEmpty {
                    Text("Click to select • ⌘-click for multiple • double-click to open")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    selectionActions
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()

            switch state.status {
            case .complete where !state.groups.isEmpty:
                groupsGrid(state.groups)
            case .complete:
                placeholder(
                    systemImage: "person.2.slash",
                    title: "No expression groups",
                    detail: "No faces in this folder could be grouped by appearance."
                )
            case .embedding, .clustering:
                placeholder(
                    systemImage: "sparkles",
                    title: "Preparing expression groups…",
                    detail: "Computing in the background from the existing scan — no rescan needed.",
                    showsProgress: true
                )
            case .notStarted:
                placeholder(
                    systemImage: "camera.viewfinder",
                    title: "Not computed yet",
                    detail: viewModel.scanComplete
                        ? "Expression groups are computed automatically after a scan."
                        : "Scan the folder for faces first."
                )
            }
        }
    }

    private var selectedImageURLs: Set<URL> {
        Set(selectedFaceIDs.compactMap { viewModel.face(byID: $0)?.imageURL })
    }

    @ViewBuilder
    private var selectionActions: some View {
        HStack(spacing: 8) {
            Text("\(selectedFaceIDs.count) selected")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Colour-label the selected faces' photos.
            HStack(spacing: 4) {
                ForEach(ColorLabel.allCases.filter { $0 != .none && $0 != .trash }, id: \.self) { label in
                    Button {
                        onLabelImages?(selectedImageURLs, label)
                    } label: {
                        Circle()
                            .fill(label.color ?? .gray)
                            .frame(width: 14, height: 14)
                    }
                    .buttonStyle(.plain)
                    .help("Label \(selectedImageURLs.count) photo\(selectedImageURLs.count == 1 ? "" : "s") \(label.displayName)")
                }
                Button {
                    onLabelImages?(selectedImageURLs, .none)
                } label: {
                    Circle()
                        .strokeBorder(.secondary, lineWidth: 1)
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
                .help("Remove label")
            }

            Button("Clear") {
                selectedFaceIDs.removeAll()
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private func groupsGrid(_ groups: [FaceGroup]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("\(group.faceIDs.count) face\(group.faceIDs.count == 1 ? "" : "s")")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                            Button("Select All") {
                                selectedFaceIDs.formUnion(group.faceIDs)
                            }
                            .controlSize(.mini)
                            .buttonStyle(.borderless)
                        }

                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 4)], alignment: .leading, spacing: 4) {
                            ForEach(group.faceIDs, id: \.self) { faceID in
                                faceThumbnail(faceID)
                            }
                        }

                        Divider()
                    }
                }
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private func faceThumbnail(_ faceID: UUID) -> some View {
        let isSelected = selectedFaceIDs.contains(faceID)
        Button {
            if NSEvent.modifierFlags.contains(.command) {
                if isSelected {
                    selectedFaceIDs.remove(faceID)
                } else {
                    selectedFaceIDs.insert(faceID)
                }
            } else {
                selectedFaceIDs = [faceID]
            }
        } label: {
            Group {
                if let image = viewModel.thumbnailImage(for: faceID) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle()
                        .fill(.quaternary)
                        .overlay {
                            Image(systemName: "person.fill")
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Face thumbnail")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityHint("Select this face; hold Command to change a multi-selection")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .onTapGesture(count: 2) {
            if let face = viewModel.face(byID: faceID) {
                onOpenFullScreen?(face.imageURL, faceID)
            }
        }
        .accessibilityAction(named: "Open Full Screen") {
            if let face = viewModel.face(byID: faceID) {
                onOpenFullScreen?(face.imageURL, faceID)
            }
        }
    }

    @ViewBuilder
    private func placeholder(systemImage: String, title: String, detail: String, showsProgress: Bool = false) -> some View {
        VStack(spacing: 10) {
            Spacer()
            if showsProgress {
                ProgressView()
                    .controlSize(.regular)
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
            }
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }
}

// MARK: - Selection Info View (isolated to prevent toolbar re-renders)

struct SelectionInfoView: View {
    @Bindable var selectionState: FaceSelectionState
    let viewModel: FaceRecognitionViewModel

    var body: some View {
        if !selectionState.selectedFaceIDs.isEmpty {
            Button(role: .destructive) {
                viewModel.deleteFaces(selectionState.selectedFaceIDs)
                selectionState.selectedFaceIDs.removeAll()
            } label: {
                Label("Delete \(selectionState.selectedFaceIDs.count)", systemImage: "trash")
            }

            Text("\(selectionState.selectedFaceIDs.count) face\(selectionState.selectedFaceIDs.count == 1 ? "" : "s") selected")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
        }
    }
}

// MARK: - Face Suggestions Panel

struct FaceSuggestionsPanel: View {
    @Bindable var viewModel: FaceRecognitionViewModel
    var onClose: () -> Void

    @State private var isRefining = false
    @State private var isCheckingKnown = false
    @State private var lastRefinementCount = 0

    /// The single selected group for thumbnail replacement (if any)
    private var replaceThumbnailCandidate: (groupID: UUID, personID: UUID)? {
        guard let groupID = viewModel.selectedThumbnailReplacementGroupID,
              let match = viewModel.knownPersonMatchByGroup[groupID],
              viewModel.groupNameMatchesKnownPerson(groupID),
              KnownPeopleService.shared.person(byID: match.personID) != nil else {
            return nil
        }
        return (groupID: groupID, personID: match.personID)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Suggestions")
                    .font(.headline)
                Spacer()
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(.bar)

            Divider()

            ScrollView {
                VStack(spacing: 12) {
                    // Action buttons
                    VStack(spacing: 12) {
                        // Refine button
                        if viewModel.canRefine {
                            Button {
                                isRefining = true
                                lastRefinementCount = viewModel.refineWithNamedGroups()
                                isRefining = false
                            } label: {
                                HStack {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Refine with Named Groups")
                                            .font(.subheadline)
                                        Text("Match unnamed groups against named ones")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if lastRefinementCount > 0 {
                                        Text("+\(lastRefinementCount)")
                                            .font(.caption)
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(.blue, in: Capsule())
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                            .disabled(isRefining)
                        }

                        // Known People button (matching is automatic; this re-runs it on demand).
                        Group {
                            Button {
                                checkKnownPeople()
                            } label: {
                                HStack {
                                    Image(systemName: "person.text.rectangle")
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Check Known People")
                                            .font(.subheadline)
                                        Text("Match against global database")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if isCheckingKnown {
                                        ProgressView()
                                            .controlSize(.small)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                            .disabled(isCheckingKnown)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top)

                    // Check results summary
                    if let result = viewModel.lastKnownPeopleCheckResult, result.totalChecked > 0 {
                        HStack(spacing: 8) {
                            if result.autoMatchCount > 0 {
                                Label("\(result.autoMatchCount) matched", systemImage: "checkmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            }
                            if result.suggestionCount > 0 {
                                Label("\(result.suggestionCount) suggestion\(result.suggestionCount == 1 ? "" : "s")", systemImage: "questionmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                            if result.autoMatchCount == 0 && result.suggestionCount == 0 {
                                Label("No matches found", systemImage: "minus.circle")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal)
                    }

                    // Replace Thumbnail card (single selection)
                    if let candidate = replaceThumbnailCandidate {
                        Divider()
                            .padding(.horizontal)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Update Known People")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal)

                            ReplaceThumbnailCard(
                                groupID: candidate.groupID,
                                personID: candidate.personID,
                                viewModel: viewModel
                            )
                            .padding(.horizontal)
                        }
                    }

                    // Known People suggestions
                    if !viewModel.knownPersonSuggestions.isEmpty {
                        Divider()
                            .padding(.horizontal)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Known People Suggestions")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal)

                            LazyVStack(spacing: 8) {
                                ForEach(viewModel.knownPersonSuggestions) { suggestion in
                                    KnownPersonSuggestionRow(suggestion: suggestion, viewModel: viewModel)
                                }
                            }
                            .padding(.horizontal)
                        }
                    }

                    Divider()
                        .padding(.horizontal)

                    // Merge suggestions list
                    if viewModel.mergeSuggestions.isEmpty && viewModel.knownPersonSuggestions.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "checkmark.circle")
                                .font(.system(size: 32))
                                .foregroundStyle(.secondary)
                            Text("No suggestions")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text("Name some groups and click Refine to find matches")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                    } else if !viewModel.mergeSuggestions.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Merge Suggestions")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal)

                            LazyVStack(spacing: 8) {
                                ForEach(viewModel.mergeSuggestions) { suggestion in
                                    SuggestionRow(suggestion: suggestion, viewModel: viewModel)
                                }
                            }
                            .padding(.horizontal)
                            .padding(.bottom)
                        }
                    }
                }
            }
        }
        .background(.background)
        .onAppear {
            if viewModel.lastKnownPeopleCheckResult == nil {
                checkKnownPeople()
            }
        }
    }

    private func checkKnownPeople() {
        guard viewModel.faceData != nil else { return }
        isCheckingKnown = true
        _ = viewModel.checkKnownPeopleWithSuggestions()
        isCheckingKnown = false
    }
}

// MARK: - Replace Thumbnail Card

struct ReplaceThumbnailCard: View {
    let groupID: UUID
    let personID: UUID
    @Bindable var viewModel: FaceRecognitionViewModel

    @State private var currentThumbnail: NSImage?
    @State private var newThumbnail: NSImage?
    @State private var isReplacing = false

    private var group: FaceGroup? {
        viewModel.group(byID: groupID)
    }

    private var person: KnownPerson? {
        KnownPeopleService.shared.person(byID: personID)
    }

    var body: some View {
        if group != nil, let person {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Replace thumbnail for \(person.name)")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Button {
                        viewModel.clearThumbnailReplacementSelection()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss")
                }

                HStack(spacing: 12) {
                    // Current thumbnail in database
                    VStack {
                        thumbnailView(currentThumbnail)
                        Text("Current")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)

                    // New thumbnail from this scan
                    VStack {
                        thumbnailView(newThumbnail)
                        Text("New")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        replaceThumbnail()
                    } label: {
                        if isReplacing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Replace")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isReplacing)
                }
            }
            .padding()
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .onAppear {
                loadThumbnails()
            }
            .onChange(of: viewModel.selectedThumbnailReplacementFaceID) { _, _ in
                loadThumbnails()
            }
            .onChange(of: groupID) { _, _ in
                loadThumbnails()
            }
            .onChange(of: personID) { _, _ in
                loadThumbnails()
            }
        }
    }

    @ViewBuilder
    private func thumbnailView(_ image: NSImage?) -> some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "person.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 60, height: 60)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary)
        )
    }

    private func loadThumbnails() {
        // Load current thumbnail from Known People database
        currentThumbnail = KnownPeopleService.shared.loadThumbnail(for: personID)

        // Load new thumbnail from current scan
        if let faceID = viewModel.selectedThumbnailReplacementFaceID ?? group?.representativeFaceID {
            newThumbnail = viewModel.thumbnailImage(for: faceID)
        } else {
            newThumbnail = nil
        }
    }

    private func replaceThumbnail() {
        guard let group else { return }

        let faceID = viewModel.selectedThumbnailReplacementFaceID ?? group.representativeFaceID
        guard let thumbImage = viewModel.thumbnailImage(for: faceID),
              let tiffData = thumbImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
            return
        }

        isReplacing = true

        do {
            try KnownPeopleService.shared.replaceThumbnail(for: personID, newThumbnailData: jpegData)
            // Clear selection after successful replacement
            viewModel.clearThumbnailReplacementSelection()
        } catch {
            // Handle error silently
        }

        isReplacing = false
    }
}

// MARK: - Suggestion Row

struct SuggestionRow: View {
    let suggestion: MergeSuggestion
    @Bindable var viewModel: FaceRecognitionViewModel

    private var group1: FaceGroup? {
        viewModel.group(byID: suggestion.group1ID)
    }

    private var group2: FaceGroup? {
        viewModel.group(byID: suggestion.group2ID)
    }

    var body: some View {
        HStack(spacing: 8) {
            // Group 1
            groupPreview(group1)

            // Similarity indicator
            VStack(spacing: 2) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("\(Int(suggestion.similarity * 100))%")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 36)

            // Group 2
            groupPreview(group2)

            Spacer()

            // Actions
            VStack(spacing: 4) {
                Button {
                    viewModel.applyMergeSuggestion(suggestion)
                } label: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                .buttonStyle(.plain)
                .help("Merge groups")

                Button {
                    viewModel.dismissMergeSuggestion(suggestion)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Dismiss suggestion")
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func groupPreview(_ group: FaceGroup?) -> some View {
        VStack(spacing: 4) {
            if let group,
               let image = viewModel.thumbnailImage(for: group.representativeFaceID) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary)
                    .frame(width: 48, height: 48)
            }

            Text(group?.name ?? "Unnamed")
                .font(.system(size: 10))
                .lineLimit(1)
                .frame(maxWidth: 60)
        }
    }
}

// MARK: - Known Person Suggestion Row

struct KnownPersonSuggestionRow: View {
    let suggestion: KnownPersonSuggestion
    @Bindable var viewModel: FaceRecognitionViewModel

    private var group: FaceGroup? {
        viewModel.group(byID: suggestion.groupID)
    }

    var body: some View {
        HStack(spacing: 8) {
            // Face group thumbnail
            groupPreview

            // Match indicator
            VStack(spacing: 2) {
                Image(systemName: "arrow.right")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("\(Int(suggestion.confidence * 100))%")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(suggestion.confidence >= 0.55 ? .orange : .secondary)
                if suggestion.sampledFaceCount > 1 {
                    Text("\(suggestion.matchedFaceCount)/\(suggestion.sampledFaceCount)")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 36)

            // Known person thumbnail + name
            knownPersonPreview

            Spacer()

            // Actions
            VStack(spacing: 4) {
                Button {
                    viewModel.acceptKnownPersonSuggestion(suggestion)
                } label: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                .buttonStyle(.plain)
                .help("Accept: name group as \(suggestion.personName)")

                Button {
                    viewModel.dismissKnownPersonSuggestion(suggestion)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Dismiss suggestion")
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var groupPreview: some View {
        VStack(spacing: 4) {
            if let group,
               let image = viewModel.thumbnailImage(for: group.representativeFaceID) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary)
                    .frame(width: 48, height: 48)
            }
            Text("Unnamed")
                .font(.system(size: 10))
                .lineLimit(1)
                .frame(maxWidth: 60)
        }
    }

    @ViewBuilder
    private var knownPersonPreview: some View {
        VStack(spacing: 4) {
            if let thumbnail = KnownPeopleService.shared.loadThumbnail(for: suggestion.personID) {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "person.fill")
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 48, height: 48)
            }
            Text(suggestion.personName)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .frame(maxWidth: 60)
        }
    }
}
