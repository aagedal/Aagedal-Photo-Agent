import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("iCloud sync coordinator")
struct ICloudSyncCoordinatorTests {
    @Test("background preferences notifications return while MainActor is occupied")
    @MainActor
    func backgroundPreferenceNotificationDoesNotWaitForMainActor() async {
        let returned = DispatchSemaphore(value: 0)
        let handled = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            PreferencesSyncService.deliverNotification {
                MainActor.assertIsolated()
                handled.signal()
            }
            returned.signal()
        }
        // Model ImageIO holding its RAW initialization lock while posting defaults.
        // The poster must return even when this actor cannot execute its callback.
        #expect(Self.waitForNotificationSignal(returned))
        let delivered = await Task.detached {
            Self.waitForNotificationSignal(handled)
        }.value
        #expect(delivered)
    }

    // Deliberately occupy the actor to reproduce the decoder lock/notification cycle.
    // Keep this synchronous helper bounded so a regression fails instead of hanging tests.
    nonisolated private static func waitForNotificationSignal(_ signal: DispatchSemaphore) -> Bool {
        signal.wait(timeout: .now() + 2) == .success
    }

    @Test("main-thread preferences notifications preserve synchronous echo suppression")
    @MainActor
    func mainPreferenceNotificationStaysInline() {
        let handled = DispatchSemaphore(value: 0)
        PreferencesSyncService.deliverNotification { handled.signal() }
        #expect(handled.wait(timeout: .now()) == .success)
    }

    @Test("master sync includes every user-facing category")
    func masterCategoryCoverage() {
        #expect(ICloudSyncCoordinator.masterCategories == [
            .preferences,
            .keywordLists,
            .templates,
            .knownPeople,
            .teams,
            .watermarks,
        ])
    }

    @Test("iCloud availability resolution runs off MainActor and returns immutable state")
    @MainActor
    func iCloudAvailabilityRunsOffMainActor() async {
        let availableProbe = ICloudAvailabilityThreadProbe(available: true)
        let availableService = ICloudAvailabilityProbeService(
            resolveAvailability: availableProbe.resolve
        )
        let unavailableProbe = ICloudAvailabilityThreadProbe(available: false)
        let unavailableService = ICloudAvailabilityProbeService(
            resolveAvailability: unavailableProbe.resolve
        )

        let available = await availableService.probe()
        let unavailable = await unavailableService.probe()

        #expect(available == .available)
        #expect(unavailable == .unavailable)
        #expect(availableProbe.callCount == 1)
        #expect(unavailableProbe.callCount == 1)
        #expect(!availableProbe.ranOnMainThread)
        #expect(!unavailableProbe.ranOnMainThread)
    }

    @Test("iCloud availability distinguishes cancellation around container resolution")
    func iCloudAvailabilityCancellationEvidence() async {
        let preCancelledProbe = ICloudAvailabilityThreadProbe(available: true)
        let preCancelledService = ICloudAvailabilityProbeService(
            resolveAvailability: preCancelledProbe.resolve
        )
        let preCancelled = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await preCancelledService.probe()
        }.value

        #expect(preCancelled == .cancelledBeforeResolution)
        #expect(preCancelledProbe.callCount == 0)

        let postCancelledProbe = ICloudAvailabilityThreadProbe(
            available: true,
            cancelDuringResolution: true
        )
        let postCancelledService = ICloudAvailabilityProbeService(
            resolveAvailability: postCancelledProbe.resolve
        )
        let postCancelled = await Task {
            await postCancelledService.probe()
        }.value

        #expect(postCancelled == .cancelledAfterResolution(wasAvailable: true))
        #expect(postCancelledProbe.callCount == 1)
    }

    @Test("Preferences sync commits only after current availability evidence")
    @MainActor
    func preferencesSyncWaitsForAvailability() async {
        let availablePreferences = PreferencesSyncControllerProbe()
        let availableCoordinator = ICloudSyncCoordinator(
            availabilityProbe: ICloudAvailabilityProbeService(resolveAvailability: { true }),
            preferencesSync: availablePreferences
        )

        availableCoordinator.setPreferencesEnabled(true)
        await waitForAvailabilityPublication(in: availableCoordinator)

        #expect(availableCoordinator.iCloudAvailability == .available)
        #expect(availableCoordinator.preferencesEnabled)
        #expect(availablePreferences.setValues == [true])
        #expect(availableCoordinator.lastError == nil)

        let unavailablePreferences = PreferencesSyncControllerProbe()
        let unavailableCoordinator = ICloudSyncCoordinator(
            availabilityProbe: ICloudAvailabilityProbeService(resolveAvailability: { false }),
            preferencesSync: unavailablePreferences
        )

        unavailableCoordinator.setPreferencesEnabled(true)
        await waitForAvailabilityPublication(in: unavailableCoordinator)

        #expect(unavailableCoordinator.iCloudAvailability == .unavailable)
        #expect(!unavailableCoordinator.preferencesEnabled)
        #expect(unavailablePreferences.setValues.isEmpty)
        #expect(unavailableCoordinator.lastError != nil)
    }

    @Test("keyword-list routing resolves and merges off MainActor in both directions")
    @MainActor
    func keywordListRoutingRunsOffMainActor() async throws {
        let local = URL(fileURLWithPath: "/virtual/local-lists", isDirectory: true)
        let cloud = URL(fileURLWithPath: "/virtual/cloud-lists", isDirectory: true)
        let probe = KeywordListsRoutingProbe(local: local, cloud: cloud)
        let service = KeywordListsRoutingService(access: probe.fileAccess)
        let enableID = UUID()
        let disableID = UUID()

        let enable = try await service.reconcile(enabled: true, requestID: enableID)
        let disable = try await service.reconcile(enabled: false, requestID: disableID)

        #expect(enable == .committed(KeywordListsRoutingCommit(
            requestID: enableID,
            enabled: true,
            sourceURL: local,
            destinationURL: cloud,
            performedMerge: true,
            cancellationRequestedAfterCommit: false
        )))
        #expect(disable == .committed(KeywordListsRoutingCommit(
            requestID: disableID,
            enabled: false,
            sourceURL: cloud,
            destinationURL: local,
            performedMerge: true,
            cancellationRequestedAfterCommit: false
        )))
        let merges = probe.merges
        #expect(merges.count == 2)
        #expect(merges[0].0 == local)
        #expect(merges[0].1 == cloud)
        #expect(merges[1].0 == cloud)
        #expect(merges[1].1 == local)
        #expect(!probe.ranOnMainThread)
    }

    @Test("keyword-list routing reports unavailable without entering the merger")
    func keywordListRoutingUnavailable() async throws {
        let probe = KeywordListsRoutingProbe(
            local: URL(fileURLWithPath: "/virtual/local"),
            cloud: nil
        )
        let service = KeywordListsRoutingService(access: probe.fileAccess)
        let requestID = UUID()

        let result = try await service.reconcile(enabled: true, requestID: requestID)

        #expect(result == .unavailable(requestID: requestID, enabled: true))
        #expect(probe.merges.isEmpty)
    }

    @Test("turning keyword-list sync off remains available without an iCloud container")
    func keywordListRoutingDisableWithoutCloud() async throws {
        let local = URL(fileURLWithPath: "/virtual/local")
        let probe = KeywordListsRoutingProbe(local: local, cloud: nil)
        let service = KeywordListsRoutingService(access: probe.fileAccess)
        let requestID = UUID()

        let result = try await service.reconcile(enabled: false, requestID: requestID)

        #expect(result == .committed(KeywordListsRoutingCommit(
            requestID: requestID,
            enabled: false,
            sourceURL: local,
            destinationURL: local,
            performedMerge: false,
            cancellationRequestedAfterCommit: false
        )))
        #expect(probe.merges.isEmpty)
    }

    @Test("keyword-list routing returns durable evidence when cancellation arrives during merge")
    func keywordListRoutingDurableCancellation() async throws {
        let local = URL(fileURLWithPath: "/virtual/local")
        let cloud = URL(fileURLWithPath: "/virtual/cloud")
        let probe = KeywordListsRoutingProbe(
            local: local,
            cloud: cloud,
            cancelDuringMerge: true
        )
        let service = KeywordListsRoutingService(access: probe.fileAccess)
        let requestID = UUID()

        let result = try await Task {
            try await service.reconcile(enabled: true, requestID: requestID)
        }.value

        #expect(result == .committed(KeywordListsRoutingCommit(
            requestID: requestID,
            enabled: true,
            sourceURL: local,
            destinationURL: cloud,
            performedMerge: true,
            cancellationRequestedAfterCommit: true
        )))
    }

    @Test("Templates iCloud routing balances security scope off MainActor in both directions")
    @MainActor
    func templateRoutingRunsOffMainActorAndBalancesScope() async throws {
        let local = URL(fileURLWithPath: "/virtual/local-templates", isDirectory: true)
        let cloud = URL(fileURLWithPath: "/virtual/cloud-templates", isDirectory: true)
        let probe = TemplateICloudRoutingProbe(local: local, cloud: cloud)
        let service = TemplateICloudRoutingService(access: probe.fileAccess)
        let enableID = UUID()
        let disableID = UUID()

        let enable = try await service.reconcile(enabled: true, requestID: enableID)
        let disable = try await service.reconcile(enabled: false, requestID: disableID)

        #expect(enable == .committed(TemplateICloudRoutingCommit(
            requestID: enableID,
            enabled: true,
            localRootURL: local,
            cloudRootURL: cloud,
            sourceURL: local,
            destinationURL: cloud,
            cancellationRequestedAfterCommit: false
        )))
        #expect(disable == .committed(TemplateICloudRoutingCommit(
            requestID: disableID,
            enabled: false,
            localRootURL: local,
            cloudRootURL: cloud,
            sourceURL: cloud,
            destinationURL: local,
            cancellationRequestedAfterCommit: false
        )))
        #expect(probe.merges.map(\.0) == [local, cloud])
        #expect(probe.merges.map(\.1) == [cloud, local])
        #expect(probe.localResolutions == 2)
        #expect(probe.releases == 2)
        #expect(!probe.ranOnMainThread)
    }

    @Test("Templates routing balances security scope for unavailable and cancelled work")
    func templateRoutingBalancesScopeWithoutCommit() async throws {
        let local = URL(fileURLWithPath: "/virtual/local-templates")
        let unavailableProbe = TemplateICloudRoutingProbe(local: local, cloud: nil)
        let unavailableService = TemplateICloudRoutingService(access: unavailableProbe.fileAccess)
        let unavailableID = UUID()

        let unavailable = try await unavailableService.reconcile(
            enabled: true,
            requestID: unavailableID
        )

        #expect(unavailable == .unavailable(requestID: unavailableID, enabled: true))
        #expect(unavailableProbe.merges.isEmpty)
        #expect(unavailableProbe.releases == 1)

        let cloud = URL(fileURLWithPath: "/virtual/cloud-templates")
        let cancelledProbe = TemplateICloudRoutingProbe(
            local: local,
            cloud: cloud,
            cancelDuringResolution: true
        )
        let cancelledService = TemplateICloudRoutingService(access: cancelledProbe.fileAccess)
        let cancelledID = UUID()

        let cancelled = try await Task {
            try await cancelledService.reconcile(enabled: false, requestID: cancelledID)
        }.value

        #expect(cancelled == .cancelledBeforeCommit(requestID: cancelledID, enabled: false))
        #expect(cancelledProbe.merges.isEmpty)
        #expect(cancelledProbe.releases == 1)
    }

    @Test("Templates routing releases security scope after a durable cancelled merge or error")
    func templateRoutingBalancesScopeAfterMerge() async throws {
        let local = URL(fileURLWithPath: "/virtual/local-templates")
        let cloud = URL(fileURLWithPath: "/virtual/cloud-templates")
        let cancelledProbe = TemplateICloudRoutingProbe(
            local: local,
            cloud: cloud,
            cancelDuringMerge: true
        )
        let cancelledService = TemplateICloudRoutingService(access: cancelledProbe.fileAccess)
        let cancelledID = UUID()

        let cancelled = try await Task {
            try await cancelledService.reconcile(enabled: true, requestID: cancelledID)
        }.value

        #expect(cancelled == .committed(TemplateICloudRoutingCommit(
            requestID: cancelledID,
            enabled: true,
            localRootURL: local,
            cloudRootURL: cloud,
            sourceURL: local,
            destinationURL: cloud,
            cancellationRequestedAfterCommit: true
        )))
        #expect(cancelledProbe.releases == 1)

        let failingProbe = TemplateICloudRoutingProbe(
            local: local,
            cloud: cloud,
            mergeError: TemplateICloudRoutingProbe.ProbeError.mergeFailed
        )
        let failingService = TemplateICloudRoutingService(access: failingProbe.fileAccess)

        await #expect(throws: TemplateICloudRoutingProbe.ProbeError.mergeFailed) {
            try await failingService.reconcile(enabled: false, requestID: UUID())
        }
        #expect(failingProbe.releases == 1)
    }

    @Test("Known People iCloud routing resolves and merges off MainActor in both directions")
    @MainActor
    func knownPeopleRoutingRunsOffMainActor() async throws {
        let local = URL(fileURLWithPath: "/virtual/local-known-people", isDirectory: true)
        let cloud = URL(fileURLWithPath: "/virtual/cloud-known-people", isDirectory: true)
        let probe = KnownPeopleICloudRoutingProbe(local: local, cloud: cloud)
        let service = KnownPeopleICloudRoutingService(access: probe.fileAccess)
        let enableID = UUID()
        let disableID = UUID()

        let enable = try await service.reconcile(enabled: true, requestID: enableID)
        let disable = try await service.reconcile(enabled: false, requestID: disableID)

        #expect(enable == .committed(KnownPeopleICloudRoutingCommit(
            requestID: enableID,
            enabled: true,
            localRootURL: local,
            cloudRootURL: cloud,
            sourceURL: local,
            destinationURL: cloud,
            cancellationRequestedAfterCommit: false
        )))
        #expect(disable == .committed(KnownPeopleICloudRoutingCommit(
            requestID: disableID,
            enabled: false,
            localRootURL: local,
            cloudRootURL: cloud,
            sourceURL: cloud,
            destinationURL: local,
            cancellationRequestedAfterCommit: false
        )))
        #expect(probe.merges.map(\.0) == [local, cloud])
        #expect(probe.merges.map(\.1) == [cloud, local])
        #expect(!probe.ranOnMainThread)
    }

    @Test("Known People routing reports unavailable before entering the recursive merger")
    func knownPeopleRoutingUnavailable() async throws {
        let probe = KnownPeopleICloudRoutingProbe(
            local: URL(fileURLWithPath: "/virtual/local-known-people"),
            cloud: nil
        )
        let service = KnownPeopleICloudRoutingService(access: probe.fileAccess)
        let requestID = UUID()

        let result = try await service.reconcile(enabled: true, requestID: requestID)

        #expect(result == .unavailable(requestID: requestID, enabled: true))
        #expect(probe.merges.isEmpty)
    }

    @Test("Known People routing distinguishes pre-commit cancellation from a durable merge")
    func knownPeopleRoutingCancellationEvidence() async throws {
        let local = URL(fileURLWithPath: "/virtual/local-known-people")
        let cloud = URL(fileURLWithPath: "/virtual/cloud-known-people")
        let beforeProbe = KnownPeopleICloudRoutingProbe(
            local: local,
            cloud: cloud,
            cancelDuringResolution: true
        )
        let beforeService = KnownPeopleICloudRoutingService(access: beforeProbe.fileAccess)
        let beforeID = UUID()

        let before = try await Task {
            try await beforeService.reconcile(enabled: true, requestID: beforeID)
        }.value

        #expect(before == .cancelledBeforeCommit(requestID: beforeID, enabled: true))
        #expect(beforeProbe.merges.isEmpty)

        let afterProbe = KnownPeopleICloudRoutingProbe(
            local: local,
            cloud: cloud,
            cancelDuringMerge: true
        )
        let afterService = KnownPeopleICloudRoutingService(access: afterProbe.fileAccess)
        let afterID = UUID()

        let after = try await Task {
            try await afterService.reconcile(enabled: false, requestID: afterID)
        }.value

        #expect(after == .committed(KnownPeopleICloudRoutingCommit(
            requestID: afterID,
            enabled: false,
            localRootURL: local,
            cloudRootURL: cloud,
            sourceURL: cloud,
            destinationURL: local,
            cancellationRequestedAfterCommit: true
        )))
    }

    @Test("library iCloud routing resolves and merges off MainActor in both directions")
    @MainActor
    func libraryRoutingRunsOffMainActor() async throws {
        let local = URL(fileURLWithPath: "/virtual/local-library", isDirectory: true)
        let cloud = URL(fileURLWithPath: "/virtual/cloud-library", isDirectory: true)
        let probe = LibraryICloudRoutingProbe(local: local, cloud: cloud)
        let service = LibraryICloudRoutingService(access: probe.fileAccess)
        let enableID = UUID()
        let disableID = UUID()

        let enable = try await service.reconcile(enabled: true, requestID: enableID)
        let disable = try await service.reconcile(enabled: false, requestID: disableID)

        #expect(enable == .committed(LibraryICloudRoutingCommit(
            requestID: enableID,
            enabled: true,
            localRootURL: local,
            cloudRootURL: cloud,
            sourceURL: local,
            destinationURL: cloud,
            cancellationRequestedAfterCommit: false
        )))
        #expect(disable == .committed(LibraryICloudRoutingCommit(
            requestID: disableID,
            enabled: false,
            localRootURL: local,
            cloudRootURL: cloud,
            sourceURL: cloud,
            destinationURL: local,
            cancellationRequestedAfterCommit: false
        )))
        #expect(probe.merges.map(\.0) == [local, cloud])
        #expect(probe.merges.map(\.1) == [cloud, local])
        #expect(!probe.ranOnMainThread)
    }

    @Test("library routing reports unavailable and distinguishes durable cancellation")
    func libraryRoutingFailureEvidence() async throws {
        let local = URL(fileURLWithPath: "/virtual/local-library")
        let unavailableProbe = LibraryICloudRoutingProbe(local: local, cloud: nil)
        let unavailableService = LibraryICloudRoutingService(access: unavailableProbe.fileAccess)
        let unavailableID = UUID()

        let unavailable = try await unavailableService.reconcile(
            enabled: true,
            requestID: unavailableID
        )

        #expect(unavailable == .unavailable(requestID: unavailableID, enabled: true))
        #expect(unavailableProbe.merges.isEmpty)

        let cloud = URL(fileURLWithPath: "/virtual/cloud-library")
        let cancelledProbe = LibraryICloudRoutingProbe(
            local: local,
            cloud: cloud,
            cancelDuringMerge: true
        )
        let cancelledService = LibraryICloudRoutingService(access: cancelledProbe.fileAccess)
        let cancelledID = UUID()

        let cancelled = try await Task {
            try await cancelledService.reconcile(enabled: false, requestID: cancelledID)
        }.value

        #expect(cancelled == .committed(LibraryICloudRoutingCommit(
            requestID: cancelledID,
            enabled: false,
            localRootURL: local,
            cloudRootURL: cloud,
            sourceURL: cloud,
            destinationURL: local,
            cancellationRequestedAfterCommit: true
        )))
    }

    @Test("coordinator starts serialized routing and applies only its latest request")
    func keywordListRoutingSourceContract() throws {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/Services/ICloudSyncCoordinator.swift"
            ),
            encoding: .utf8
        )

        #expect(source.contains("keywordListsRoutingTask?.cancel()"))
        #expect(source.contains("try await KeywordListsRoutingService.shared.reconcile("))
        #expect(source.contains("keywordListsRoutingRequestID == requestID"))
        #expect(source.contains("KeywordListsStore.shared.applyICloudRoutingPreference(on)"))
        #expect(!source.contains("let ok = KeywordListsStore.shared.setICloudEnabled(on)"))
        #expect(source.contains("try await templatesRouting.reconcile("))
        #expect(source.contains("templatesRoutingRequestID == requestID"))
        #expect(source.contains("NotificationCenter.default.post(name: .templatesStorageDidChange"))
        #expect(!source.contains("let (current, release) = AppPaths.localTemplatesDirectory()"))
        #expect(!source.contains("try mergeCopy(from: cloud, to: dest)"))
        #expect(source.contains("try await knownPeopleRouting.reconcile("))
        #expect(source.contains("knownPeopleRoutingRequestID == requestID"))
        #expect(source.contains("resolvedStorageURL: commit.destinationURL"))
        #expect(source.contains("await routingTask.value"))
        #expect(!source.contains("try mergeCopy(from: KnownPeopleService.localKnownPeopleDirectory, to: cloud)"))
        #expect(source.contains("try await teamsRouting.reconcile("))
        #expect(source.contains("teamsRoutingRequestID == requestID"))
        #expect(source.contains("resolvedStorageURL: commit.destinationURL"))
        #expect(source.contains("try await watermarksRouting.reconcile("))
        #expect(source.contains("watermarksRoutingRequestID == requestID"))
        #expect(!source.contains("try mergeCopy(from: RosterStore.localTeamsDirectory, to: cloud)"))
        #expect(!source.contains("try mergeCopy(from: WatermarkStore.localWatermarksDirectory, to: cloud)"))
        #expect(source.contains("let result = await availabilityProbe.probe()"))
        #expect(source.contains("pendingPreferencesEnabled ?? preferencesSync.isEnabled"))
        #expect(!source.contains("AppPaths.iCloudDocuments != nil"))

        let watcherSource = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/Services/KnownPeopleCloudCoordinator.swift"
            ),
            encoding: .utf8
        )
        #expect(watcherSource.contains("guard !Task.isCancelled, let self else { return }"))
        #expect(watcherSource.contains("guard let root = resolvedRoot else { return }"))
        #expect(!watcherSource.contains("AppPaths.iCloudKnownPeopleURL"))

        let rosterWatcherSource = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/Services/RosterCloudCoordinator.swift"
            ),
            encoding: .utf8
        )
        #expect(rosterWatcherSource.contains("let root = resolvedRoot else { return }"))
        #expect(!rosterWatcherSource.contains("AppPaths.iCloudTeamsURL"))

        let watermarkWatcherSource = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/Services/WatermarkCloudCoordinator.swift"
            ),
            encoding: .utf8
        )
        #expect(watermarkWatcherSource.contains("let root = resolvedRoot else { return }"))
        #expect(!watermarkWatcherSource.contains("AppPaths.iCloudWatermarksURL"))

        let settingsSource = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/Views/Settings/SettingsView.swift"
            ),
            encoding: .utf8
        )
        let contentSource = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/ContentView.swift"
            ),
            encoding: .utf8
        )
        #expect(settingsSource.contains("publisher(for: .templatesStorageDidChange)"))
        #expect(settingsSource.contains("ICloudSyncCoordinator.shared.refreshICloudAvailability()"))
        #expect(settingsSource.contains("coordinator.iCloudAvailability == .checking"))
        #expect(contentSource.contains("publisher(for: .templatesStorageDidChange)"))
    }

    @Test("keyword-list routing unions flat lists and preserves an existing structured tree")
    func keywordListRoutingMergePolicy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "KeywordListsRoutingPolicyTests-\(UUID().uuidString)",
            isDirectory: true
        )
        let source = root.appendingPathComponent("source", isDirectory: true)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceQuick = source.appendingPathComponent("quick/keywords.txt")
        let destinationQuick = destination.appendingPathComponent("quick/keywords.txt")
        let sourceStructured = source.appendingPathComponent("structured/keywords.txt")
        let destinationStructured = destination.appendingPathComponent("structured/keywords.txt")
        try FileManager.default.createDirectory(
            at: sourceQuick.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: destinationQuick.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: sourceStructured.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: destinationStructured.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("Local\nShared\n".utf8).write(to: sourceQuick)
        try Data("Cloud\nShared\n".utf8).write(to: destinationQuick)
        try Data("source tree\n".utf8).write(to: sourceStructured)
        try Data("destination tree\n".utf8).write(to: destinationStructured)

        try KeywordListsStore.reconcileTree(from: source, to: destination)

        #expect(try Data(contentsOf: destinationQuick) == Data("Cloud\nShared\nLocal\n".utf8))
        #expect(try Data(contentsOf: destinationStructured) == Data("destination tree\n".utf8))
    }

    @Test("Known People disclosure and iCloud confirmation are versioned independently")
    func knownPeoplePrivacyAcknowledgements() throws {
        let suiteName = "KnownPeoplePrivacyLifecycleTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(!KnownPeoplePrivacyLifecycle.hasAcknowledgedDisclosure(in: defaults))
        #expect(!KnownPeoplePrivacyLifecycle.hasConfirmedICloudTransfer(in: defaults))
        #expect(KnownPeoplePrivacyLifecycle.requiresICloudConfirmation(
            enabling: true,
            currentlyEnabled: false,
            defaults: defaults
        ))
        #expect(!KnownPeoplePrivacyLifecycle.requiresICloudConfirmation(
            enabling: false,
            currentlyEnabled: true,
            defaults: defaults
        ))

        KnownPeoplePrivacyLifecycle.acknowledgeDisclosure(in: defaults)
        #expect(KnownPeoplePrivacyLifecycle.hasAcknowledgedDisclosure(in: defaults))
        #expect(KnownPeoplePrivacyLifecycle.requiresICloudConfirmation(
            enabling: true,
            currentlyEnabled: false,
            defaults: defaults
        ))

        KnownPeoplePrivacyLifecycle.recordICloudTransferConfirmation(in: defaults)
        #expect(KnownPeoplePrivacyLifecycle.hasConfirmedICloudTransfer(in: defaults))
        #expect(!KnownPeoplePrivacyLifecycle.requiresICloudConfirmation(
            enabling: true,
            currentlyEnabled: false,
            defaults: defaults
        ))
    }

    @Test("Known People Data Management summary counts nested storage and reports its destination")
    func knownPeopleDataSummary() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KnownPeopleDataSummaryTests-\(UUID().uuidString)", isDirectory: true)
        let people = root.appendingPathComponent("people", isDirectory: true)
        let thumbnails = root.appendingPathComponent("thumbnails", isDirectory: true)
        try FileManager.default.createDirectory(at: people, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: thumbnails, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data(repeating: 1, count: 7).write(to: people.appendingPathComponent("person.json"))
        try Data(repeating: 2, count: 11).write(to: thumbnails.appendingPathComponent("sample.jpg"))

        let localEvidence = await KnownPeopleDataSummaryService().summarize(
            peopleCount: 3,
            sampleCount: 8,
            storageURL: root,
            syncEnabled: false
        )
        let local = try #require(completeSummary(from: localEvidence))
        #expect(local.peopleCount == 3)
        #expect(local.sampleCount == 8)
        #expect(local.storedBytes == 18)
        #expect(local.storageDestination.contains("This Mac"))

        let cloudEvidence = await KnownPeopleDataSummaryService().summarize(
            peopleCount: 3,
            sampleCount: 8,
            storageURL: root,
            syncEnabled: true
        )
        let cloud = try #require(completeSummary(from: cloudEvidence))
        #expect(cloud.storedBytes == 18)
        #expect(cloud.storageDestination.contains("iCloud Drive"))
    }

    @Test("Known People storage measurement executes away from the main thread")
    @MainActor
    func knownPeopleDataSummaryRunsOffMainThread() async throws {
        let probe = KnownPeopleDataSummaryThreadProbe()
        let service = KnownPeopleDataSummaryService(measureDirectory: probe.measure)

        let evidence = await service.summarize(
            peopleCount: 1,
            sampleCount: 2,
            storageURL: URL(fileURLWithPath: "/simulated-known-people"),
            syncEnabled: false
        )

        let summary = try #require(completeSummary(from: evidence))
        #expect(summary.storedBytes == 23)
        #expect(!probe.ranOnMainThread)
    }

    @Test("Known People storage scans serialize and a cancelled queued request performs no read")
    @MainActor
    func knownPeopleDataSummarySerializesAndCancels() async throws {
        let probe = BlockingKnownPeopleDataSummaryProbe()
        defer { probe.release() }
        let service = KnownPeopleDataSummaryService(measureDirectory: probe.measure)
        let firstURL = URL(fileURLWithPath: "/simulated-known-people/first")
        let cancelledURL = URL(fileURLWithPath: "/simulated-known-people/cancelled")

        let first = Task {
            await service.summarize(
                peopleCount: 1,
                sampleCount: 1,
                storageURL: firstURL,
                syncEnabled: false
            )
        }
        let didBlock = await probe.waitUntilBlocked()
        #expect(didBlock, "The simulated storage measurement did not start within 30 seconds")
        guard didBlock else { return }

        let queued = Task {
            await service.summarize(
                peopleCount: 2,
                sampleCount: 2,
                storageURL: cancelledURL,
                syncEnabled: false
            )
        }
        first.cancel()
        queued.cancel()
        probe.release()

        let firstEvidence = await first.value
        let queuedEvidence = await queued.value
        #expect(firstEvidence == .cancelled)
        #expect(queuedEvidence == .cancelled)
        #expect(probe.urls == [firstURL])
    }

    @Test("Known People settings publishes only the latest complete async summary")
    func knownPeopleDataSummarySourceContract() throws {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settingsSource = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/Views/Settings/SettingsView.swift"
            ),
            encoding: .utf8
        )
        let summarySource = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/Models/KnownPeoplePrivacyLifecycle.swift"
            ),
            encoding: .utf8
        )

        #expect(settingsSource.contains("knownPeopleDataSummaryTask?.cancel()"))
        #expect(settingsSource.contains("await coordinator.knownPeopleStorageSnapshot()"))
        #expect(settingsSource.contains("await KnownPeopleDataSummaryService.shared.summarize("))
        #expect(settingsSource.contains("knownPeopleDataSummaryRequestID == requestID"))
        #expect(settingsSource.contains("if case .complete(let summary) = evidence"))
        #expect(!summarySource.contains("FileManager.default.enumerator"))
        #expect(!summarySource.contains("static func make("))
        #expect(!settingsSource.contains("AppPaths.iCloudKnownPeopleURL ?? KnownPeopleService.localKnownPeopleDirectory"))
    }

    private func completeSummary(
        from evidence: KnownPeopleDataSummaryEvidence
    ) -> KnownPeopleDataSummary? {
        guard case .complete(let summary) = evidence else { return nil }
        return summary
    }

    @MainActor
    private func waitForAvailabilityPublication(
        in coordinator: ICloudSyncCoordinator
    ) async {
        for _ in 0..<100 where coordinator.iCloudAvailability == .checking {
            await Task.yield()
        }
    }


    @Test("store migration preserves a newer destination and accepts a newer source")
    func migrationUsesNewestFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudMergeTests-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceFile = source.appendingPathComponent("record.json")
        let destinationFile = destination.appendingPathComponent("record.json")
        try Data("stale-local".utf8).write(to: sourceFile)
        try Data("new-cloud".utf8).write(to: destinationFile)
        let now = Date()
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-60)], ofItemAtPath: sourceFile.path)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: destinationFile.path)

        try CloudCoordinatedIO.mergeCopyPreservingNewer(from: source, to: destination)
        #expect(try Data(contentsOf: destinationFile) == Data("new-cloud".utf8))

        try Data("newest-local".utf8).write(to: sourceFile)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(60)], ofItemAtPath: sourceFile.path)
        try CloudCoordinatedIO.mergeCopyPreservingNewer(from: source, to: destination)
        #expect(try Data(contentsOf: destinationFile) == Data("newest-local".utf8))
    }
}

nonisolated private final class ICloudAvailabilityThreadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let available: Bool
    private let cancelDuringResolution: Bool
    private var observedMainThread = false
    private var recordedCallCount = 0

    init(available: Bool, cancelDuringResolution: Bool = false) {
        self.available = available
        self.cancelDuringResolution = cancelDuringResolution
    }

    func resolve() -> Bool {
        lock.withLock {
            observedMainThread = observedMainThread || Thread.isMainThread
            recordedCallCount += 1
        }
        if cancelDuringResolution {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        return available
    }

    var callCount: Int { lock.withLock { recordedCallCount } }
    var ranOnMainThread: Bool { lock.withLock { observedMainThread } }
}

@MainActor
private final class PreferencesSyncControllerProbe: PreferencesSyncControlling {
    private(set) var isEnabled = false
    private(set) var setValues: [Bool] = []

    func setEnabled(_ enabled: Bool) -> Bool {
        setValues.append(enabled)
        isEnabled = enabled
        return true
    }
}

nonisolated private final class TemplateICloudRoutingProbe: @unchecked Sendable {
    enum ProbeError: Error, Equatable {
        case mergeFailed
    }

    private let lock = NSLock()
    private let local: URL
    private let cloud: URL?
    private let cancelDuringResolution: Bool
    private let cancelDuringMerge: Bool
    private let mergeError: ProbeError?
    private var observedMainThread = false
    private var recordedMerges: [(URL, URL)] = []
    private var recordedLocalResolutions = 0
    private var recordedReleases = 0

    init(
        local: URL,
        cloud: URL?,
        cancelDuringResolution: Bool = false,
        cancelDuringMerge: Bool = false,
        mergeError: ProbeError? = nil
    ) {
        self.local = local
        self.cloud = cloud
        self.cancelDuringResolution = cancelDuringResolution
        self.cancelDuringMerge = cancelDuringMerge
        self.mergeError = mergeError
    }

    var fileAccess: TemplateICloudRoutingFileAccess {
        TemplateICloudRoutingFileAccess(
            localRoot: { [self] in
                lock.withLock {
                    observedMainThread = observedMainThread || Thread.isMainThread
                    recordedLocalResolutions += 1
                }
                return TemplateICloudLocalRoot(
                    url: local,
                    release: { [self] in
                        lock.withLock {
                            observedMainThread = observedMainThread || Thread.isMainThread
                            recordedReleases += 1
                        }
                    }
                )
            },
            cloudRootURL: { [self] in
                lock.withLock {
                    observedMainThread = observedMainThread || Thread.isMainThread
                }
                if cancelDuringResolution {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
                return cloud
            },
            merge: { [self] source, destination in
                lock.withLock {
                    observedMainThread = observedMainThread || Thread.isMainThread
                    recordedMerges.append((source, destination))
                }
                if cancelDuringMerge {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
                if let mergeError {
                    throw mergeError
                }
            }
        )
    }

    var merges: [(URL, URL)] { lock.withLock { recordedMerges } }
    var localResolutions: Int { lock.withLock { recordedLocalResolutions } }
    var releases: Int { lock.withLock { recordedReleases } }
    var ranOnMainThread: Bool { lock.withLock { observedMainThread } }
}

nonisolated private final class KeywordListsRoutingProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let local: URL
    private let cloud: URL?
    private let cancelDuringMerge: Bool
    private var observedMainThread = false
    private var recordedMerges: [(URL, URL)] = []

    init(local: URL, cloud: URL?, cancelDuringMerge: Bool = false) {
        self.local = local
        self.cloud = cloud
        self.cancelDuringMerge = cancelDuringMerge
    }

    var fileAccess: KeywordListsRoutingFileAccess {
        KeywordListsRoutingFileAccess(
            localRootURL: { [self] in
                recordThread()
                return local
            },
            cloudRootURL: { [self] in
                recordThread()
                return cloud
            },
            merge: { [self] source, destination in
                lock.withLock {
                    observedMainThread = observedMainThread || Thread.isMainThread
                    recordedMerges.append((source, destination))
                }
                if cancelDuringMerge {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        )
    }

    var merges: [(URL, URL)] { lock.withLock { recordedMerges } }
    var ranOnMainThread: Bool { lock.withLock { observedMainThread } }

    private func recordThread() {
        lock.withLock {
            observedMainThread = observedMainThread || Thread.isMainThread
        }
    }
}

nonisolated private final class KnownPeopleICloudRoutingProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let local: URL
    private let cloud: URL?
    private let cancelDuringResolution: Bool
    private let cancelDuringMerge: Bool
    private var observedMainThread = false
    private var recordedMerges: [(URL, URL)] = []

    init(
        local: URL,
        cloud: URL?,
        cancelDuringResolution: Bool = false,
        cancelDuringMerge: Bool = false
    ) {
        self.local = local
        self.cloud = cloud
        self.cancelDuringResolution = cancelDuringResolution
        self.cancelDuringMerge = cancelDuringMerge
    }

    var fileAccess: KnownPeopleICloudRoutingFileAccess {
        KnownPeopleICloudRoutingFileAccess(
            localRootURL: { [self] in
                recordThread()
                return local
            },
            cloudRootURL: { [self] in
                recordThread()
                if cancelDuringResolution {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
                return cloud
            },
            ensureDirectory: { _ in },
            merge: { [self] source, destination in
                lock.withLock {
                    observedMainThread = observedMainThread || Thread.isMainThread
                    recordedMerges.append((source, destination))
                }
                if cancelDuringMerge {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        )
    }

    var merges: [(URL, URL)] { lock.withLock { recordedMerges } }
    var ranOnMainThread: Bool { lock.withLock { observedMainThread } }

    private func recordThread() {
        lock.withLock {
            observedMainThread = observedMainThread || Thread.isMainThread
        }
    }
}

nonisolated private final class LibraryICloudRoutingProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let local: URL
    private let cloud: URL?
    private let cancelDuringMerge: Bool
    private var observedMainThread = false
    private var recordedMerges: [(URL, URL)] = []

    init(local: URL, cloud: URL?, cancelDuringMerge: Bool = false) {
        self.local = local
        self.cloud = cloud
        self.cancelDuringMerge = cancelDuringMerge
    }

    var fileAccess: LibraryICloudRoutingFileAccess {
        LibraryICloudRoutingFileAccess(
            localRootURL: { [self] in
                recordThread()
                return local
            },
            cloudRootURL: { [self] in
                recordThread()
                return cloud
            },
            ensureDirectory: { _ in },
            merge: { [self] source, destination in
                lock.withLock {
                    observedMainThread = observedMainThread || Thread.isMainThread
                    recordedMerges.append((source, destination))
                }
                if cancelDuringMerge {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        )
    }

    var merges: [(URL, URL)] { lock.withLock { recordedMerges } }
    var ranOnMainThread: Bool { lock.withLock { observedMainThread } }

    private func recordThread() {
        lock.withLock {
            observedMainThread = observedMainThread || Thread.isMainThread
        }
    }
}

nonisolated private final class KnownPeopleDataSummaryThreadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var observedMainThread = false

    var ranOnMainThread: Bool {
        lock.withLock { observedMainThread }
    }

    func measure(_ url: URL) -> KnownPeopleDataSummaryService.DirectorySizeEvidence {
        lock.withLock {
            observedMainThread = observedMainThread || Thread.isMainThread
        }
        return .complete(23)
    }
}

nonisolated private final class BlockingKnownPeopleDataSummaryProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private var isBlocked = false
    private var isReleased = false
    private var measuredURLs: [URL] = []

    var urls: [URL] {
        condition.withLock { measuredURLs }
    }

    func measure(_ url: URL) -> KnownPeopleDataSummaryService.DirectorySizeEvidence {
        condition.lock()
        measuredURLs.append(url)
        isBlocked = true
        condition.broadcast()
        while !isReleased {
            condition.wait()
        }
        condition.unlock()
        return .complete(31)
    }

    func waitUntilBlocked(timeout: TimeInterval = 30) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [self] in
                let deadline = Date().addingTimeInterval(timeout)
                condition.lock()
                defer { condition.unlock() }
                while !isBlocked {
                    guard condition.wait(until: deadline) else {
                        continuation.resume(returning: false)
                        return
                    }
                }
                continuation.resume(returning: true)
            }
        }
    }

    func release() {
        condition.withLock {
            isReleased = true
            condition.broadcast()
        }
    }
}
