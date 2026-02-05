import Foundation
import Vision
import AppKit

@MainActor
final class KnownPeopleService {

    // MARK: - Singleton

    static let shared = KnownPeopleService()

    // MARK: - Storage Paths

    private var knownPeopleDirectory: URL {
        let url = AppPaths.applicationSupport.appendingPathComponent("KnownPeople", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private var databaseFileURL: URL {
        knownPeopleDirectory.appendingPathComponent("database.json")
    }

    private var thumbnailsDirectory: URL {
        let url = knownPeopleDirectory.appendingPathComponent("thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func thumbnailURL(for personID: UUID) -> URL {
        thumbnailsDirectory.appendingPathComponent("\(personID.uuidString).jpg")
    }

    // MARK: - In-Memory Cache

    private var database: KnownPeopleDatabase?
    private var featurePrintCache: [UUID: VNFeaturePrintObservation] = [:]

    // MARK: - Load / Save

    func loadDatabase() -> KnownPeopleDatabase {
        if let cached = database {
            return cached
        }

        guard FileManager.default.fileExists(atPath: databaseFileURL.path) else {
            let empty = KnownPeopleDatabase()
            database = empty
            return empty
        }

        do {
            let data = try Data(contentsOf: databaseFileURL)
            let loaded = try JSONDecoder().decode(KnownPeopleDatabase.self, from: data)
            database = loaded
            return loaded
        } catch {
            let empty = KnownPeopleDatabase()
            database = empty
            return empty
        }
    }

    private func saveDatabase() throws {
        guard let db = database else { return }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(db)
        try data.write(to: databaseFileURL)
        NotificationCenter.default.post(name: .knownPeopleDatabaseDidChange, object: nil)
    }

    // MARK: - Thumbnails

    func loadThumbnail(for personID: UUID) -> NSImage? {
        let url = thumbnailURL(for: personID)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return NSImage(data: data)
    }

    func saveThumbnail(_ imageData: Data, for personID: UUID) throws {
        let url = thumbnailURL(for: personID)
        try imageData.write(to: url)
    }

    private func deleteThumbnail(for personID: UUID) {
        let url = thumbnailURL(for: personID)
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - CRUD Operations

    func addPerson(
        name: String,
        role: String? = nil,
        embeddings: [PersonEmbedding],
        thumbnailData: Data? = nil
    ) throws -> KnownPerson {
        var db = loadDatabase()

        let person = KnownPerson(
            name: name,
            role: role,
            embeddings: embeddings,
            representativeThumbnailID: embeddings.first?.id
        )

        db.people.append(person)
        db.lastModified = Date()
        database = db

        if let thumbData = thumbnailData {
            try saveThumbnail(thumbData, for: person.id)
        }

        try saveDatabase()
        clearFeaturePrintCache()

        return person
    }

    func updatePerson(_ person: KnownPerson) throws {
        var db = loadDatabase()

        guard let index = db.people.firstIndex(where: { $0.id == person.id }) else {
            return
        }

        var updated = person
        updated.updatedAt = Date()
        db.people[index] = updated
        db.lastModified = Date()
        database = db

        try saveDatabase()
        clearFeaturePrintCache()
    }

    func removePerson(id: UUID) throws {
        var db = loadDatabase()

        db.people.removeAll { $0.id == id }
        db.lastModified = Date()
        database = db

        deleteThumbnail(for: id)
        try saveDatabase()
        clearFeaturePrintCache()
    }

    func addEmbedding(_ embedding: PersonEmbedding, toPersonID personID: UUID) throws {
        var db = loadDatabase()

        guard let index = db.people.firstIndex(where: { $0.id == personID }) else {
            return
        }

        db.people[index].embeddings.append(embedding)
        db.people[index].updatedAt = Date()
        db.lastModified = Date()
        database = db

        try saveDatabase()
        clearFeaturePrintCache()
    }

    // MARK: - Duplicate Detection

    /// Result of checking for duplicate people before adding
    enum DuplicateCheckResult {
        /// No duplicate found - safe to create new person
        case noDuplicate
        /// Found person with matching name (case-insensitive)
        case nameMatch(person: KnownPerson)
        /// Found person with similar face embedding
        case faceMatch(person: KnownPerson, confidence: Float)
        /// Found both name and face match (same person)
        case bothMatch(person: KnownPerson, confidence: Float)
    }

    /// Check if a person with this name or similar face already exists.
    /// Set allowFaceMatch to false to only check name matches.
    /// Use this before adding to avoid duplicates.
    func checkForDuplicate(
        name: String,
        representativeFaceData: Data,
        threshold: Float = 0.45,
        allowFaceMatch: Bool = true
    ) -> DuplicateCheckResult {
        let db = loadDatabase()
        let trimmedName = name.trimmingCharacters(in: .whitespaces)

        // Check for name match (case-insensitive)
        let nameMatch = db.people.first { person in
            person.name.trimmingCharacters(in: .whitespaces)
                .caseInsensitiveCompare(trimmedName) == .orderedSame
        }

        // Check for face match if allowed
        let faceMatch: KnownPersonMatch?
        if allowFaceMatch {
            let faceMatches = matchFace(featurePrintData: representativeFaceData, threshold: threshold, maxResults: 1)
            faceMatch = faceMatches.first
        } else {
            faceMatch = nil
        }

        // Determine result
        if let nameMatch, let faceMatch, nameMatch.id == faceMatch.person.id {
            // Same person matched by both name and face
            return .bothMatch(person: nameMatch, confidence: faceMatch.confidence)
        } else if let nameMatch {
            return .nameMatch(person: nameMatch)
        } else if let faceMatch {
            return .faceMatch(person: faceMatch.person, confidence: faceMatch.confidence)
        }

        return .noDuplicate
    }

    /// Smart add that checks for duplicates and either creates new or adds to existing.
    /// Returns the person (new or existing) and whether embeddings were added to existing.
    @discardableResult
    func addOrMergePerson(
        name: String,
        role: String? = nil,
        embeddings: [PersonEmbedding],
        thumbnailData: Data?,
        duplicateCheck: DuplicateCheckResult
    ) throws -> (person: KnownPerson, addedToExisting: Bool) {
        switch duplicateCheck {
        case .noDuplicate:
            // Create new person
            let person = try addPerson(name: name, role: role, embeddings: embeddings, thumbnailData: thumbnailData)
            return (person, false)

        case .nameMatch(let existingPerson), .faceMatch(let existingPerson, _), .bothMatch(let existingPerson, _):
            // Add embeddings to existing person, avoiding duplicates
            try addEmbeddingsDeduped(embeddings, toPersonID: existingPerson.id)

            // Return updated person
            if let updatedPerson = person(byID: existingPerson.id) {
                return (updatedPerson, true)
            }
            return (existingPerson, true)
        }
    }

    /// Add embeddings to a person, skipping any that are duplicates (same featurePrintData).
    func addEmbeddingsDeduped(_ embeddings: [PersonEmbedding], toPersonID personID: UUID) throws {
        var db = loadDatabase()

        guard let index = db.people.firstIndex(where: { $0.id == personID }) else {
            return
        }

        // Get existing embedding data for comparison
        let existingData = Set(db.people[index].embeddings.map { $0.featurePrintData })

        // Filter to only new embeddings
        let newEmbeddings = embeddings.filter { !existingData.contains($0.featurePrintData) }

        guard !newEmbeddings.isEmpty else { return }

        db.people[index].embeddings.append(contentsOf: newEmbeddings)
        db.people[index].updatedAt = Date()
        db.lastModified = Date()
        database = db

        try saveDatabase()
        clearFeaturePrintCache()
    }

    /// Find a person by name (case-insensitive).
    func person(byName name: String) -> KnownPerson? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return loadDatabase().people.first { person in
            person.name.trimmingCharacters(in: .whitespaces)
                .caseInsensitiveCompare(trimmed) == .orderedSame
        }
    }

    /// Merge people: combine embeddings from source into target, delete source.
    /// Deduplicates embeddings to avoid storing the same face data multiple times.
    func mergePeople(sourceID: UUID, intoTargetID: UUID) throws {
        var db = loadDatabase()
        guard let sourceIndex = db.people.firstIndex(where: { $0.id == sourceID }),
              let targetIndex = db.people.firstIndex(where: { $0.id == intoTargetID }),
              sourceIndex != targetIndex else {
            return
        }

        // Get existing embedding data for deduplication
        let existingData = Set(db.people[targetIndex].embeddings.map { $0.featurePrintData })

        // Filter source embeddings to only include those not already in target
        let newEmbeddings = db.people[sourceIndex].embeddings.filter { embedding in
            !existingData.contains(embedding.featurePrintData)
        }

        // Append only non-duplicate embeddings to target
        db.people[targetIndex].embeddings.append(contentsOf: newEmbeddings)
        db.people[targetIndex].updatedAt = Date()

        // Delete source person and thumbnail
        let sourcePersonID = db.people[sourceIndex].id
        db.people.remove(at: sourceIndex)
        deleteThumbnail(for: sourcePersonID)

        db.lastModified = Date()
        database = db
        try saveDatabase()
        clearFeaturePrintCache()
    }

    /// Replace the thumbnail for a known person
    func replaceThumbnail(for personID: UUID, newThumbnailData: Data) throws {
        try saveThumbnail(newThumbnailData, for: personID)

        // Update timestamp
        var db = loadDatabase()
        if let index = db.people.firstIndex(where: { $0.id == personID }) {
            db.people[index].updatedAt = Date()
            db.lastModified = Date()
            database = db
            try saveDatabase()
        }
    }

    /// Delete a single embedding from a person
    func removeEmbedding(_ embeddingID: UUID, fromPersonID personID: UUID) throws {
        var db = loadDatabase()
        guard let index = db.people.firstIndex(where: { $0.id == personID }) else { return }

        db.people[index].embeddings.removeAll { $0.id == embeddingID }

        // Update representative if it was the removed one
        if db.people[index].representativeThumbnailID == embeddingID {
            db.people[index].representativeThumbnailID = db.people[index].embeddings.first?.id
        }

        db.people[index].updatedAt = Date()
        db.lastModified = Date()
        database = db
        try saveDatabase()
        clearFeaturePrintCache()
    }

    /// Get a person by ID
    func person(byID personID: UUID) -> KnownPerson? {
        return loadDatabase().people.first { $0.id == personID }
    }

    func clearDatabase() throws {
        database = KnownPeopleDatabase()
        featurePrintCache = [:]

        // Remove all files
        if FileManager.default.fileExists(atPath: knownPeopleDirectory.path) {
            try FileManager.default.removeItem(at: knownPeopleDirectory)
        }

        // Recreate empty directory structure
        try FileManager.default.createDirectory(at: thumbnailsDirectory, withIntermediateDirectories: true)
        try saveDatabase()
    }

    // MARK: - Matching

    struct MatchPolicy: Sendable {
        let threshold: Float
        let minConfidence: Float
        let minConfidenceGap: Float
    }

    private func currentAutoMatchPolicy() -> MatchPolicy {
        let minConfidence = Float(UserDefaults.standard.object(forKey: "knownPeopleMinConfidence") as? Double ?? 0.60)
        return MatchPolicy(
            threshold: 0.45,
            minConfidence: minConfidence,
            minConfidenceGap: 0.05
        )
    }

    private func clearFeaturePrintCache() {
        featurePrintCache = [:]
    }

    private func getFeaturePrint(for embedding: PersonEmbedding) -> VNFeaturePrintObservation? {
        if let cached = featurePrintCache[embedding.id] {
            return cached
        }

        guard let fp = try? NSKeyedUnarchiver.unarchivedObject(
            ofClass: VNFeaturePrintObservation.self,
            from: embedding.featurePrintData
        ) else {
            return nil
        }

        featurePrintCache[embedding.id] = fp
        return fp
    }

    /// Match a face embedding against all known people.
    /// Returns matches sorted by confidence (highest first).
    ///
    /// **Important:** This always performs face-only matching using Vision feature prints.
    /// Clothing features are intentionally NOT used here to ensure consistent matching
    /// across different contexts (same person in different clothing).
    func matchFace(
        featurePrintData: Data,
        threshold: Float = 0.45,
        maxResults: Int = 5
    ) -> [KnownPersonMatch] {
        guard let queryFP = try? NSKeyedUnarchiver.unarchivedObject(
            ofClass: VNFeaturePrintObservation.self,
            from: featurePrintData
        ) else {
            return []
        }

        let db = loadDatabase()
        var matches: [KnownPersonMatch] = []

        for person in db.people {
            var bestDistance: Float = .infinity
            var bestEmbeddingID: UUID?

            for embedding in person.embeddings {
                guard let personFP = getFeaturePrint(for: embedding) else { continue }

                var distance: Float = 0
                do {
                    try queryFP.computeDistance(&distance, to: personFP)
                    if distance < bestDistance {
                        bestDistance = distance
                        bestEmbeddingID = embedding.id
                    }
                } catch {
                    continue
                }
            }

            if let embeddingID = bestEmbeddingID, bestDistance < threshold {
                // Convert distance to confidence (0-1, higher = more confident)
                let confidence = max(0, 1.0 - bestDistance)
                matches.append(KnownPersonMatch(
                    person: person,
                    confidence: confidence,
                    matchedEmbeddingID: embeddingID
                ))
            }
        }

        return matches
            .sorted { $0.confidence > $1.confidence }
            .prefix(maxResults)
            .map { $0 }
    }

    /// Returns the best match only if it clears a stricter auto-match policy.
    /// This is intended for auto-naming flows and is more conservative than raw `matchFace`.
    func bestAutoMatch(
        featurePrintData: Data,
        policy: MatchPolicy? = nil
    ) -> KnownPersonMatch? {
        let policy = policy ?? currentAutoMatchPolicy()
        let matches = matchFace(
            featurePrintData: featurePrintData,
            threshold: policy.threshold,
            maxResults: 2
        )

        guard let best = matches.first, best.confidence >= policy.minConfidence else {
            return nil
        }

        if let second = matches.dropFirst().first,
           best.confidence - second.confidence < policy.minConfidenceGap {
            return nil
        }

        return best
    }

    /// Match multiple faces at once for efficiency.
    /// Returns a dictionary mapping face IDs to their best match (if any).
    func matchFaces(
        _ faces: [(id: UUID, featurePrintData: Data)],
        threshold: Float = 0.45
    ) -> [UUID: KnownPersonMatch] {
        var results: [UUID: KnownPersonMatch] = [:]

        for face in faces {
            if let bestMatch = matchFace(featurePrintData: face.featurePrintData, threshold: threshold, maxResults: 1).first {
                results[face.id] = bestMatch
            }
        }

        return results
    }

    // MARK: - Export

    func exportToZip(destinationURL: URL, exportedBy: String? = nil) throws {
        let db = loadDatabase()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        // Create temp directory structure
        let tempThumbnailsDir = tempDir.appendingPathComponent("thumbnails")
        try FileManager.default.createDirectory(at: tempThumbnailsDir, withIntermediateDirectories: true)

        // Write manifest
        let embeddingCount = db.people.reduce(0) { $0 + $1.embeddings.count }
        let manifest = KnownPeopleManifest(
            exportedBy: exportedBy,
            peopleCount: db.people.count,
            embeddingCount: embeddingCount
        )
        let manifestData = try JSONEncoder().encode(manifest)
        try manifestData.write(to: tempDir.appendingPathComponent("manifest.json"))

        // Write people data
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let peopleData = try encoder.encode(db.people)
        try peopleData.write(to: tempDir.appendingPathComponent("people.json"))

        // Copy thumbnails
        for person in db.people {
            let sourceURL = thumbnailURL(for: person.id)
            if FileManager.default.fileExists(atPath: sourceURL.path) {
                let destURL = tempThumbnailsDir.appendingPathComponent("\(person.id.uuidString).jpg")
                try FileManager.default.copyItem(at: sourceURL, to: destURL)
            }
        }

        // Create zip using ditto
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", tempDir.path, destinationURL.path]

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            throw NSError(domain: "KnownPeopleService", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to create zip archive"
            ])
        }
    }

    // MARK: - Import

    func importFromZip(sourceURL: URL) throws -> Int {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Unzip using ditto
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", sourceURL.path, tempDir.path]

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            throw NSError(domain: "KnownPeopleService", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Failed to extract zip archive"
            ])
        }

