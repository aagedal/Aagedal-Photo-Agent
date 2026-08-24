import Foundation

/// Supported video container formats.
public enum VideoFormat: String, Sendable, Equatable {
    case mp4
    case mov
    case m4v
    case mxf
    case mkv
    case webm
    case avi
    case mpg
    case braw
    case arriraw
    case r3d
    case nikonRaw
    case xocn
    case crm
    case crl
    /// On2 IVF — a minimal container wrapping a single raw video elementary
    /// stream (VP8, VP9, AV1, or the experimental AV2). Read-only.
    case ivf
}
