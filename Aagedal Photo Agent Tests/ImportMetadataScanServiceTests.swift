import Foundation
import Testing
@testable import Aagedal_Photo_Agent

private nonisolated final class ImportMetadataScanGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var activeCount = 0
    private var maximumActiveCount = 0
    private var didStart = false
    private var isReleased = false

    func block() {
        condition.lock()
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
        didStart = true
        condition.broadcast()
        while !isReleased {
            condition.wait()
        }
        activeCount -= 1
        condition.unlock()
    }

    func waitUntilStarted() async -> Bool {
        for _ in 0..<200 {
            if started { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    func release() {
        condition.lock()
        isReleased = true
        condition.broadcast()
        condition.unlock()
    }

    var maximumConcurrentCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return maximumActiveCount
    }

    private var started: Bool {
        condition.lock()
        defer { condition.unlock() }
        return didStart
    }
}

private nonisolated final class ImportMetadataScanProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCallCount = 0

    func recordCall() {
        lock.lock()
        storedCallCount += 1
        lock.unlock()
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedCallCount
    }
}

@Suite("Import metadata filesystem boundaries")
struct ImportMetadataScanServiceTests {
    @Test("Capture-date scan returns immutable EXIF and modification-date groups")
    func captureDateScanReturnsCompleteGroups() async throws {
        let first = URL(fileURLWithPath: "/card/first.jpg")
        let second = URL(fileURLWithPath: "/card/second.jpg")
        let fallbackDate = try #require(
            ISO8601DateFormatter().date(from: "2026-09-02T12:34:56Z")
        )
        let service = ImportCaptureDateScanService(
            captureDateReader: { url in
                url == first ? "2026:09:01 08:09:10" : nil
            },
            modificationDateReader: { url in
                url == second ? fallbackDate : nil
            }
        )

        let result = await service.scan([first, second])
        let evidence: ImportCaptureDateScanService.Evidence
        switch result {
        case .complete(let completed):
            evidence = completed
        case .cancelled:
            Issue.record("An uncancelled scan must complete")
            return
        }

