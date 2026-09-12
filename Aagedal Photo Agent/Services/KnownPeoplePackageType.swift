import UniformTypeIdentifiers

extension UTType {
    /// Shared with Aagedal FTP Sync. A bare `.aagedalpeople` item is a directory
    /// package; ZIP transport uses the distinct `.aagedalpeople.zip` suffix.
    static let aagedalPeopleLibrary = UTType(
        exportedAs: "no.aagedal.people-library",
        conformingTo: .package
    )
}
