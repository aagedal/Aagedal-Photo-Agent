import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Original filename rename transaction")
struct RenameOriginalFilenameTransactionTests {
    private let root = URL(fileURLWithPath: "/original-filename-transaction", isDirectory: true)

    @Test("JPEG metadata bytes are staged before commit")
    func jpegSuccess() async throws {
        let source = root.appendingPathComponent("camera.jpg")
        let destination = root.appendingPathComponent("desk.jpg")
        let plan = makePlan(sources: [source], destinations: [destination.lastPathComponent])
        let fileSystem = OriginalFilenameMemoryFileSystem([source: Data("jpeg".utf8)])

        let result = await service(fileSystem).execute(plan)

        #expect(result.succeeded)
        #expect(fileSystem.data(atIfPresent: destination) == marker("jpeg", filename: "camera.jpg"))
        #expect(fileSystem.writeCount == 1)
        #expect(result.moves.map(\.phase) == [.stage, .commit])
        #expect(fileSystem.operationKinds == ["move", "write", "move"])
    }

    @Test("Cancellation after the staged JPEG metadata write restores exact bytes and name")
    func jpegCancellationRollback() async {
        let source = root.appendingPathComponent("camera.jpg")
        let original = [source: Data("jpeg".utf8)]
        let plan = makePlan(sources: [source], destinations: ["desk.jpg"])
        let fileSystem = OriginalFilenameMemoryFileSystem(original)
        let result = await RenameExecutionService(
            fileSystem: fileSystem,
            temporaryNameToken: { "cancel" },
            cancellationRequested: { fileSystem.writeCount > 0 },
            originalFilenameMetadataCodec: MarkerOriginalFilenameCodec()
        ).execute(plan)

        #expect(result.status == .cancelled)
        #expect(result.rollbackStatus == .succeeded)
        #expect(result.residuals.isEmpty)
        #expect(fileSystem.snapshot() == original)
    }

    @Test("RAW and XMP cycles keep metadata with source bytes")
    func rawXMPCycle() async {
        let a = root.appendingPathComponent("A.NEF")
        let b = root.appendingPathComponent("B.NEF")
        let xmpA = root.appendingPathComponent("A.xmp")
        let xmpB = root.appendingPathComponent("B.xmp")
        let plan = makePlan(
            sources: [a, b],
            destinations: ["B.NEF", "A.NEF"],
            existingArtifacts: [xmpA, xmpB]
        )
        let fileSystem = OriginalFilenameMemoryFileSystem([
            a: Data("raw-a".utf8), b: Data("raw-b".utf8),
            xmpA: Data("xmp-a".utf8), xmpB: Data("xmp-b".utf8),
        ])

        let result = await service(fileSystem).execute(plan)

        #expect(result.succeeded)
        #expect(fileSystem.data(atIfPresent: b) == Data("raw-a".utf8))
        #expect(fileSystem.data(atIfPresent: a) == Data("raw-b".utf8))
        #expect(fileSystem.data(atIfPresent: xmpB) == marker("xmp-a", filename: "A.NEF"))
        #expect(fileSystem.data(atIfPresent: xmpA) == marker("xmp-b", filename: "B.NEF"))
    }

    @Test("A later RAW sidecar write failure rolls every prior mutation back byte-for-byte")
    func rawXMPWriteFailureRollback() async {
        let a = root.appendingPathComponent("A.NEF")
        let b = root.appendingPathComponent("B.NEF")
        let xmpA = root.appendingPathComponent("A.xmp")
        let xmpB = root.appendingPathComponent("B.xmp")
        let original = [
            a: Data("raw-a".utf8), b: Data("raw-b".utf8),
            xmpA: Data("xmp-a".utf8), xmpB: Data("xmp-b".utf8),
        ]
        let plan = makePlan(
            sources: [a, b],
            destinations: ["B.NEF", "A.NEF"],
            existingArtifacts: [xmpA, xmpB]
        )
        let fileSystem = OriginalFilenameMemoryFileSystem(original, failWriteOnceAt: 2)

        let result = await service(fileSystem).execute(plan)

        #expect(result.status == .failed)
        #expect(result.rollbackStatus == .succeeded)
        #expect(result.issues.first?.code == .metadataUpdateFailed)
        #expect(result.residuals.isEmpty)
        #expect(fileSystem.snapshot() == original)
    }

