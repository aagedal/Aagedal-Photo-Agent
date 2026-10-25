import AppKit

/// A combined rescan replaces folder-local grouping decisions, so keep that choice explicit.
@MainActor
func confirmFaceAndJerseyScan(viewModel: FaceRecognitionViewModel, imageURLs: [URL], folderURL: URL) {
    guard !viewModel.isScanning, viewModel.faceModelAvailability.isAvailable else { return }
    let existing = viewModel.faceData.map {
        $0.folderURL.standardizedFileURL == folderURL.standardizedFileURL && !$0.faces.isEmpty
    } ?? false
    let verb = existing ? "Rescan" : "Scan"
    let alert = NSAlert()
    alert.messageText = "\(verb) Faces + Jerseys?"
    alert.informativeText = "This scans all photos in \(folderURL.lastPathComponent) for faces and jersey numbers. Jersey OCR takes longer."
        + (existing ? " Existing face groups, folder-local names and jersey results will be replaced." : "")
        + " Your Known People library and photo metadata are preserved."
    alert.alertStyle = existing ? .warning : .informational
    alert.addButton(withTitle: "Cancel")
    alert.addButton(withTitle: "\(verb) Faces + Jerseys")
    guard alert.runModal() == .alertSecondButtonReturn else { return }
    viewModel.scanFolder(imageURLs: imageURLs.filter { SupportedImageFormats.isSupported(url: $0) }, folderURL: folderURL, includeJerseyNumbers: true)
}
