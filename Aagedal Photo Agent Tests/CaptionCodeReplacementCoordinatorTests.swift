import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@MainActor
@Suite("Caption code replacement integration")
struct CaptionCodeReplacementCoordinatorTests {
    private let coordinator = CaptionCodeReplacementCoordinator()

    @Test("Only headline and caption-style fields change")
    func eligibleFieldsOnly() throws {
        let list = CodeReplacementParser().parse(Data("name\tAda Lovelace\ncity\tOslo".utf8))
        let metadata = IPTCMetadata(
            title: "\\name\\ reports",
            description: "From \\city\\ by \\name\\",
            extendedDescription: "Profile: \\name\\",
            keywords: ["\\name\\"],
            personShown: ["\\name\\"],
            creator: "\\name\\"
        )

        let result = coordinator.plan(
            metadata: metadata,
            list: list,
            configuration: configuration(),
            compositionState: .committed
        )

        #expect(result.status == .completed)
        let updated = try #require(result.metadata)
        #expect(updated.title == "Ada Lovelace reports")
        #expect(updated.description == "From Oslo by Ada Lovelace")
        #expect(updated.extendedDescription == "Profile: Ada Lovelace")
        #expect(updated.keywords == ["\\name\\"])
        #expect(updated.personShown == ["\\name\\"])
        #expect(updated.creator == "\\name\\")
        #expect(result.fields.map(\.field) == CaptionCodeReplacementField.allCases)
    }

    @Test("An ambiguous occurrence refuses the entire multi-field update")
    func ambiguousIsAtomic() {
        let list = CodeReplacementParser().parse(Data("safe\tExpanded\ndesk\tNews\ndesk\tSports".utf8))
        let metadata = IPTCMetadata(
            title: "\\safe\\",
            description: "Filed by \\desk\\"
        )

        let result = coordinator.plan(
            metadata: metadata,
            list: list,
            configuration: configuration(),
            compositionState: .committed
        )

        #expect(result.status == .ambiguousOccurrence)
        #expect(result.metadata == nil)
        #expect(result.fields.first?.proposedText == "Expanded")
        #expect(result.fields[1].proposedText == "Filed by \\desk\\")
        #expect(result.fields[1].unresolvedOccurrences.count == 1)
    }

    @Test("Invalid source rows and configuration never return mutable metadata")
    func invalidInputRefusesMutation() {
        let malformed = CodeReplacementParser().parse(Data("ok\tSafe\nbad-row".utf8))
        let metadata = IPTCMetadata(title: "\\ok\\")

        let invalidSource = coordinator.plan(
            metadata: metadata,
            list: malformed,
            configuration: configuration(),
            compositionState: .committed
        )
        #expect(invalidSource.status == .invalidSource)
        #expect(invalidSource.metadata == nil)

        let invalidConfiguration = coordinator.plan(
            metadata: metadata,
            list: CodeReplacementParser().parse(Data("ok\tSafe".utf8)),
            configuration: configuration(startDelimiter: ""),
            compositionState: .committed
        )
        #expect(invalidConfiguration.status == .invalidConfiguration)
        #expect(invalidConfiguration.metadata == nil)
    }

    @Test("Active IME composition and disabled state are explicit no-ops")
    func compositionAndDisabled() {
        let list = CodeReplacementParser().parse(Data("name\t山田太郎".utf8))
        let metadata = IPTCMetadata(description: "\\name\\")

        let composing = coordinator.plan(
            metadata: metadata,
            list: list,
            configuration: configuration(),
            compositionState: .active
        )
        #expect(composing.status == .activeComposition)
        #expect(composing.metadata == nil)

        var disabledConfiguration = configuration()
        disabledConfiguration.isEnabled = false
        let disabled = coordinator.plan(
            metadata: metadata,
            list: list,
            configuration: disabledConfiguration,
            compositionState: .committed
        )
        #expect(disabled.status == .disabled)
        #expect(disabled.metadata == nil)
    }

