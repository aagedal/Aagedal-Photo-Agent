import AVFAudio
import Foundation
import Observation

nonisolated struct CaptionVoiceMemoPlayback: Equatable, Sendable {
    let association: VoiceMemoAssociation
    let duration: TimeInterval
    let position: TimeInterval
    let isPlaying: Bool
}

nonisolated enum CaptionVoiceMemoState: Equatable, Sendable {
    case idle, loading, none
    case available(CaptionVoiceMemoPlayback)
    case missing(String)
    case unavailable(String)
}

/// The player never leaves its service executor, including preparation and teardown.
nonisolated protocol CaptionVoiceMemoAudioPlayer: AnyObject {
    var duration: TimeInterval { get }
    var currentTime: TimeInterval { get set }
    var isPlaying: Bool { get }
    func play() -> Bool
    func pause()
    func stop()
}

nonisolated extension AVAudioPlayer: CaptionVoiceMemoAudioPlayer {}

nonisolated struct CaptionVoiceMemoFileRevision: Equatable, Sendable {
    let size: UInt64
    let modified: Date
    let device: UInt64
    let inode: UInt64

    static func read(_ url: URL) throws -> Self {
        let values = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = values[.size] as? NSNumber,
              let modified = values[.modificationDate] as? Date,
              let device = values[.systemNumber] as? NSNumber,
              let inode = values[.systemFileNumber] as? NSNumber else {
            throw CocoaError(.fileReadUnknown)
        }
        return Self(size: size.uint64Value, modified: modified,
                    device: device.uint64Value, inode: inode.uint64Value)
    }
}

