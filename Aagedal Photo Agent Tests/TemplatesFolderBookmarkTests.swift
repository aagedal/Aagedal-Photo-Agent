import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@MainActor
@Suite("Templates folder bookmarks", .serialized)
struct TemplatesFolderBookmarkTests {
    @Test("Stale bookmark resolution and refresh run away from MainActor")
    func staleResolutionRunsOffMainActor() async throws {
        let recorder = TemplatesFolderBookmarkRecorder()
        let originalData = Data([0x31])
        let refreshedData = Data([0x32])
        let movedURL = URL(
            fileURLWithPath: "/tmp/photo-agent-templates/moved",
            isDirectory: true
        )
        let service = TemplatesFolderBookmarkService(access: TemplatesFolderBookmarkAccess(
            resolve: { data in
                recorder.record(.resolve, url: nil)
                #expect(data == originalData)
                return TemplatesFolderBookmarkResolution(url: movedURL, isStale: true)
            },
            startAccessing: { url in
                recorder.record(.start, url: url)
                return true
            },
            stopAccessing: { url in
                recorder.record(.stop, url: url)
            },
            create: { url in
                recorder.record(.create, url: url)
                return refreshedData
            }
        ))
        let requestID = UUID()

        let result = await service.resolve(originalData, requestID: requestID)

        #expect(result == .loaded(TemplatesFolderBookmarkSnapshot(
            requestID: requestID,
            url: movedURL,
            refreshedBookmarkData: refreshedData
        )))
        #expect(recorder.operations == [.resolve, .start, .create, .stop])
        #expect(recorder.urls == [movedURL, movedURL, movedURL])
        #expect(recorder.observedMainThread == [false, false, false, false])
    }

    @Test("Settings publishes and persists only the completed bookmark request")
    func settingsPublishesCompletedBookmarkWork() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let recorder = TemplatesFolderBookmarkRecorder()
        let staleData = Data([0x41])
        let refreshedData = Data([0x42])
        let selectedData = Data([0x43])
        let restoredURL = URL(
            fileURLWithPath: "/tmp/photo-agent-templates/restored",
            isDirectory: true
        )
        let selectedURL = URL(
            fileURLWithPath: "/tmp/photo-agent-templates/selected",
            isDirectory: true
        )
        defaults.set(staleData, forKey: UserDefaultsKeys.templatesFolderBookmark)
        let service = TemplatesFolderBookmarkService(access: TemplatesFolderBookmarkAccess(
            resolve: { _ in
                recorder.record(.resolve, url: nil)
                return TemplatesFolderBookmarkResolution(url: restoredURL, isStale: true)
            },
            startAccessing: { url in
                recorder.record(.start, url: url)
                return true
            },
            stopAccessing: { url in
                recorder.record(.stop, url: url)
            },
            create: { url in
                recorder.record(.create, url: url)
                return url == restoredURL ? refreshedData : selectedData
            }
        ))
        let viewModel = SettingsViewModel(
            templatesFolderDefaults: defaults,
            templatesFolderBookmarkService: service
        )

        await viewModel.loadTemplatesFolderBookmark()

        #expect(viewModel.templatesFolderPath == restoredURL.path)
        #expect(defaults.data(forKey: UserDefaultsKeys.templatesFolderBookmark) == refreshedData)

        await viewModel.setTemplatesFolderURL(selectedURL)

        #expect(viewModel.templatesFolderPath == selectedURL.path)
        #expect(defaults.data(forKey: UserDefaultsKeys.templatesFolderBookmark) == selectedData)
        #expect(recorder.observedMainThread.allSatisfy { !$0 })

        viewModel.clearTemplatesFolder()
        #expect(viewModel.templatesFolderPath.isEmpty)
        #expect(defaults.data(forKey: UserDefaultsKeys.templatesFolderBookmark) == nil)
    }

    @Test("Cancellation before resolution performs no bookmark access")
    func preCancelledResolutionPerformsNoAccess() async {
        let recorder = TemplatesFolderBookmarkRecorder()
        let service = TemplatesFolderBookmarkService(
            access: TemplatesFolderBookmarkAccess(
                resolve: { _ in
                    recorder.record(.resolve, url: nil)
                    return TemplatesFolderBookmarkResolution(
                        url: URL(fileURLWithPath: "/tmp/unexpected"),
                        isStale: false
                    )
                }
            ),
            cancellationRequested: { true }
        )
        let requestID = UUID()

        let result = await service.resolve(Data([0x51]), requestID: requestID)

        #expect(result == .cancelledBeforeAccess(requestID: requestID))
        #expect(recorder.operations.isEmpty)
    }

    @Test("Cancellation after a synchronous bookmark call is explicit")
    func postAccessCancellationIsExplicit() async {
        let resolutionRecorder = TemplatesFolderBookmarkRecorder()
        let resolutionCancellation = TemplatesFolderCancellationSequence([false, true])
        let resolvedURL = URL(fileURLWithPath: "/tmp/post-access-resolution", isDirectory: true)
        let resolutionService = TemplatesFolderBookmarkService(
            access: TemplatesFolderBookmarkAccess(resolve: { _ in
                resolutionRecorder.record(.resolve, url: nil)
                return TemplatesFolderBookmarkResolution(url: resolvedURL, isStale: false)
            }),
            cancellationRequested: resolutionCancellation.next
        )
        let resolutionRequestID = UUID()

        let resolutionResult = await resolutionService.resolve(
            Data([0x61]),
            requestID: resolutionRequestID
        )

        #expect(resolutionResult == .cancelledAfterAccess(requestID: resolutionRequestID))
        #expect(resolutionRecorder.operations == [.resolve])

        let creationCancellation = TemplatesFolderCancellationSequence([false, true])
        let bookmarkData = Data([0x62])
        let creationService = TemplatesFolderBookmarkService(
            access: TemplatesFolderBookmarkAccess(create: { _ in bookmarkData }),
            cancellationRequested: creationCancellation.next
        )
        let creationRequestID = UUID()

        let creationResult = await creationService.createBookmark(
            for: resolvedURL,
            requestID: creationRequestID
        )

        #expect(creationResult == .completed(TemplatesFolderBookmarkCommit(
            requestID: creationRequestID,
            bookmarkData: bookmarkData,
            cancellationRequestedAfterAccess: true
        )))
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "TemplatesFolderBookmarkTests.\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suiteName)), suiteName)
    }
}

nonisolated private enum TemplatesFolderBookmarkOperation: Sendable, Equatable {
    case resolve
    case start
    case stop
    case create
}

nonisolated private final class TemplatesFolderBookmarkRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var operationStorage: [TemplatesFolderBookmarkOperation] = []
    private var urlStorage: [URL] = []
    private var threadStorage: [Bool] = []

    var operations: [TemplatesFolderBookmarkOperation] {
        lock.withLock { operationStorage }
    }

    var urls: [URL] {
        lock.withLock { urlStorage }
    }

    var observedMainThread: [Bool] {
        lock.withLock { threadStorage }
    }

    func record(_ operation: TemplatesFolderBookmarkOperation, url: URL?) {
        lock.withLock {
            operationStorage.append(operation)
            if let url {
                urlStorage.append(url)
            }
            threadStorage.append(Thread.isMainThread)
        }
    }
}

nonisolated private final class TemplatesFolderCancellationSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool]

    init(_ values: [Bool]) {
        self.values = values
    }

    func next() -> Bool {
        lock.withLock {
            values.isEmpty ? false : values.removeFirst()
        }
    }
}
