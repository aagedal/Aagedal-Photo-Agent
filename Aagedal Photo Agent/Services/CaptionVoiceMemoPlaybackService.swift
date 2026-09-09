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
