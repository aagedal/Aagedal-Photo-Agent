import Foundation

/// A serial executor backed by one dedicated thread with a large stack.
///
/// Batch capture and admission keep every photo's anchored snapshot open by recursing once per
/// photo through `withPhotoSnapshot`, so their stack grows with the batch. Dispatch queues and
/// Swift's cooperative threads have 512 KB stacks: the eight-photo batch fits locally with less
/// than 2x headroom (it crashes at 256 KB) and crashed CI with SIGBUS. Actors that run that work
/// use this executor instead; jobs keep their task, so cancellation and task-locals still work.
nonisolated final class LargeStackSerialExecutor: SerialExecutor, @unchecked Sendable {
    static let developBatchReview = LargeStackSerialExecutor(
        name: "com.aagedal.photo-agent.develop-batch-review", stackSize: 8 << 20)

    private let condition = NSCondition()
    private var jobs: [UnownedJob] = []

    init(name: String, stackSize: Int) {
        let thread = Thread { [unowned self] in self.run() }
        thread.name = name
        thread.stackSize = stackSize
        thread.qualityOfService = .utility
        thread.start()
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let unowned = UnownedJob(job)
        condition.lock()
        jobs.append(unowned)
        condition.signal()
        condition.unlock()
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }

    private func run() {
        while true {
            condition.lock()
            while jobs.isEmpty { condition.wait() }
            let job = jobs.removeFirst()
            condition.unlock()
            job.runSynchronously(on: asUnownedSerialExecutor())
        }
    }
}
