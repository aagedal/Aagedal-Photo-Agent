import CoreGraphics
import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Image memory coordinator")
struct ImageMemoryCoordinatorTests {
    private let mebibyte = 1_024 * 1_024

    @Test("cache shares stay within one hardware-scaled process budget")
    func sharedBudgetIsBoundedAndScaled() {
        let fourGiB = ImageMemoryCoordinator(
            availableMemory: { 4 * 1_024 * 1_024 * 1_024 },
            observesSystemPressure: false
        ).policy()
        let thirtyTwoGiB = ImageMemoryCoordinator(
            availableMemory: { 32 * 1_024 * 1_024 * 1_024 },
            observesSystemPressure: false
        ).policy()

        #expect(fourGiB.totalBudget == 512 * mebibyte)
        #expect(thirtyTwoGiB.totalBudget == 1_024 * mebibyte)
        #expect(sumOfCacheLimits(fourGiB) == fourGiB.totalBudget)
        #expect(sumOfCacheLimits(thirtyTwoGiB) == thirtyTwoGiB.totalBudget)
    }

    @Test("large full-resolution sources reduce limits and disable speculative GPU prefetch")
    func sourceDimensionsAdaptPolicy() {
        let coordinator = ImageMemoryCoordinator(
            availableMemory: { 8 * 1_024 * 1_024 * 1_024 },
            observesSystemPressure: false
        )
        let small = CGSize(width: 1_000, height: 1_000)
        let fortyEightMP = CGSize(width: 8_000, height: 6_000)

        let smallLimit = coordinator.adaptiveLimit(
            for: .developSpeculative,
            sourcePixelSize: small,
            bytesPerPixel: 8
        )
        let largeLimit = coordinator.adaptiveLimit(
            for: .developSpeculative,
            sourcePixelSize: fortyEightMP,
            bytesPerPixel: 8
        )
        let smallPrefetch = coordinator.prefetchItemLimit(
            for: .developSpeculative,
            sourcePixelSize: small,
            bytesPerPixel: 8,
            maximum: 2
        )
        let largePrefetch = coordinator.prefetchItemLimit(
            for: .developSpeculative,
            sourcePixelSize: fortyEightMP,
            bytesPerPixel: 8,
            maximum: 2
        )

        #expect(largeLimit < smallLimit)
        #expect(smallPrefetch == 2)
        #expect(largePrefetch == 0)
    }

    @Test("multiple caches of one kind divide rather than duplicate their share")
    func duplicateParticipantsDivideShare() {
        let coordinator = ImageMemoryCoordinator(
            availableMemory: { 8 * 1_024 * 1_024 * 1_024 },
            observesSystemPressure: false
        )
        let limits = IntegerRecorder()
        let first = coordinator.register(
            kind: .developSpeculative,
            applyLimit: { limits.setFirst($0) },
            evict: {}
        )
        let second = coordinator.register(
            kind: .developSpeculative,
            applyLimit: { limits.setSecond($0) },
            evict: {}
        )
        _ = [first, second]

        let share = coordinator.policy().developSpeculativeLimit
        #expect(limits.first == share / 2)
        #expect(limits.second == share / 2)
    }

    @Test("warning pressure cancels work before ordered low-cost eviction")
    func warningPressureOrder() throws {
        let coordinator = ImageMemoryCoordinator(
            availableMemory: { 8 * 1_024 * 1_024 * 1_024 },
            observesSystemPressure: false
        )
        let recorder = EventRecorder()
        let registrations = registerAllKinds(with: coordinator, recorder: recorder)
        _ = registrations
        recorder.reset()

        coordinator.handleMemoryPressure(.warning)
        let events = recorder.events
        let firstEviction = try #require(events.firstIndex(where: { $0.hasPrefix("evict-") }))

        #expect(events[..<firstEviction].allSatisfy { $0.hasPrefix("cancel-") })
        #expect(Array(events[firstEviction...]) == [
            "evict-developSpeculative",
            "evict-scope",
            "evict-fullScreenPreview",
        ])
    }

    @Test("critical pressure follows the complete documented eviction order")
    func criticalPressureOrder() throws {
        let coordinator = ImageMemoryCoordinator(
            availableMemory: { 8 * 1_024 * 1_024 * 1_024 },
            observesSystemPressure: false
        )
        let recorder = EventRecorder()
        let registrations = registerAllKinds(with: coordinator, recorder: recorder)
        _ = registrations
        recorder.reset()

        coordinator.handleMemoryPressure(.critical)
        let evictions = recorder.events.filter { $0.hasPrefix("evict-") }

        #expect(evictions == [
            "evict-developSpeculative",
            "evict-scope",
            "evict-fullScreenPreview",
            "evict-thumbnail",
            "evict-fullScreenPrimary",
        ])
    }

    private func sumOfCacheLimits(_ policy: ImageMemoryCoordinator.Policy) -> Int {
        policy.fullScreenPrimaryLimit
            + policy.fullScreenPreviewLimit
            + policy.thumbnailLimit
            + policy.scopeLimit
            + policy.developSpeculativeLimit
    }

    private func registerAllKinds(
        with coordinator: ImageMemoryCoordinator,
        recorder: EventRecorder
    ) -> [ImageMemoryCoordinator.Registration] {
        ImageMemoryCoordinator.CacheKind.allCases.map { kind in
            coordinator.register(
                kind: kind,
                cancelSpeculativeWork: {
                    recorder.append("cancel-\(kind)")
                },
                applyLimit: { _ in },
                evict: {
                    recorder.append("evict-\(kind)")
                }
            )
        }
    }
}

nonisolated private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var events: [String] {
        lock.withLock { storage }
    }

    func append(_ event: String) {
        lock.withLock { storage.append(event) }
    }

    func reset() {
        lock.withLock { storage.removeAll() }
    }
}

nonisolated private final class IntegerRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var firstStorage = 0
    private var secondStorage = 0

    var first: Int { lock.withLock { firstStorage } }
    var second: Int { lock.withLock { secondStorage } }

    func setFirst(_ value: Int) { lock.withLock { firstStorage = value } }
    func setSecond(_ value: Int) { lock.withLock { secondStorage = value } }
}