    @Test("Caption editor exposes composition state through the flush boundary")
    func flushBoundaryCompositionState() throws {
        let flushCoordinator = CaptionWorkspaceFlushCoordinator()
        let owner = UUID()
        flushCoordinator.register(
            owner: owner,
            compositionState: { .active },
            handler: {}
        )

        #expect(try flushCoordinator.editorCompositionState() == .active)
        flushCoordinator.unregister(owner: owner)
        #expect(throws: CaptionWorkspaceFlushError.handlerUnavailable) {
            try flushCoordinator.editorCompositionState()
        }
    }

    @Test("No matches returns an unchanged safe snapshot")
    func unchanged() throws {
        let metadata = IPTCMetadata(title: "Ordinary headline", description: "Caption")
        let result = coordinator.plan(
            metadata: metadata,
            list: CodeReplacementParser().parse(Data("name\tAda".utf8)),
            configuration: configuration(),
            compositionState: .committed
        )

        #expect(result.status == .unchanged)
        #expect(try #require(result.metadata) == metadata)
        #expect(!result.changed)
    }

    @Test("Pending preview only validates for its exact asset and draft")
    func stalePreviewRefusesDifferentAssetOrDraft() throws {
        let originalURL = URL(fileURLWithPath: "/Newsroom/one.jpg")
        let otherURL = URL(fileURLWithPath: "/Newsroom/two.jpg")
        let input = IPTCMetadata(title: "\\name\\", keywords: ["news"])
        let result = coordinator.plan(
            metadata: input,
            list: CodeReplacementParser().parse(Data("name\tAda".utf8)),
            configuration: configuration(),
            compositionState: .committed
        )
        let pending = CaptionCodeReplacementPendingPreview(
            imageURL: originalURL,
            inputMetadata: input,
            result: result
        )

        let validated = try #require(pending.validatedMetadata(
            currentURL: originalURL,
            currentMetadata: input
        ))
        #expect(validated.title == "Ada")
        #expect(pending.validatedMetadata(currentURL: otherURL, currentMetadata: input) == nil)

        var revised = input
        revised.keywords.append("edited-after-preview")
        #expect(pending.validatedMetadata(currentURL: originalURL, currentMetadata: revised) == nil)
        #expect(pending.validatedMetadata(currentURL: nil, currentMetadata: input) == nil)
    }

    @Test("Configuration and opaque bookmark bytes persist in separate keys")
    func settingsPersistenceSeparatesBookmark() async throws {
        let suiteName = "CaptionCodeReplacementCoordinatorTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let sourceURL = URL(fileURLWithPath: "/Newsroom/code-replacements.txt")
        let sourceData = Data("name\tAda Lovelace\r\ncity\tOslo".utf8)
        let bookmarkSecret = Data("BOOKMARK_BYTES_MUST_STAY_SEPARATE".utf8)
        let access = CodeReplacementSourceAccess(
            createBookmark: { _ in bookmarkSecret },
            resolveBookmark: { data in
                #expect(data == bookmarkSecret)
                return CodeReplacementBookmarkResolution(url: sourceURL, isStale: false)
            },
            readData: { url in
                #expect(url == sourceURL)
                return sourceData
            }
        )
        let instant = Date(timeIntervalSince1970: 1_800_000_000)
        let store = CodeReplacementSettingsStore(
            defaults: defaults,
            access: access,
            now: { instant }
        )

        store.setEnabled(false)
        store.setStartDelimiter("[[")
        store.setEndDelimiter("]] ")
        try await store.selectSource(sourceURL)

        let configurationData = try #require(defaults.data(
            forKey: UserDefaultsKeys.codeReplacementConfiguration
        ))
        #expect(defaults.data(forKey: UserDefaultsKeys.codeReplacementSourceBookmark) == bookmarkSecret)
        #expect(configurationData != bookmarkSecret)
        #expect(String(decoding: configurationData, as: UTF8.self).contains("BOOKMARK_BYTES") == false)

        let restored = CodeReplacementSettingsStore(
            defaults: defaults,
            access: access,
            now: { instant }
        )
        await restored.waitForPendingSourceOperation()
        #expect(restored.configuration.isEnabled == false)
        #expect(restored.configuration.startDelimiter == "[[")
        #expect(restored.configuration.endDelimiter == "]] ")
        #expect(restored.configuration.source?.path == sourceURL.path)
        #expect(restored.configuration.source?.bookmark?.id != nil)
        #expect(restored.list.entries.map(\.code) == ["name", "city"])
        #expect(restored.sourceLoadError == nil)
    }

    @Test("Missing bookmark permission is visible and cannot produce a usable list")
    func missingBookmarkIsVisible() async throws {
        let suiteName = "CaptionCodeReplacementCoordinatorTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let encoded = try JSONEncoder().encode(configuration())
        defaults.set(encoded, forKey: UserDefaultsKeys.codeReplacementConfiguration)

        let store = CodeReplacementSettingsStore(
            defaults: defaults,
            access: CodeReplacementSourceAccess(
                createBookmark: { _ in Data() },
                resolveBookmark: { _ in throw TestError.unexpectedAccess },
                readData: { _ in throw TestError.unexpectedAccess }
            )
        )
        await store.waitForPendingSourceOperation()

        #expect(store.sourceLoadError != nil)
        #expect(store.list.entries.isEmpty)
    }

    @Test("A stale security-scoped bookmark is refreshed only after the source is readable")
    func staleBookmarkRefreshesAfterRead() async throws {
        let suiteName = "CaptionCodeReplacementStaleBookmarkTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let sourceURL = URL(fileURLWithPath: "/Newsroom/private-stale-codes.txt")
        let oldBookmark = Data("old-bookmark-secret".utf8)
        let refreshedBookmark = Data("refreshed-bookmark-secret".utf8)
        let storedConfiguration = CodeReplacementConfiguration(
            source: CodeReplacementSourceReference(
                displayName: sourceURL.lastPathComponent,
                path: sourceURL.path,
                bookmark: CodeReplacementBookmarkReference(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000099")!,
                    createdAt: Date(timeIntervalSince1970: 1_800_000_000),
                    lastResolvedAt: Date(timeIntervalSince1970: 1_800_000_000),
                    wasStaleWhenLastResolved: false
                )
            )
        )
        defaults.set(
            try JSONEncoder().encode(storedConfiguration),
            forKey: UserDefaultsKeys.codeReplacementConfiguration
        )
        defaults.set(oldBookmark, forKey: UserDefaultsKeys.codeReplacementSourceBookmark)
        let refreshProbe = BookmarkRefreshProbe()

        let store = CodeReplacementSettingsStore(
            defaults: defaults,
            access: CodeReplacementSourceAccess(
                createBookmark: { url in
                    #expect(url == sourceURL)
                    refreshProbe.recordRefresh()
                    return refreshedBookmark
                },
                resolveBookmark: { data in
                    #expect(data == oldBookmark)
                    return CodeReplacementBookmarkResolution(url: sourceURL, isStale: true)
                },
                readData: { url in
                    #expect(url == sourceURL)
                    return Data("desk\tWire".utf8)
                }
            ),
            now: { Date(timeIntervalSince1970: 1_900_000_000) }
        )
        await store.waitForPendingSourceOperation()

        #expect(store.sourceLoadError == nil)
        #expect(store.list.entries.map(\.code) == ["desk"])
        #expect(store.configuration.source?.bookmark?.wasStaleWhenLastResolved == true)
        #expect(defaults.data(forKey: UserDefaultsKeys.codeReplacementSourceBookmark)
            == refreshedBookmark)
        #expect(refreshProbe.refreshCount == 1)
    }

    @Test(
        "Denied bookmark resolution or source read fails closed with a sanitized message",
        arguments: [BookmarkAccessFailure.resolutionDenied, .readDenied]
    )
    private func deniedBookmarkAccessIsSanitized(failure: BookmarkAccessFailure) async throws {
        let suiteName = "CaptionCodeReplacementDeniedBookmarkTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let sourceURL = URL(fileURLWithPath: "/Newsroom/private-denied-codes.txt")
        let bookmark = Data("bookmark-credential-secret".utf8)
        defaults.set(try JSONEncoder().encode(configuration()), forKey: UserDefaultsKeys.codeReplacementConfiguration)
        defaults.set(bookmark, forKey: UserDefaultsKeys.codeReplacementSourceBookmark)

        let store = CodeReplacementSettingsStore(
            defaults: defaults,
            access: CodeReplacementSourceAccess(
                createBookmark: { _ in bookmark },
                resolveBookmark: { _ in
                    if failure == .resolutionDenied {
                        throw BookmarkEnvironmentalFailure()
                    }
                    return CodeReplacementBookmarkResolution(url: sourceURL, isStale: false)
                },
                readData: { _ in
                    if failure == .readDenied {
                        throw BookmarkEnvironmentalFailure()
                    }
                    return Data("desk\tWire".utf8)
                }
            )
        )
        await store.waitForPendingSourceOperation()

        #expect(store.list.entries.isEmpty)
        let message = try #require(store.sourceLoadError).lowercased()
        #expect(message.contains("choose the file again"))
        #expect(!message.contains("bookmark-credential-secret"))
        #expect(!message.contains("/newsroom/"))
        #expect(!message.contains("account-token-secret"))
        #expect(defaults.data(forKey: UserDefaultsKeys.codeReplacementSourceBookmark) == bookmark)
    }

    private func configuration(startDelimiter: String = "\\") -> CodeReplacementConfiguration {
        CodeReplacementConfiguration(
            startDelimiter: startDelimiter,
            endDelimiter: "\\",
            source: CodeReplacementSourceReference(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000021")!,
                displayName: "codes.txt"
            )
        )
    }
}

nonisolated private enum TestError: Error {
    case unexpectedAccess
}

nonisolated private enum BookmarkAccessFailure: Sendable {
    case resolutionDenied
    case readDenied
}

nonisolated private struct BookmarkEnvironmentalFailure: LocalizedError {
    let errorDescription: String? =
        "Denied /Newsroom/private-denied-codes.txt with account-token-secret"
}

nonisolated private final class BookmarkRefreshProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var refreshCount: Int {
        lock.withLock { count }
    }

    func recordRefresh() {
        lock.withLock { count += 1 }
    }
}
