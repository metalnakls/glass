import Testing
@testable import GlassRemoteUI

@Suite("Shared lowercase style")
struct GlassTextStyleTests {
    @Test func controlsAndMessages() {
        for (text, expected) in [("Search Files", "search files"), ("No data found", "no data found"),
                                 ("Unavailable", "unavailable"), ("Couldn’t Add Torrent", "couldn’t add torrent")] {
            #expect(GlassTextCase.apply(text, lowercase: true) == expected)
            #expect(GlassTextCase.apply(text, lowercase: false) == text)
        }
    }
}