/// Resolves only persisted associations. Looking at a photo never starts playback or writes
/// metadata. A monotonically increasing generation prevents late load/stop commands from
/// replacing a newer photo, even when actor jobs are scheduled out of submission order.
actor CaptionVoiceMemoPlaybackService {
    nonisolated let filesystemQueue: DispatchSerialQueue
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        filesystemQueue.asUnownedSerialExecutor()
    }

    typealias Lookup = @Sendable (URL) throws -> VoiceMemoCompanionRepository.Lookup
    typealias PlayerFactory = @Sendable (URL) throws -> any CaptionVoiceMemoAudioPlayer
    typealias RevisionReader = @Sendable (URL) throws -> CaptionVoiceMemoFileRevision

    private let lookup: Lookup
    private let makePlayer: PlayerFactory
    private let readRevision: RevisionReader
    private let startAccess: @Sendable (URL) -> Bool
    private let stopAccess: @Sendable (URL) -> Void
    private var generation: UInt64 = 0
    private var player: (any CaptionVoiceMemoAudioPlayer)?
    private var association: VoiceMemoAssociation?
    private var imageRevision: CaptionVoiceMemoFileRevision?
    private var memoRevision: CaptionVoiceMemoFileRevision?
    private var accessURL: URL?

    init(
        filesystemQueue: DispatchSerialQueue = DispatchSerialQueue(
            label: "com.aagedal.photo-agent.caption-voice-memo", qos: .utility
        ),
        lookup: @escaping Lookup = { try VoiceMemoCompanionRepository().lookup(for: $0) },
        makePlayer: @escaping PlayerFactory = { try AVAudioPlayer(contentsOf: $0) },
        readRevision: @escaping RevisionReader = { try CaptionVoiceMemoFileRevision.read($0) },
        startAccess: @escaping @Sendable (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
        stopAccess: @escaping @Sendable (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }
    ) {
        self.filesystemQueue = filesystemQueue
        self.lookup = lookup
        self.makePlayer = makePlayer
        self.readRevision = readRevision
        self.startAccess = startAccess
        self.stopAccess = stopAccess
    }

    isolated deinit {
        releasePlayer()
    }

    func load(imageURL: URL?, generation requested: UInt64) -> CaptionVoiceMemoState? {
        guard requested > generation, !Task.isCancelled else { return nil }
        generation = requested
        releasePlayer()
        guard let imageURL else { return CaptionVoiceMemoState.none }
        let folder = imageURL.deletingLastPathComponent()
        if startAccess(folder) { accessURL = folder }
        defer { if player == nil { releasePlayer() } }
        do {
            switch try lookup(imageURL) {
            case .none: return CaptionVoiceMemoState.none
            case .missing(let record): return .missing(record.memoFilename)
            case .available(let found):
                guard !Task.isCancelled else { return nil }
                guard found.memoURL.pathExtension.lowercased() == "wav" else {
                    return .unavailable("The associated audio format is not supported. A WAV voice memo is required.")
                }
                let imageBefore = try readRevision(found.imageURL)
                let memoBefore = try readRevision(found.memoURL)
                let prepared = try makePlayer(found.memoURL)
                guard !Task.isCancelled else { prepared.stop(); return nil }
                guard prepared.duration.isFinite, prepared.duration > 0 else {
                    prepared.stop()
                    return .unavailable("The associated WAV has no playable audio.")
                }
                guard try readRevision(found.imageURL) == imageBefore,
                      try readRevision(found.memoURL) == memoBefore,
                      try lookup(imageURL) == .available(found) else {
                    prepared.stop()
                    return .unavailable("The photo or voice memo changed while loading. Refresh the voice memo.")
                }
                guard !Task.isCancelled else { prepared.stop(); return nil }
                association = found
                imageRevision = imageBefore
                memoRevision = memoBefore
                player = prepared
                return snapshot()
            }
        } catch let error as VoiceMemoCompanionRepository.RepositoryError {
            return .unavailable(error.localizedDescription)
        } catch {
            return .unavailable("The saved voice memo could not be opened. Check its relationship record, audio format and folder access, then refresh.")
        }
    }

    func toggle(generation requested: UInt64) -> CaptionVoiceMemoState? {
        guard requested == generation, !Task.isCancelled,
              let player, let association else { return nil }
        if player.isPlaying {
            player.pause()
        } else {
            do {
                guard try lookup(association.imageURL) == .available(association),
                      try readRevision(association.imageURL) == imageRevision,
                      try readRevision(association.memoURL) == memoRevision else {
                    releasePlayer()
                    return .unavailable("The photo or voice memo changed. Refresh before playing it again.")
                }
                guard !Task.isCancelled else { return nil }
                if player.currentTime >= player.duration { player.currentTime = 0 }
                guard player.play() else {
                    releasePlayer()
                    return .unavailable("Audio playback could not start. Check the audio output and refresh the voice memo.")
                }
                if Task.isCancelled { player.pause(); return snapshot() }
            } catch {
                releasePlayer()
                return .unavailable("The photo or voice memo is no longer accessible. Restore access and refresh.")
            }
        }
        return snapshot()
    }

    func progress(generation requested: UInt64) -> CaptionVoiceMemoState? {
        guard requested == generation, !Task.isCancelled else { return nil }
        return snapshot()
    }

    func clear(generation requested: UInt64) {
        guard requested > generation else { return }
        generation = requested
        releasePlayer()
    }

    private func snapshot() -> CaptionVoiceMemoState? {
        guard let player, let association else { return nil }
        return .available(CaptionVoiceMemoPlayback(
            association: association, duration: player.duration,
            position: max(0, min(player.currentTime, player.duration)),
            isPlaying: player.isPlaying
        ))
    }

    private func releasePlayer() {
        player?.stop()
        player = nil
        association = nil
        imageRevision = nil
        memoRevision = nil
        if let accessURL { stopAccess(accessURL) }
        accessURL = nil
    }
}

@MainActor @Observable
final class CaptionVoiceMemoPlaybackModel {
    private(set) var state: CaptionVoiceMemoState = .idle
    private(set) var isChangingPlayback = false
    @ObservationIgnored private let service: CaptionVoiceMemoPlaybackService
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var playbackTask: Task<CaptionVoiceMemoState?, Never>?

