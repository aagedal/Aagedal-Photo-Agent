import Foundation

/// One plain sentence explaining why a file operation failed, for error messages shaped
/// "Couldn't save … . {cause} Try again." System errors get photographer-friendly wording;
/// the app's own errors already explain themselves and are passed through.
nonisolated enum UserFacingErrorCause {
    static func sentence(for error: Error) -> String {
        let ns = error as NSError
        // The app wraps its own explanations in CocoaError with an explicit description;
        // system errors compute theirs and don't set the key.
        if let explicit = ns.userInfo[NSLocalizedDescriptionKey] as? String {
            let trimmed = explicit.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed.hasSuffix(".") ? trimmed : trimmed + "." }
        }
        let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError
        func posix(_ codes: Int32...) -> Bool {
            [ns, underlying].contains { error in
                guard let error, error.domain == NSPOSIXErrorDomain else { return false }
                return codes.map(Int.init).contains(error.code)
            }
        }
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileWriteOutOfSpaceError: return "The disk is full."
            case NSFileWriteNoPermissionError, NSFileReadNoPermissionError, NSFileWriteVolumeReadOnlyError:
                return "The folder is read-only or access was denied."
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError: return "The file is no longer there."
            default: break
            }
        }
        if posix(ENOSPC, EDQUOT) { return "The disk is full." }
        if posix(EACCES, EPERM, EROFS) { return "The folder is read-only or access was denied." }
        if posix(ENOENT) { return "The file is no longer there." }
        if ns.domain == NSCocoaErrorDomain || ns.domain == NSPOSIXErrorDomain || ns.domain == NSOSStatusErrorDomain {
            return "The folder may be read-only or the disk full."
        }
        let own = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !own.isEmpty else { return "The folder may be read-only or the disk full." }
        return own.hasSuffix(".") ? own : own + "."
    }
}
