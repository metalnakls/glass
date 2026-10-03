import Testing
@testable import GlassRemoteUI

@Suite("Media extension display")
struct TorrentExtensionPolicyTests {
    @Test("uniform media types hide their suffix irrespective of case or nested folders")
    func uniformTypes() {
        #expect(TorrentExtensionPolicy.hiddenExtension(paths: ["Show/S01E01.MKV", "Show/Extras/S01E02.mkv"]) == "mkv")
        #expect(TorrentExtensionPolicy.name("S01E01.MKV", hiding: "mkv") == "S01E01")
        for suffix in ["mkv", "mov", "mp4", "wav", "flac", "mp3"] {
            #expect(TorrentExtensionPolicy.hiddenExtension(paths: ["File.\(suffix)"]) == suffix)
        }
    }
    @Test("mixed, unsupported, and extensionless files keep their names")
    func mixedTypes() {
        for paths in [["Episode.mkv", "Episode.srt"], ["Movie.mkv", "Bonus.mp4"], ["Music.flac", "cover.jpg"], ["movie.avi"], ["README"], []] {
            #expect(TorrentExtensionPolicy.hiddenExtension(paths: paths) == nil)
        }
        #expect(TorrentExtensionPolicy.name("Season 1", hiding: "mkv") == "Season 1")
    }
}