    init(service: CaptionVoiceMemoPlaybackService = CaptionVoiceMemoPlaybackService()) {
        self.service = service
    }

    func load(_ imageURL: URL?) async {
        guard !Task.isCancelled else { return }
        playbackTask?.cancel()
        playbackTask = nil
        generation &+= 1
        let requested = generation
        state = .loading
        isChangingPlayback = false
        let loaded = await service.load(imageURL: imageURL, generation: requested)
        guard requested == generation else { return }
        guard !Task.isCancelled else { stop(); return }
        state = loaded ?? .idle
    }

    func toggle() async {
        guard case .available = state, !isChangingPlayback else { return }
        let requested = generation
        isChangingPlayback = true
        let task = Task { await service.toggle(generation: requested) }
        playbackTask = task
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        guard requested == generation else { return }
        playbackTask = nil
        isChangingPlayback = false
        if let result, !Task.isCancelled { state = result }
    }

    func pollWhilePlaying() async {
        let requested = generation
        while requested == generation, !Task.isCancelled,
              case .available(let current) = state, current.isPlaying {
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard requested == generation, !Task.isCancelled else { return }
            if let result = await service.progress(generation: requested),
               requested == generation, !Task.isCancelled { state = result }
        }
    }

    func stop() {
        playbackTask?.cancel()
        playbackTask = nil
        generation &+= 1
        let requested = generation
        state = .idle
        isChangingPlayback = false
        Task { await service.clear(generation: requested) }
    }
}

/// Serializes recovery hashing/copying away from MainActor and balances any picker-granted
/// security scopes. Candidate inspection never writes; only the confirmed recovery call commits.
actor CaptionVoiceMemoRecoveryService {
    nonisolated let filesystemQueue: DispatchSerialQueue
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        filesystemQueue.asUnownedSerialExecutor()
    }

    typealias Assess = @Sendable (URL, URL) throws -> VoiceMemoCompanionRepository.RecoveryAssessment
    typealias Recover = @Sendable (
        URL, URL, Bool
    ) throws -> VoiceMemoCompanionRepository.RecoveryReceipt

    private let assessCandidate: Assess
    private let recoverCandidate: Recover
    private let startAccess: @Sendable (URL) -> Bool
    private let stopAccess: @Sendable (URL) -> Void

    init(
        filesystemQueue: DispatchSerialQueue = DispatchSerialQueue(
            label: "com.aagedal.photo-agent.caption-voice-memo-recovery", qos: .utility
        ),
        assessCandidate: @escaping Assess = {
            try VoiceMemoCompanionRepository().assessRecoveryCandidate($0, for: $1)
        },
        recoverCandidate: @escaping Recover = {
            try VoiceMemoCompanionRepository().recoverMissingMemo(
                for: $1, from: $0, confirmingReplacement: $2
            )
        },
        startAccess: @escaping @Sendable (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
        stopAccess: @escaping @Sendable (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }
    ) {
        self.filesystemQueue = filesystemQueue
        self.assessCandidate = assessCandidate
        self.recoverCandidate = recoverCandidate
        self.startAccess = startAccess
        self.stopAccess = stopAccess
    }

    func assess(candidateURL: URL, imageURL: URL) throws -> VoiceMemoCompanionRepository.RecoveryAssessment {
        try Task.checkCancellation()
        return try withAccess(candidateURL: candidateURL, imageURL: imageURL) {
            try Task.checkCancellation()
            return try assessCandidate(candidateURL, imageURL)
        }
    }

    func recover(
        candidateURL: URL,
        imageURL: URL,
        confirmingReplacement: Bool
    ) throws -> VoiceMemoCompanionRepository.RecoveryReceipt {
        try Task.checkCancellation()
        return try withAccess(candidateURL: candidateURL, imageURL: imageURL) {
            try Task.checkCancellation()
            return try recoverCandidate(candidateURL, imageURL, confirmingReplacement)
        }
    }

    private func withAccess<T>(
        candidateURL: URL,
        imageURL: URL,
        operation: () throws -> T
    ) rethrows -> T {
        let folderURL = imageURL.deletingLastPathComponent()
        let candidateAccess = startAccess(candidateURL)
        let folderAccess = startAccess(folderURL)
        defer {
            if folderAccess { stopAccess(folderURL) }
            if candidateAccess { stopAccess(candidateURL) }
        }
        return try operation()
    }
}

