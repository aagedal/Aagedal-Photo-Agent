import Foundation

/// Versioned, local-only acknowledgement state for the Known People privacy UX.
/// Copy changes that alter the described data lifecycle should bump the matching version.
nonisolated enum KnownPeoplePrivacyLifecycle {
    static let disclosureVersion = 1
    static let iCloudConsentVersion = 1

    static func hasAcknowledgedDisclosure(in defaults: UserDefaults = .standard) -> Bool {
        defaults.integer(forKey: UserDefaultsKeys.knownPeopleDisclosureAcknowledgedVersion) >= disclosureVersion
    }

    static func acknowledgeDisclosure(in defaults: UserDefaults = .standard) {
        defaults.set(disclosureVersion, forKey: UserDefaultsKeys.knownPeopleDisclosureAcknowledgedVersion)
    }

    static func hasConfirmedICloudTransfer(in defaults: UserDefaults = .standard) -> Bool {
        defaults.integer(forKey: UserDefaultsKeys.knownPeopleICloudConsentVersion) >= iCloudConsentVersion
    }

    static func recordICloudTransferConfirmation(in defaults: UserDefaults = .standard) {
        defaults.set(iCloudConsentVersion, forKey: UserDefaultsKeys.knownPeopleICloudConsentVersion)
    }

    static func requiresICloudConfirmation(
        enabling: Bool,
        currentlyEnabled: Bool,
        defaults: UserDefaults = .standard
    ) -> Bool {
        enabling && !currentlyEnabled && !hasConfirmedICloudTransfer(in: defaults)
    }
}

/// Testable projection used by the single Known People Data Management section.
nonisolated struct KnownPeopleDataSummary: Equatable, Sendable {
    let peopleCount: Int
    let sampleCount: Int
    let storedBytes: Int64
    let syncEnabled: Bool

    var storageDestination: String {
        if syncEnabled {
            return "iCloud Drive › Aagedal Photo Agent › KnownPeople"
        }
        return "This Mac › Application Support › Aagedal Photo Agent › KnownPeople"
    }

    static func make(
        peopleCount: Int,
        sampleCount: Int,
        storageURL: URL,
        syncEnabled: Bool
    ) -> KnownPeopleDataSummary {
        KnownPeopleDataSummary(
            peopleCount: peopleCount,
            sampleCount: sampleCount,
            storedBytes: directorySize(at: storageURL),
            syncEnabled: syncEnabled
        )
    }

    /// Counts regular files only and never follows package descendants or symbolic links.
    static func directorySize(at root: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}
