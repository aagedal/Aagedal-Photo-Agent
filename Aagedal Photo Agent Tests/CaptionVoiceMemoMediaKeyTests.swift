import Testing
@testable import Aagedal_Photo_Agent

@Suite("Caption voice memo media key")
struct CaptionVoiceMemoMediaKeyTests {
    @Test func recognizesOnlyPlayPause() {
        #expect(CaptionVoiceMemoMediaKey.isPlayPause(subtype: 8, data: (16 << 16) | 0x0a00))
        #expect(!CaptionVoiceMemoMediaKey.isPlayPause(subtype: 7, data: (16 << 16) | 0x0a00))
        for key in [0, 1, 17, 18, 19, 20] {
            #expect(!CaptionVoiceMemoMediaKey.isPlayPause(subtype: 8, data: (key << 16) | 0x0a00))
        }
    }

    @Test func togglesOnlyOnInitialKeyDown() {
        #expect(CaptionVoiceMemoMediaKey.isInitialPress(data: (16 << 16) | 0x0a00))
        #expect(!CaptionVoiceMemoMediaKey.isInitialPress(data: (16 << 16) | 0x0b00))
        #expect(!CaptionVoiceMemoMediaKey.isInitialPress(data: (16 << 16) | 0x0a01))
        #expect(!CaptionVoiceMemoMediaKey.isInitialPress(data: (16 << 16) | 0x0b01))
    }
}
