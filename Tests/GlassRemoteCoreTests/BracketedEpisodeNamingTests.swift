import Testing
@testable import GlassRemoteCore

struct BracketedEpisodeNamingTests {
    @Test(arguments: [
        ("The.Walking.Dead.[S07E01].HD1080.mkv", "S07E01.mkv"),
        ("S07E01 — ] Hd1080.mkv", "S07E01.mkv"),
        ("The.Walking.Dead.[S07E16].The.First.Day.HD1080.mkv", "S07E16 — The First Day.mkv"),
        ("Show.S01E03.Real.Title.1080p.MKV", "S01E03 — Real Title.MKV")
    ])
    func cleansEpisodeSuffix(input: String, expected: String) {
        #expect(TorrentNameCleaner.cleanMediaFileName(input) == expected)
    }
}