    private func makePlan(
        sources: [URL],
        destinations: [String],
        existingArtifacts: Set<URL> = []
    ) -> RenamePlan {
        let items = zip(sources, destinations).map { source, destination in
            RenamePlanningItem(
                sourceImageURL: source,
                context: BatchRenameContext(
                    originalFilename: source.lastPathComponent,
                    metadata: [.event: destination]
                )
            )
        }
        return RenamePlanningService().makePlan(
            items: items,
            recipe: BatchRenameRecipe(
                name: "Preserve",
                components: [.token(.metadata(.event))],
                originalFilenameMetadata: .preserveInXMP
            ),
            environment: RenamePlanningEnvironment(
                caseSensitivity: .caseSensitive,
                existingURLs: existingArtifacts
            )
        )
    }

    private func service(_ fileSystem: OriginalFilenameMemoryFileSystem) -> RenameExecutionService {
        RenameExecutionService(
            fileSystem: fileSystem,
            temporaryNameToken: { UUID().uuidString },
            originalFilenameMetadataCodec: MarkerOriginalFilenameCodec()
        )
    }

    private func marker(_ original: String, filename: String) -> Data {
        Data("\(original)|xmpMM:PreservedFileName=\(filename)".utf8)
    }
}

private nonisolated struct MarkerOriginalFilenameCodec: RenameOriginalFilenameMetadataCodec {
    func applying(
        _ mutation: RenameOriginalFilenameMetadataMutation,
        to originalData: Data
    ) throws -> Data {
        var data = originalData
        data.append(Data("|xmpMM:PreservedFileName=\(mutation.value)".utf8))
        return data
    }
}

private nonisolated final class OriginalFilenameMemoryFileSystem:
    RenameExecutionFileSystem,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var files: [String: Data]
    private let failWriteOnceAt: Int?
    private var didFailWrite = false
    private var writes = 0
    private var operations: [String] = []

    init(_ files: [URL: Data], failWriteOnceAt: Int? = nil) {
        self.files = Dictionary(uniqueKeysWithValues: files.map {
            ($0.key.standardizedFileURL.path, $0.value)
        })
        self.failWriteOnceAt = failWriteOnceAt
    }

    var writeCount: Int { lock.withLock { writes } }
    var operationKinds: [String] { lock.withLock { operations } }

    func itemExists(at url: URL) -> Bool {
        lock.withLock { files[url.standardizedFileURL.path] != nil }
    }

    func directoryAllowsChanges(at directoryURL: URL) -> Bool { true }

    func itemsReferToSameFile(_ firstURL: URL, _ secondURL: URL) throws -> Bool {
        firstURL.standardizedFileURL.path == secondURL.standardizedFileURL.path
    }

    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        try lock.withLock {
            let source = sourceURL.standardizedFileURL.path
            let destination = destinationURL.standardizedFileURL.path
            guard let data = files.removeValue(forKey: source) else {
                throw CocoaError(.fileNoSuchFile)
            }
            guard files[destination] == nil else {
                files[source] = data
                throw CocoaError(.fileWriteFileExists)
            }
            files[destination] = data
            operations.append("move")
        }
    }

    func data(at url: URL) throws -> Data {
        try lock.withLock {
            guard let data = files[url.standardizedFileURL.path] else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            return data
        }
    }

    func writeDataAtomically(_ data: Data, to url: URL) throws {
        try lock.withLock {
            writes += 1
            if !didFailWrite, failWriteOnceAt == writes {
                didFailWrite = true
                throw CocoaError(.fileWriteUnknown)
            }
            files[url.standardizedFileURL.path] = data
            operations.append("write")
        }
    }

    func data(atIfPresent url: URL) -> Data? {
        lock.withLock { files[url.standardizedFileURL.path] }
    }

    func snapshot() -> [URL: Data] {
        lock.withLock {
            Dictionary(uniqueKeysWithValues: files.map {
                (URL(fileURLWithPath: $0.key), $0.value)
            })
        }
    }
}
