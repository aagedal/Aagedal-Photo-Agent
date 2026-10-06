import Foundation

/// Downloads and validates the official multilingual vocabulary before atomically replacing
/// the local cache. The bundled vocabulary remains the fallback for offline or failed checks.
actor IPTCMediaTopicsUpdateService {
    static let shared = IPTCMediaTopicsUpdateService()
    static let endpoint = URL(string: "https://cv.iptc.org/newscodes/mediatopic?format=json&lang=all")!
    struct Cache: Codable, Sendable {
        let vocabulary: IPTCMediaTopics
        let checkedAt: Date
    }
    enum UpdateError: LocalizedError {
        case invalidResponse, invalidVocabulary
        var errorDescription: String? {
            switch self {
            case .invalidResponse: "IPTC did not return a valid vocabulary download."
            case .invalidVocabulary: "The downloaded IPTC vocabulary could not be validated."
            }
        }
    }
    private let cacheURL: URL
    private let download: @Sendable () async throws -> Data

    init(cacheURL: URL? = nil, download: (@Sendable () async throws -> Data)? = nil) {
        self.cacheURL = cacheURL ?? AppPaths.applicationSupport.appendingPathComponent("IPTC/MediaTopics.json")
        self.download = download ?? {
            var request = URLRequest(url: Self.endpoint)
            request.timeoutInterval = 30
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                  data.count <= 20 * 1024 * 1024 else { throw UpdateError.invalidResponse }
            return data
        }
    }

    func cached() -> Cache? {
        guard let data = try? Data(contentsOf: cacheURL),
              let cache = try? JSONDecoder().decode(Cache.self, from: data),
              (try? Self.validate(cache.vocabulary)) != nil else { return nil }
        return cache
    }

    func refresh(current: IPTCMediaTopics, force: Bool, now: Date = .now) async throws -> Cache? {
        if !force, let cache = cached(), now.timeIntervalSince(cache.checkedAt) < 7 * 24 * 60 * 60 { return nil }
        let data = try await download()
        try Task.checkCancellation()
        let incoming = try Self.decodeOfficial(data)
        // An older server response must not roll back a newer bundled or cached release.
        let vocabulary = incoming.release.prefix(10) >= current.release.prefix(10) ? incoming : current
        let cache = Cache(vocabulary: vocabulary, checkedAt: now)
        let encoded = try JSONEncoder().encode(cache)
        try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoded.write(to: cacheURL, options: .atomic)
        return cache
    }

    nonisolated static func decodeOfficial(_ data: Data) throws -> IPTCMediaTopics {
        struct Official: Decodable {
            struct Concept: Decodable {
                let uri: String
                let prefLabel: [String: String]
                let broader: [String]?
                let retired: String?
            }
            let uri: String
            let dateReleased: String
            let hasTopConcept: [String]
            let conceptSet: [Concept]
        }
        let source = try JSONDecoder().decode(Official.self, from: data)
        let prefix = "http://cv.iptc.org/newscodes/mediatopic/"
        guard source.uri == prefix else { throw UpdateError.invalidVocabulary }
        func identifier(_ uri: String) throws -> String {
            guard uri.hasPrefix(prefix) else { throw UpdateError.invalidVocabulary }
            let id = String(uri.dropFirst(prefix.count))
            guard id.count == 8, id.allSatisfy(\.isNumber) else { throw UpdateError.invalidVocabulary }
            return id
        }
        let active = source.conceptSet.filter { ($0.retired ?? "").isEmpty }
        var labels: [String: [String: String]] = [:]
        var children: [String: [String]] = [:]
        for concept in active {
            let id = try identifier(concept.uri)
            guard labels[id] == nil else { throw UpdateError.invalidVocabulary }
            labels[id] = concept.prefLabel.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            for parent in concept.broader ?? [] { children[try identifier(parent), default: []].append(id) }
        }
        let complete = IPTCMediaTopics(release: source.dateReleased,
            roots: try source.hasTopConcept.map(identifier),
            concepts: Dictionary(uniqueKeysWithValues: labels.map { id, values in
                (id, IPTCMediaTopics.Concept(labels: values, children: children[id] ?? []))
            }))
        try validate(complete)
        return complete
    }

    nonisolated static func validate(_ vocabulary: IPTCMediaTopics) throws {
        guard ISO8601DateFormatter().date(from: vocabulary.release) != nil,
              !vocabulary.roots.isEmpty, !vocabulary.concepts.isEmpty,
              Set(vocabulary.roots).count == vocabulary.roots.count else { throw UpdateError.invalidVocabulary }
        var visited = Set<String>()
        func visit(_ id: String, ancestors: Set<String>) throws {
            guard ancestors.count < 32, !ancestors.contains(id),
                  let concept = vocabulary.concepts[id],
                  concept.labels["en-US"] != nil || concept.labels["en-GB"] != nil else {
                throw UpdateError.invalidVocabulary
            }
            if visited.contains(id) { return }
            for child in concept.children { try visit(child, ancestors: ancestors.union([id])) }
            visited.insert(id)
        }
        for root in vocabulary.roots { try visit(root, ancestors: []) }
        guard visited.count == vocabulary.concepts.count else { throw UpdateError.invalidVocabulary }
    }
}
