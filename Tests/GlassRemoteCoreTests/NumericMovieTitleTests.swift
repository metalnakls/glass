import Testing
@testable import GlassRemoteCore

struct NumericMovieTitleTests {
    @Test(arguments: [
        ("1917.2019.WEB-DL.2160p.mkv", "1917.mkv"),
        ("1984.1984.1080p.mkv", "1984.mkv"),
        ("2001.A.Space.Odyssey.1968.BluRay.mkv", "2001 A Space Odyssey.mkv"),
        ("1080p.mkv", "1080p.mkv")
    ])
    func keepsVisibleMovieName(input: String, expected: String) {
        #expect(TorrentNameCleaner.cleanMediaFileName(input) == expected)
    }
}
