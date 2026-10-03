import GlassRemoteCore
import Testing
@testable import GlassRemoteUI

@MainActor
@Suite("Compact file tree")
struct TorrentFileTreeTests {
    @Test("smart names preserve parents and staged choices stay isolated between torrents")
    func stagedNaming() {
        let entry = TorrentFileBrowserEntry(index: 4, file: TorrentFile(name: "Show/Season 1/Subfolder/original.mkv", length: 10, bytesCompleted: 0), rootName: "Show", displayName: "S01E01.mkv")
        #expect(entry.displayName == "Season 1/Subfolder/S01E01.mkv")
        let session = TorrentFileEditSession()
        session.selections = ["one": [4], "two": [1, 2]]
        session.stageSelection(false)
        #expect(session.wanted["one"] == [4: false])
        #expect(session.wanted["two"] == [1: false, 2: false])
        session.confirm([4: true], for: "one")
        #expect(session.wanted["one"] == [4: false])
        session.confirm([4: false], for: "one")
        #expect(session.wanted["one"]?.isEmpty == true)
        #expect(session.wanted["two"] == [1: false, 2: false])
        session.reset()
        #expect(!session.hasChanges && !session.hasSelection)
    }

    @Test("renamed torrent roots do not repeat the series above seasons")
    func renamedRoot() {
        let paths = ["Fargo.original/Season 1/S01E01.mkv", "Fargo.original/Season 2/S02E01.mkv"]
        let root = TorrentFileBrowserEntry.commonRoot(paths: paths) ?? "Fargo"
        let entries = paths.enumerated().map { index, path in
            TorrentFileBrowserEntry(index: index, file: TorrentFile(name: path, length: 10, bytesCompleted: 0), rootName: root)
        }
        #expect(TorrentFileTreeRow.rows(entries: entries, collapsed: [], query: "").map(\.name) == ["Season 1", "S01E01.mkv", "Season 2", "S02E01.mkv"])
        #expect(TorrentFileBrowserEntry.commonRoot(paths: ["a.mkv", "b.mkv"]) == nil)
    }

    @Test("nested folders preserve file indices and aggregate sizes when collapsed or searched")
    func hierarchy() {
        let entries = ["Show/Season 1/S01E01.mkv", "Show/Season 1/Subtitles/en.srt", "Show/Season 2/S02E01.mkv"].enumerated().map { index, path in
            TorrentFileBrowserEntry(index: index, file: TorrentFile(name: path, length: 10, bytesCompleted: 0), rootName: "Show")
        }
        let expanded = TorrentFileTreeRow.rows(entries: entries, collapsed: [], query: "")
        #expect(expanded.map(\.name) == ["Season 1", "S01E01.mkv", "Subtitles", "en.srt", "Season 2", "S02E01.mkv"])
        #expect(expanded[0].indices == [0, 1])
        #expect(expanded[0].size == 20)
        let collapsed = TorrentFileTreeRow.rows(entries: entries, collapsed: ["Season 1"], query: "")
        #expect(collapsed.map(\.name) == ["Season 1", "Season 2", "S02E01.mkv"])
        let found = TorrentFileTreeRow.rows(entries: entries, collapsed: ["Season 1"], query: "en.srt")
        #expect(found.map(\.name) == ["Season 1", "Subtitles", "en.srt"])
        #expect(found.last?.indices == [1])
    }
}
