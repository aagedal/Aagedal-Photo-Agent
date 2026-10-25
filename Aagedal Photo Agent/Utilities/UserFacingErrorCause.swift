import Foundation

/// One plain sentence explaining why a file operation failed, for error messages shaped
/// "Couldn't save … . {cause} Try again." System errors get photographer-friendly wording;
/// the app's own errors already explain themselves and are passed through.
nonisolated enum UserFacingErrorCause {
    static func sentence(for error: Error) -> String {
        let ns = error as NSError
        // The app wraps its own explanations in CocoaError with an explicit description;
        // system errors compute theirs and don't set the key.
        if let explicit = ns.userInfo[NSLocalizedDescriptionKey] as? String,
           !explicit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return withPeriod(explicit)
        }
        let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError
        func posix(_ codes: Int32...) -> Bool {
            [ns, underlying].contains { error in
                guard let error, error.domain == NSPOSIXErrorDomain else { return false }
                return codes.map(Int.init).contains(error.code)
            }
        }
        if error is DecodingError { return damaged }
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileWriteOutOfSpaceError: return "The disk is full."
            case NSFileWriteNoPermissionError, NSFileReadNoPermissionError, NSFileWriteVolumeReadOnlyError:
                return "The folder is read-only or access was denied."
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError: return "The file is no longer there."
            case NSFileWriteFileExistsError: return "A file with that name already exists."
            case NSFileReadCorruptFileError, NSPropertyListReadCorruptError, NSCoderReadCorruptError:
                return damaged
            default: break
            }
        }
        if posix(ENOSPC, EDQUOT) { return "The disk is full." }
        if posix(EACCES, EPERM, EROFS) { return "The folder is read-only or access was denied." }
        if posix(ENOENT) { return "The file is no longer there." }
        if posix(EIO) { return "The disk couldn't be read or written. Check that the drive is still connected." }
        if ns.domain == NSCocoaErrorDomain {
            if ns.code == NSFileWriteUnknownError || ns.code == NSFileReadUnknownError {
                return "The file couldn't be written or checked afterwards."
            }
            // Foundation's own descriptions are written for users.
            return withPeriod(error.localizedDescription)
        }
        if ns.domain == NSPOSIXErrorDomain || ns.domain == NSOSStatusErrorDomain {
            return "The file couldn't be read or written."
        }
        return withPeriod(error.localizedDescription)
    }

    private static let damaged = "The saved data is damaged or in an unexpected format."

    private static func withPeriod(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "The file couldn't be read or written." }
        return trimmed.hasSuffix(".") ? trimmed : trimmed + "."
    }
}
