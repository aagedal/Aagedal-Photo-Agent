import Foundation
import SwiftExif

/// Serialized filesystem/metadata boundary for Sony dual-card voice-memo association.
///
/// EXIF and file-resource reads are synchronous once entered. Cancellation is therefore sampled
/// before and after every read, and the main actor receives either a complete immutable report or
/// an exact processed prefix that it must not present as complete association evidence.
actor ImportVoiceMemoAssociationScanService {
    typealias ImageEvidenceReader = @Sendable (URL) -> SonyVoiceMemoImageEvidence
    typealias MemoDateReader = @Sendable (URL) -> Date

    struct Progress: Sendable, Equatable {
        let requestedPrimaryImageCount: Int
        let processedPrimaryImageCount: Int
        let requestedPrimaryMemoCount: Int
        let processedPrimaryMemoCount: Int
        let requestedCompanionFileCount: Int
        let processedCompanionFileCount: Int

        var requestedFileCount: Int {
            requestedPrimaryImageCount + requestedPrimaryMemoCount + requestedCompanionFileCount
        }

        var processedFileCount: Int {
            processedPrimaryImageCount + processedPrimaryMemoCount + processedCompanionFileCount
        }
    }

    struct Evidence: Sendable, Equatable {
        let progress: Progress
        let report: VoiceMemoAssociationReport
    }

    enum Result: Sendable, Equatable {
        case complete(Evidence)
        case cancelled(Progress)
    }

    private let imageEvidenceReader: ImageEvidenceReader
    private let memoDateReader: MemoDateReader

    init(
        imageEvidenceReader: @escaping ImageEvidenceReader = {
            ImportVoiceMemoAssociationScanService.readImageEvidence(from: $0)
        },
        memoDateReader: @escaping MemoDateReader = {
            ImportVoiceMemoAssociationScanService.readMemoDate(from: $0)
        }
    ) {
        self.imageEvidenceReader = imageEvidenceReader
        self.memoDateReader = memoDateReader
    }

    func scan(
        primaryImages: [URL],
        primaryMemos: [URL],
        companionFiles: [URL],
        primaryRoot: URL?,
        companionRoot: URL?
    ) -> Result {
        let didStartAccessingPrimary = primaryRoot?.startAccessingSecurityScopedResource() ?? false
        let didStartAccessingCompanion = companionRoot?.startAccessingSecurityScopedResource() ?? false
        defer {
            if didStartAccessingPrimary { primaryRoot?.stopAccessingSecurityScopedResource() }
            if didStartAccessingCompanion { companionRoot?.stopAccessingSecurityScopedResource() }
        }

        var primaryEvidence: [SonyVoiceMemoImageEvidence] = []
        var companionEvidence: [SonyVoiceMemoImageEvidence] = []
        var primaryMemoDates: [URL: Date] = [:]
        var companionMemoDates: [URL: Date] = [:]
        var processedPrimaryImages = 0
        var processedPrimaryMemos = 0
        var processedCompanionFiles = 0

        func progress() -> Progress {
            Progress(
                requestedPrimaryImageCount: primaryImages.count,
                processedPrimaryImageCount: processedPrimaryImages,
                requestedPrimaryMemoCount: primaryMemos.count,
                processedPrimaryMemoCount: processedPrimaryMemos,
                requestedCompanionFileCount: companionFiles.count,
                processedCompanionFileCount: processedCompanionFiles
            )
        }

        for file in primaryImages {
            guard !Task.isCancelled else { return .cancelled(progress()) }
            let evidence = imageEvidenceReader(file)
            guard !Task.isCancelled else { return .cancelled(progress()) }
            primaryEvidence.append(evidence)
            processedPrimaryImages += 1
        }
        for file in primaryMemos {
            guard !Task.isCancelled else { return .cancelled(progress()) }
            let date = memoDateReader(file)
            guard !Task.isCancelled else { return .cancelled(progress()) }
            primaryMemoDates[file] = date
            processedPrimaryMemos += 1
        }
        for file in companionFiles {
            guard !Task.isCancelled else { return .cancelled(progress()) }
            if file.pathExtension.caseInsensitiveCompare("wav") == .orderedSame {
                let date = memoDateReader(file)
                guard !Task.isCancelled else { return .cancelled(progress()) }
                companionMemoDates[file] = date
            } else {
                let evidence = imageEvidenceReader(file)
                guard !Task.isCancelled else { return .cancelled(progress()) }
                companionEvidence.append(evidence)
            }
            processedCompanionFiles += 1
        }

        let completedProgress = progress()
        guard !Task.isCancelled else { return .cancelled(completedProgress) }
        let report = SonyDualCardVoiceMemoAssociationService().associate(
            primaryImages: primaryEvidence,
            companionImages: companionEvidence,
            primaryMemoFileDates: primaryMemoDates,
            companionMemoFileDates: companionMemoDates
        )
        guard !Task.isCancelled else { return .cancelled(completedProgress) }
        return .complete(Evidence(progress: completedProgress, report: report))
    }

    nonisolated private static func readMemoDate(from url: URL) -> Date {
        let values = try? url.resourceValues(forKeys: [
            .creationDateKey,
            .contentModificationDateKey,
        ])
        // Missing dates are not evidence that a WAV followed its image. `.distantPast` makes the
        // association service's lower-bound rule fail closed and visible.
        return values?.creationDate ?? values?.contentModificationDate ?? .distantPast
    }

    nonisolated private static func readImageEvidence(from url: URL) -> SonyVoiceMemoImageEvidence {
        guard let metadata = try? ImageMetadata.read(from: url), let exif = metadata.exif,
              let captured = exif.dateTimeOriginal?.trimmingCharacters(in: .whitespacesAndNewlines),
              !captured.isEmpty else {
            return SonyVoiceMemoImageEvidence(url: url, captureSignature: nil, capturedAt: nil)
        }

        let make = exif.make?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let model = exif.model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let software = exif.software?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let subsecond = exif.subSecTimeOriginal?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let offset = exif.offsetTimeOriginal?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard make.caseInsensitiveCompare("SONY") == .orderedSame,
              !model.isEmpty, !software.isEmpty, !subsecond.isEmpty, !offset.isEmpty else {
            return SonyVoiceMemoImageEvidence(url: url, captureSignature: nil, capturedAt: nil)
        }

        let signature = [make, model, software, captured, subsecond, offset].joined(separator: "|")
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy:MM:dd HH:mm:ssXXX"
        return SonyVoiceMemoImageEvidence(
            url: url,
            captureSignature: signature,
            capturedAt: parser.date(from: captured + offset)
        )
    }
}