        #expect(evidence.requestedFileCount == 2)
        #expect(evidence.processedFileCount == 2)
        #expect(evidence.groups.map(\.dateString) == ["2026:09:01", "2026:09:02"])
        #expect(evidence.groups.map(\.folderDate) == ["2026-09-01", "2026-09-02"])
        #expect(evidence.groups.map(\.yearFolder) == ["2026", "2026"])
        #expect(evidence.groups.map(\.monthFolder) == ["09", "09"])
        #expect(evidence.groups[0].captureTimes[first] != nil)
        #expect(evidence.groups[1].captureTimes[second] == fallbackDate)
    }

    @Test("Cancellation after a capture-date read returns an explicit empty prefix")
    func captureDateCancellationAfterReadIsExplicit() async {
        let gate = ImportMetadataScanGate()
        let modificationProbe = ImportMetadataScanProbe()
        let file = URL(fileURLWithPath: "/card/first.jpg")
        let service = ImportCaptureDateScanService(
            captureDateReader: { _ in
                gate.block()
                return nil
            },
            modificationDateReader: { _ in
                modificationProbe.recordCall()
                return nil
            }
        )
        let task = Task { await service.scan([file]) }
        defer { gate.release() }
        #expect(await gate.waitUntilStarted())
        task.cancel()
        gate.release()

        switch await task.value {
        case .complete:
            Issue.record("A cancelled scan must not publish complete evidence")
        case .cancelled(let evidence):
            #expect(evidence.requestedFileCount == 1)
            #expect(evidence.processedFileCount == 0)
            #expect(evidence.groups.isEmpty)
        }
        #expect(modificationProbe.callCount == 0)
    }

    @Test("Capture-date actor serializes overlapping scans")
    func captureDateActorSerializesScans() async {
        let gate = ImportMetadataScanGate()
        let service = ImportCaptureDateScanService(
            captureDateReader: { _ in
                gate.block()
                return nil
            },
            modificationDateReader: { _ in nil }
        )
        let first = Task {
            await service.scan([URL(fileURLWithPath: "/card/first.jpg")])
        }
        defer { gate.release() }
        #expect(await gate.waitUntilStarted())
        let second = Task {
            await service.scan([URL(fileURLWithPath: "/card/second.jpg")])
        }
        for _ in 0..<20 { await Task.yield() }
        #expect(gate.maximumConcurrentCount == 1)
        gate.release()

        _ = await first.value
        _ = await second.value
        #expect(gate.maximumConcurrentCount == 1)
    }

    @Test("Folder inventory returns sorted complete evidence and omits empty dates")
    func folderInventoryReturnsCompleteEvidence() async {
        let base = URL(fileURLWithPath: "/photos", isDirectory: true)
        let folder = base.appendingPathComponent("2026-09-02 – Match", isDirectory: true)
        let service = ImportFolderSuggestionService { date, _ in
            date == "2026-09-02" ? [folder] : []
        }

        let result = await service.suggestions(
            for: ["2026-09-02", "2026-09-01"],
            under: base
        )
        switch result {
        case .complete(let evidence):
            #expect(evidence.requestedDates == ["2026-09-01", "2026-09-02"])
            #expect(evidence.completedDateCount == 2)
            #expect(evidence.suggestions == ["2026-09-02": [folder]])
        case .cancelled:
            Issue.record("An uncancelled inventory must complete")
        }
    }

    @Test("Folder inventory reports cancellation after a non-preemptible probe")
    func folderInventoryCancellationAfterProbeIsExplicit() async {
        let gate = ImportMetadataScanGate()
        let base = URL(fileURLWithPath: "/photos", isDirectory: true)
        let service = ImportFolderSuggestionService { _, _ in
            gate.block()
            return [base]
        }
        let task = Task {
            await service.suggestions(for: ["2026-09-01"], under: base)
        }
        defer { gate.release() }
        #expect(await gate.waitUntilStarted())
        task.cancel()
        gate.release()

        switch await task.value {
        case .complete:
            Issue.record("A cancelled inventory must not publish complete evidence")
        case .cancelled(let evidence):
            #expect(evidence.completedDateCount == 0)
            #expect(evidence.suggestions.isEmpty)
        }
    }

    @Test("Import rejects a superseded capture-date scan")
    func viewModelRejectsSupersededCaptureDateScan() async {
        let gate = ImportMetadataScanGate()
        let captureService = ImportCaptureDateScanService(
            captureDateReader: { url in
                if url.deletingPathExtension().lastPathComponent == "first" { gate.block() }
                return url.deletingPathExtension().lastPathComponent == "first"
                    ? "2026:09:01 08:00:00"
                    : "2026:09:02 09:00:00"
            },
            modificationDateReader: { _ in nil }
        )
        let viewModel = ImportViewModel(
            readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine(),
            captureDateScanService: captureService,
            folderSuggestionService: ImportFolderSuggestionService { _, _ in [] }
        )
        let pathExtension = viewModel.configuration.fileTypeFilter == .jpegOnly ? "jpg" : "arw"
        let first = URL(fileURLWithPath: "/card/first.\(pathExtension)")
        let second = URL(fileURLWithPath: "/card/second.\(pathExtension)")
        viewModel.sourceFiles = [first]
        viewModel.scanCaptureDates()
        defer { gate.release() }
        #expect(await gate.waitUntilStarted())

        viewModel.sourceFiles = [second]
        viewModel.scanCaptureDates()
        gate.release()
        for _ in 0..<200 where viewModel.isScanningDates {
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(!viewModel.isScanningDates)
        #expect(viewModel.dateGroups.map(\.dateString) == ["2026:09:02"])
        #expect(viewModel.dateGroups.first?.files == [second])
    }

    @Test("Import rejects superseded destination-folder evidence")
    func viewModelRejectsSupersededFolderEvidence() async {
        let gate = ImportMetadataScanGate()
        let firstBase = URL(fileURLWithPath: "/photos/first", isDirectory: true)
        let secondBase = URL(fileURLWithPath: "/photos/second", isDirectory: true)
        let firstFolder = firstBase.appendingPathComponent("First", isDirectory: true)
        let secondFolder = secondBase.appendingPathComponent("Second", isDirectory: true)
        let suggestionService = ImportFolderSuggestionService { _, base in
            if base == firstBase { gate.block() }
            return base == firstBase ? [firstFolder] : [secondFolder]
        }
        let viewModel = ImportViewModel(
            readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine(),
            folderSuggestionService: suggestionService
        )
        viewModel.configuration.destinationBaseURL = firstBase
        let date = viewModel.currentImportDateFolderName
        if viewModel.sortByDate {
            viewModel.dateGroups = [ImportDateGroup(
                dateString: date.replacingOccurrences(of: "-", with: ":"),
                folderName: date,
                shootFolderName: nil,
                yearFolder: String(date.prefix(4)),
                files: [URL(fileURLWithPath: "/card/placeholder.jpg")]
            )]
        }
        viewModel.refreshPreviousImportFolderSuggestions()
        defer { gate.release() }
        #expect(await gate.waitUntilStarted())

        viewModel.configuration.destinationBaseURL = secondBase
        viewModel.refreshPreviousImportFolderSuggestions()
        gate.release()
        for _ in 0..<200 where viewModel.isScanningPreviousImportFolders {
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(!viewModel.isScanningPreviousImportFolders)
        #expect(viewModel.previousImportFolderSuggestions == [date: [secondFolder]])
    }

    @Test("Import view model delegates both scans to serialized services")
    func viewModelDelegatesScans() throws {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = workspace
            .appendingPathComponent("Aagedal Photo Agent", isDirectory: true)
            .appendingPathComponent("ViewModels", isDirectory: true)
            .appendingPathComponent("ImportViewModel.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let folderSlice = try #require(source.range(
            of: "func refreshPreviousImportFolderSuggestions()"
        )).lowerBound..<#require(source.range(
            of: "func suggestedFoldersForCurrentImportDate()"
        )).lowerBound
        let captureSlice = try #require(source.range(
            of: "func scanCaptureDates()"
        )).lowerBound..<#require(source.range(
            of: "static let defaultShootGapThreshold"
        )).lowerBound

        let folderSource = String(source[folderSlice])
        let captureSource = String(source[captureSlice])
        #expect(folderSource.contains("await folderSuggestionService.suggestions("))
        #expect(captureSource.contains("await captureDateScanService.scan(files)"))
        #expect(folderSource.contains("self.folderSuggestionRequestID == requestID"))
        #expect(captureSource.contains("self.dateScanRequestID == requestID"))
        #expect(!folderSource.contains("Task.detached"))
        #expect(!captureSource.contains("Task.detached"))
        #expect(!captureSource.contains("ImageMetadata.read(from:"))
        #expect(!captureSource.contains("FileManager.default"))
    }

}