        // Find the extracted directory (ditto with --keepParent creates a subdirectory)
        let contents = try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
        let extractedDir = contents.first { url in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        } ?? tempDir

        // Read people.json
        let peopleURL = extractedDir.appendingPathComponent("people.json")
        guard FileManager.default.fileExists(atPath: peopleURL.path) else {
            throw NSError(domain: "KnownPeopleService", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Invalid archive: missing people.json"
            ])
        }

        let peopleData = try Data(contentsOf: peopleURL)
        let importedPeople = try JSONDecoder().decode([KnownPerson].self, from: peopleData)

        // Add imported people (UUIDs are unique, no conflict resolution needed)
        var db = loadDatabase()
        db.people.append(contentsOf: importedPeople)
        db.lastModified = Date()
        database = db

        // Copy thumbnails
        let importedThumbnailsDir = extractedDir.appendingPathComponent("thumbnails")
        for person in importedPeople {
            let sourceThumb = importedThumbnailsDir.appendingPathComponent("\(person.id.uuidString).jpg")
            if FileManager.default.fileExists(atPath: sourceThumb.path) {
                let destThumb = thumbnailURL(for: person.id)
                try? FileManager.default.copyItem(at: sourceThumb, to: destThumb)
            }
        }

        try saveDatabase()
        clearFeaturePrintCache()

        return importedPeople.count
    }

    // MARK: - Statistics

    func getStatistics() -> (peopleCount: Int, embeddingCount: Int) {
        let db = loadDatabase()
        let embeddingCount = db.people.reduce(0) { $0 + $1.embeddings.count }
        return (db.people.count, embeddingCount)
    }

    func getAllPeople() -> [KnownPerson] {
        return loadDatabase().people
    }
}
