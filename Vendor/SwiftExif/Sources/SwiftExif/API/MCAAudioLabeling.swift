import Foundation

/// SMPTE ST 377-4 / ST 2020-1 Multi-Channel Audio (MCA) labelling, as carried
/// by AudioChannelLabel / SoundfieldGroupLabel / GroupOfSoundfieldGroupsLabel
/// subdescriptors in MXF files. This is the metadata that bmxtools writes via
/// `bmxtranswrap --audio-labels file.txt`, and that AS-11 broadcast deliverables
/// rely on for unambiguous channel assignment (chL/chR/chM1/chC/chLFE/…),
/// soundfield grouping (sgST = stereo, sgM = mono, sg51 = 5.1, …), and
/// program/dialog/M&E grouping (ggMPg, ggDcm, ggME, …).
///
/// Each subdescriptor contributes a row to one of the three arrays below;
/// `linkID` UUIDs cross-reference the rows so a channel can resolve up to its
/// soundfield group and then to its group-of-soundfield-groups.
public struct MCAAudioLabeling: Sendable, Equatable {
    public var channels: [MCAChannelLabel]
    public var soundfieldGroups: [MCASoundfieldGroup]
    public var groupsOfSoundfieldGroups: [MCAGroupOfSoundfieldGroups]

    public init(
        channels: [MCAChannelLabel] = [],
        soundfieldGroups: [MCASoundfieldGroup] = [],
        groupsOfSoundfieldGroups: [MCAGroupOfSoundfieldGroups] = []
    ) {
        self.channels = channels
        self.soundfieldGroups = soundfieldGroups
        self.groupsOfSoundfieldGroups = groupsOfSoundfieldGroups
    }

    public var isEmpty: Bool {
        channels.isEmpty && soundfieldGroups.isEmpty && groupsOfSoundfieldGroups.isEmpty
    }
}

/// One channel label inside an MXF audio essence (one MCA Tag Symbol such as
/// "chL", "chR", "chC", "chLFE", "chM1"…). bmxtools writes one
/// AudioChannelLabelSubDescriptor per mono PCM track, so `trackIndex` resolves
/// to the AudioStream slot that carries the labeled channel.
public struct MCAChannelLabel: Sendable, Equatable {
    /// Index into `VideoMetadata.audioStreams` (track ordering of the file).
    /// `nil` if the subdescriptor wasn't reachable from any sound descriptor's
    /// SubDescriptors strong-reference array.
    public var trackIndex: Int?
    /// MCA Tag Symbol — short identifier, e.g. "chL", "chR", "chM1".
    public var symbol: String?
    /// MCA Tag Name — human-readable name, e.g. "Left", "Right", "Mono One".
    public var name: String?
    /// MCA Channel ID — 1-based index into the parent track's channel layout.
    /// Often absent on per-track mono audio (bmxtools omits it).
    public var channelID: Int?
    /// MCA Link ID — InstanceUID-equivalent that identifies this channel
    /// label so a soundfield group can refer back to it.
    public var linkID: UUID?
    /// Soundfield Group Link ID — points at one entry in `soundfieldGroups`.
    public var soundfieldGroupLinkID: UUID?
    /// RFC 5646 spoken language tag (e.g. "en", "no").
    public var language: String?

    public init() {}
}

/// One soundfield-group label (e.g. "sgST" Standard Stereo, "sgM" Mono, "sg51"
/// 5.1 Surround). Channel labels reference this via `soundfieldGroupLinkID`,
/// and a soundfield group can belong to multiple groups-of-soundfield-groups.
public struct MCASoundfieldGroup: Sendable, Equatable {
    /// MCA Tag Symbol, e.g. "sgST", "sgM".
    public var symbol: String?
    /// MCA Tag Name, e.g. "Standard Stereo", "Monoaural".
    public var name: String?
    /// MCA Link ID identifying this soundfield group.
    public var linkID: UUID?
    /// References into `groupsOfSoundfieldGroups` (a soundfield group can sit
    /// in more than one program group simultaneously).
    public var groupOfGroupsLinkIDs: [UUID]
    /// RFC 5646 spoken language tag.
    public var language: String?

    public init() {
        self.groupOfGroupsLinkIDs = []
    }
}

/// One group-of-soundfield-groups label (e.g. "ggMPg" Main Program, "ggDcm"
/// Dialog Centric Mix, "ggME" Music & Effects).
public struct MCAGroupOfSoundfieldGroups: Sendable, Equatable {
    /// MCA Tag Symbol, e.g. "ggMPg", "ggDcm", "ggME".
    public var symbol: String?
    /// MCA Tag Name, e.g. "Main Program", "Dialog Centric Mix",
    /// "Music and Effects".
    public var name: String?
    /// MCA Link ID identifying this group-of-soundfield-groups.
    public var linkID: UUID?
    /// RFC 5646 spoken language tag.
    public var language: String?

    public init() {}
}
