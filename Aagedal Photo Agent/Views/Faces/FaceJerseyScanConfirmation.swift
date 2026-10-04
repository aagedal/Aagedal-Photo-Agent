import AppKit

/// A combined rescan replaces folder-local grouping decisions, so keep that choice explicit.
@MainActor
func confirmFaceAndJerseyScan(viewModel: FaceRecognitionViewModel, imageURLs: [URL], folderURL: URL) {
    guard !viewModel.isScanning, viewModel.faceModelAvailability.isAvailable else { return }
    let alert = NSAlert()
    alert.messageText = "Rescan Faces + Jerseys?"
    alert.informativeText = "This scans all photos in \(folderURL.lastPathComponent) for faces and jersey numbers. Jersey OCR takes longer. Existing face groups, folder-local names and jersey results will be replaced. Your Known People library and photo metadata are preserved."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Cancel")
    alert.addButton(withTitle: "Rescan Faces + Jerseys")
    guard alert.runModal() == .alertSecondButtonReturn else { return }
    viewModel.scanFolder(imageURLs: imageURLs, folderURL: folderURL, includeJerseyNumbers: true)
}
