import Foundation

nonisolated enum KnownPeopleInterchangeEligibilityError: LocalizedError, Equatable {
    case tooManyPeople(actual: Int)
    case tooManyEmbeddings(actual: Int)
    case invalidPersonID
    case invalidEmbeddingID(personID: UUID)
    case duplicatePersonID(UUID)
    case duplicateEmbeddingID(UUID)
    case invalidName(personID: UUID)
    case personHasNoEmbeddings(personID: UUID)
    case unknownEmbeddingProvenance(personID: UUID, embeddingID: UUID)
    case invalidEmbedding(personID: UUID, embeddingID: UUID, reason: String)

    var errorDescription: String? {
        switch self {
        case .tooManyPeople(let actual):
            return "The library has \(actual) people; interchange supports at most 10,000."
        case .tooManyEmbeddings(let actual):
            return "The library has \(actual) face examples; interchange supports at most 100,000."
        case .invalidPersonID:
            return "A person has the reserved all-zero identifier."
        case .invalidEmbeddingID(let personID):
            return "Person \(personID.uuidString.lowercased()) has a face example with the reserved all-zero identifier."
        case .duplicatePersonID(let id):
            return "Person ID \(id.uuidString.lowercased()) appears more than once."
        case .duplicateEmbeddingID(let id):
            return "Face example ID \(id.uuidString.lowercased()) appears more than once."
        case .invalidName(let personID):
            return "Person \(personID.uuidString.lowercased()) has a blank, invalid, or overlong name."
        case .personHasNoEmbeddings(let personID):
            return "Person \(personID.uuidString.lowercased()) has no face examples for companion matching."
        case .unknownEmbeddingProvenance(let personID, let embeddingID):
            return "Face example \(embeddingID.uuidString.lowercased()) for person \(personID.uuidString.lowercased()) has unknown or incompatible model provenance. Re-enroll it before companion export."
        case .invalidEmbedding(let personID, let embeddingID, let reason):
            return "Face example \(embeddingID.uuidString.lowercased()) for person \(personID.uuidString.lowercased()) is not a valid portable FEM2 vector: \(reason)"
        }
    }
}

nonisolated struct KnownPeopleInterchangeEligibility: Equatable, Sendable {
    let peopleCount: Int
    let embeddingCount: Int

    static let maximumPeopleCount = 10_000
    static let maximumEmbeddingCount = 100_000
    static let maximumNameUTF8ByteCount = 1_024

    static func validate(people: [KnownPerson]) throws -> Self {
        guard people.count <= maximumPeopleCount else {
            throw KnownPeopleInterchangeEligibilityError.tooManyPeople(actual: people.count)
        }

        var personIDs = Set<UUID>()
        var embeddingIDs = Set<UUID>()
        var embeddingCount = 0
        for person in people {
            guard person.id != Self.zeroID else {
                throw KnownPeopleInterchangeEligibilityError.invalidPersonID
            }
            guard personIDs.insert(person.id).inserted else {
                throw KnownPeopleInterchangeEligibilityError.duplicatePersonID(person.id)
            }
            let trimmedName = person.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty,
                  !person.name.contains("\0"),
                  person.name.utf8.count <= maximumNameUTF8ByteCount else {
                throw KnownPeopleInterchangeEligibilityError.invalidName(personID: person.id)
            }
            guard !person.embeddings.isEmpty else {
                throw KnownPeopleInterchangeEligibilityError.personHasNoEmbeddings(personID: person.id)
            }

            for embedding in person.embeddings {
                embeddingCount += 1
                guard embeddingCount <= maximumEmbeddingCount else {
                    throw KnownPeopleInterchangeEligibilityError.tooManyEmbeddings(actual: embeddingCount)
                }
                guard embedding.id != Self.zeroID else {
                    throw KnownPeopleInterchangeEligibilityError.invalidEmbeddingID(personID: person.id)
                }
                guard embeddingIDs.insert(embedding.id).inserted else {
                    throw KnownPeopleInterchangeEligibilityError.duplicateEmbeddingID(embedding.id)
                }
                guard embedding.provenance?.isCurrentInterchangeCompatible == true else {
                    throw KnownPeopleInterchangeEligibilityError.unknownEmbeddingProvenance(
                        personID: person.id,
                        embeddingID: embedding.id
                    )
                }
                do {
                    _ = try FaceEmbeddingInterchangeCodec.validate(embedding.featurePrintData)
                } catch {
                    throw KnownPeopleInterchangeEligibilityError.invalidEmbedding(
                        personID: person.id,
                        embeddingID: embedding.id,
                        reason: error.localizedDescription
                    )
                }
            }
        }
        return Self(peopleCount: people.count, embeddingCount: embeddingCount)
    }

    private static let zeroID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
}
