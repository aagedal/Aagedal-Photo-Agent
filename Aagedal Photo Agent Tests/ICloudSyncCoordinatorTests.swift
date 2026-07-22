import Testing
@testable import Aagedal_Photo_Agent

@Suite("iCloud sync coordinator")
struct ICloudSyncCoordinatorTests {
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
}
