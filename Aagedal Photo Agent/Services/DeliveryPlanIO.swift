import Foundation

nonisolated enum DeliveryPlanIOError: Error, Equatable, LocalizedError, Sendable {
    case fileTooLarge(found: Int, limit: Int)
    case destinationAlreadyExists(URL)

    var errorDescription: String? {
        switch self {
        case let .fileTooLarge(found, limit):
            "The delivery plan is \(found) bytes; the maximum supported size is \(limit) bytes."
        case let .destinationAlreadyExists(url):
            "A file already exists at \(url.path). Immutable delivery plans are never overwritten."
        }
    }
}

/// Strict JSON boundary for immutable plan handoff and relaunch/resume state.
nonisolated struct DeliveryPlanIO: Sendable {
    static let maximumFileSize = 64 * 1_048_576

    func encode(_ plan: DeliveryPlan) throws -> Data {
        try plan.validateForPersistence()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(plan)
        data.append(0x0A)
        return data
    }

    func decode(_ data: Data) throws -> DeliveryPlan {
        guard data.count <= Self.maximumFileSize else {
            throw DeliveryPlanIOError.fileTooLarge(found: data.count, limit: Self.maximumFileSize)
        }
        try EditorialJSONSchema.requireWritableVersion(
            in: data,
            supportedVersion: DeliveryPlan.currentSchemaVersion,
            documentName: "delivery plan"
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let plan = try decoder.decode(DeliveryPlan.self, from: data)
        try plan.validateForPersistence()
        return plan
    }

    func export(_ plan: DeliveryPlan, to destination: URL) throws {
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw DeliveryPlanIOError.destinationAlreadyExists(destination)
        }
        try encode(plan).write(to: destination, options: [.atomic, .withoutOverwriting])
    }

    func importPlan(from source: URL) throws -> DeliveryPlan {
        let values = try source.resourceValues(forKeys: [.fileSizeKey])
        if let size = values.fileSize, size > Self.maximumFileSize {
            throw DeliveryPlanIOError.fileTooLarge(found: size, limit: Self.maximumFileSize)
        }
        return try decode(Data(contentsOf: source, options: .mappedIfSafe))
    }
}
