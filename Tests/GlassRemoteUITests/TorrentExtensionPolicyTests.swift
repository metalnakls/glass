import Testing
@testable import GlassRemoteUI

@Suite("Media extension display")
struct TorrentExtensionPolicyTests {
    @Test("uniform media types hide their suffix irrespective of case or nested folders")
    func uniformTypes() {
        #expect(TorrentExtensionPolicy.hiddenExtension(paths: ["Show/S01E01.MKV", "Show/Extras/S01E02.mkv"]) == "mkv")
        #expect(TorrentExtensionPolicy.name("S01E01.MKV", hiding: "mkv") == "S01E01")
        for suffix in TorrentExtensionPolicy.mediaExtensions {
            #expect(TorrentExtensionPolicy.hiddenExtension(paths: ["File.\(suffix)"]) == suffix)
        }
    }

    @Test("avi hides its suffix, including the reported name")
    func aviIsHidden() {
        #expect(TorrentExtensionPolicy.hiddenExtension(paths: ["Royal Hotel.avi"]) == "avi")
        #expect(TorrentExtensionPolicy.name("Royal Hotel.avi", hiding: "avi") == "Royal Hotel")
        #expect(TorrentExtensionPolicy.hiddenExtension(paths: ["Show/S01E01.AVI", "Show/S01E02.avi"]) == "avi")
        #expect(TorrentExtensionPolicy.hiddenExtension(paths: ["Royal Hotel.xvid"]) == "xvid")
        #expect(TorrentExtensionPolicy.hiddenExtension(paths: ["Royal Hotel.divx"]) == "divx")
    }

    @Test("mixed, unsupported, and extensionless files keep their names")
    func mixedTypes() {
        for paths in [["Episode.mkv", "Episode.srt"], ["Movie.mkv", "Bonus.mp4"], ["Music.flac", "cover.jpg"], ["README"], []] {
            #expect(TorrentExtensionPolicy.hiddenExtension(paths: paths) == nil)
        }
        for suffix in ["srt", "sub", "idx", "txt", "nfo", "jpg", "png", "iso", "zip", "rar", "7z"] {
            #expect(TorrentExtensionPolicy.hiddenExtension(paths: ["File.\(suffix)"]) == nil)
        }
        for paths in [["Clip.avi", "Clip.srt"], ["Clip.avi", "cover.jpg"]] {
            #expect(TorrentExtensionPolicy.hiddenExtension(paths: paths) == nil)
        }
        #expect(TorrentExtensionPolicy.name("Season 1", hiding: "mkv") == "Season 1")
    }
}