@MainActor @Observable
final class CaptionVoiceMemoRecoveryModel {
    private enum SelectionOutcome: Sendable {
        case recovered
        case replacement(VoiceMemoCompanionRepository.RecoveryAssessment)
        case failed(String)
        case cancelled
    }

    private(set) var isWorking = false
    private(set) var pendingReplacement: VoiceMemoCompanionRepository.RecoveryAssessment?
    private(set) var errorMessage: String?
    @ObservationIgnored private let service: CaptionVoiceMemoRecoveryService
    @ObservationIgnored private var pendingImageURL: URL?
    @ObservationIgnored private var task: Task<SelectionOutcome, Never>?
    @ObservationIgnored private var generation: UInt64 = 0

    init(service: CaptionVoiceMemoRecoveryService = CaptionVoiceMemoRecoveryService()) {
        self.service = service
    }

    func select(candidateURL: URL, for imageURL: URL) async -> Bool {
        cancel()
        generation &+= 1
        let requested = generation
        isWorking = true
        errorMessage = nil
        let work = Task { [service] in
            do {
                let assessment = try await service.assess(
                    candidateURL: candidateURL, imageURL: imageURL
                )
                switch assessment.kind {
                case .exactRecovery:
                    _ = try await service.recover(
                        candidateURL: candidateURL,
                        imageURL: imageURL,
                        confirmingReplacement: false
                    )
                    return SelectionOutcome.recovered
                case .explicitReplacement:
                    return SelectionOutcome.replacement(assessment)
                }
            } catch is CancellationError {
                return SelectionOutcome.cancelled
            } catch {
                return SelectionOutcome.failed(error.localizedDescription)
            }
        }
        task = work
        let outcome = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        guard requested == generation else { return false }
        task = nil
        isWorking = false
        switch outcome {
        case .recovered:
            pendingReplacement = nil
            pendingImageURL = nil
            return true
        case .replacement(let assessment):
            pendingReplacement = assessment
            pendingImageURL = imageURL
            return false
        case .failed(let message):
            errorMessage = message
            return false
        case .cancelled:
            return false
        }
    }

    func confirmReplacement() async -> Bool {
        guard let assessment = pendingReplacement, let imageURL = pendingImageURL else { return false }
        generation &+= 1
        let requested = generation
        isWorking = true
        errorMessage = nil
        let work = Task { [service] in
            do {
                _ = try await service.recover(
                    candidateURL: assessment.candidateURL,
                    imageURL: imageURL,
                    confirmingReplacement: true
                )
                return SelectionOutcome.recovered
            } catch is CancellationError {
                return SelectionOutcome.cancelled
            } catch {
                return SelectionOutcome.failed(error.localizedDescription)
            }
        }
        task = work
        let outcome = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        guard requested == generation else { return false }
        task = nil
        isWorking = false
        switch outcome {
        case .recovered:
            pendingReplacement = nil
            pendingImageURL = nil
            return true
        case .failed(let message):
            errorMessage = message
            return false
        case .cancelled, .replacement:
            return false
        }
    }

    func dismissReplacement() {
        pendingReplacement = nil
        pendingImageURL = nil
    }

    func reportPickerError(_ error: Error) {
        errorMessage = error.localizedDescription
    }

    func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
        isWorking = false
        pendingReplacement = nil
        pendingImageURL = nil
        errorMessage = nil
    }
}

nonisolated enum CaptionVoiceMemoReassociationResult: Equatable, Sendable {
    case reassociated(VoiceMemoCompanionRepository.ReassociationReceipt)
    case ambiguous(candidateCount: Int)
    case sourceChanged(relationshipCount: Int)
    case notFound
}

/// Owns directory enumeration, hashing and the eventual relationship transaction on one
/// retained utility executor. The picker scope remains active across discovery and commit.
actor CaptionVoiceMemoReassociationService {
    nonisolated let filesystemQueue: DispatchSerialQueue
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        filesystemQueue.asUnownedSerialExecutor()
    }

    typealias Discover = @Sendable (
        URL, URL
    ) throws -> VoiceMemoCompanionRepository.ReassociationDiscovery
    typealias Commit = @Sendable (
        VoiceMemoCompanionRepository.ReassociationCandidate, URL
    ) throws -> VoiceMemoCompanionRepository.ReassociationReceipt

    private let discover: Discover
    private let commit: Commit
    private let startAccess: @Sendable (URL) -> Bool
    private let stopAccess: @Sendable (URL) -> Void

    init(
        filesystemQueue: DispatchSerialQueue = DispatchSerialQueue(
            label: "com.aagedal.photo-agent.caption-voice-memo-reassociation", qos: .utility
        ),
        discover: @escaping Discover = {
            try VoiceMemoCompanionRepository().discoverReassociation(for: $1, in: [$0])
        },
        commit: @escaping Commit = {
            try VoiceMemoCompanionRepository().commitReassociation($0, to: $1)
        },
        startAccess: @escaping @Sendable (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
        stopAccess: @escaping @Sendable (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }
    ) {
        self.filesystemQueue = filesystemQueue
        self.discover = discover
        self.commit = commit
        self.startAccess = startAccess
        self.stopAccess = stopAccess
    }

    func reassociate(searchLocation: URL, imageURL: URL) throws -> CaptionVoiceMemoReassociationResult {
        try Task.checkCancellation()
        let imageFolder = imageURL.deletingLastPathComponent()
        let searchAccess = startAccess(searchLocation)
        let imageAccess = startAccess(imageFolder)
        defer {
            if imageAccess { stopAccess(imageFolder) }
            if searchAccess { stopAccess(searchLocation) }
        }

        let discovery = try discover(searchLocation, imageURL)
        try Task.checkCancellation()
        switch discovery {
        case .exact(let candidate):
            return .reassociated(try commit(candidate, imageURL))
        case .ambiguous(let candidates):
            return .ambiguous(candidateCount: candidates.count)
        case .sourceChanged(let relationships):
            return .sourceChanged(relationshipCount: relationships.count)
        case .notFound:
            return .notFound
        }
    }
}

@MainActor @Observable
final class CaptionVoiceMemoReassociationModel {
    private(set) var isWorking = false
    private(set) var result: CaptionVoiceMemoReassociationResult?
    private(set) var errorMessage: String?
    @ObservationIgnored private let service: CaptionVoiceMemoReassociationService
    @ObservationIgnored private var task: Task<CaptionVoiceMemoReassociationResult, Error>?
    @ObservationIgnored private var generation: UInt64 = 0

    init(service: CaptionVoiceMemoReassociationService = CaptionVoiceMemoReassociationService()) {
        self.service = service
    }

    func search(_ location: URL, for imageURL: URL) async -> Bool {
        cancel()
        generation &+= 1
        let requested = generation
        isWorking = true
        let work = Task { [service] in
            try await service.reassociate(searchLocation: location, imageURL: imageURL)
        }
        task = work
        do {
            let outcome = try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
            }
            guard requested == generation, !Task.isCancelled else { return false }
            task = nil
            isWorking = false
            result = outcome
            return if case .reassociated = outcome { true } else { false }
        } catch is CancellationError {
            guard requested == generation else { return false }
            task = nil
            isWorking = false
            return false
        } catch {
            guard requested == generation else { return false }
            task = nil
            isWorking = false
            errorMessage = error.localizedDescription
            return false
        }
    }

    func reportPickerError(_ error: Error) {
        errorMessage = error.localizedDescription
    }

    func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
        isWorking = false
        result = nil
        errorMessage = nil
    }
}
