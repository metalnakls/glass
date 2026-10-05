import GlassRemoteCore
import Testing
@testable import GlassRemoteUI

@MainActor
@Suite("Compact file tree")
struct TorrentFileTreeTests {
    @Test("cached trees retain fresh telemetry and invalidate for names, sizes, collapse and search")
    func cachedTreeUpdates() {
        let cache = TorrentFileTreeCache()
        func entries(name: String = "Show/Season 1/one.mkv", size: UInt64 = 10, completed: UInt64 = 0, wanted: Bool = true) -> [TorrentFileBrowserEntry] {
            [TorrentFileBrowserEntry(index: 0,
                file: TorrentFile(name: name, length: size, bytesCompleted: completed),
                rootName: "Show", isWanted: wanted)]
        }
        func rows(_ entries: [TorrentFileBrowserEntry], collapsed: Set<String> = [], query: String = "") -> [TorrentFileTreeRow] {
            cache.rows(entries: entries, byIndex: Dictionary(uniqueKeysWithValues: entries.map { ($0.index, $0) }), collapsed: collapsed, query: query)
        }
        #expect(rows(entries()).map(\.name) == ["Season 1", "one.mkv"])
        #expect(cache.hiddenExtension == "mkv")
        let updated = rows(entries(completed: 7, wanted: false))
        #expect(updated.last?.entry?.completedBytes == 7)
        #expect(updated.last?.entry?.isWanted == false)
        #expect(rows(entries(), collapsed: ["Season 1"]).count == 1)
        #expect(rows(entries(), collapsed: ["Season 1"], query: "one").count == 2)
        #expect(rows(entries(), query: "absent").isEmpty)
        let renamed = rows(entries(name: "Show/Season 2/two.mp4", size: 20))
        #expect(renamed.map(\.name) == ["Season 2", "two.mp4"])
        #expect(renamed.first?.size == 20)
        #expect(cache.hiddenExtension == "mp4")
        #expect(rows([]).isEmpty)
        #expect(cache.hiddenExtension == nil)
    }

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

    @Test("bulk apply contains only differences and reverting removes the action")
    func bulkChanges() {
        let session = TorrentFileEditSession()
        let current = [0: true, 1: true]
        #expect(!session.hasChanges)
        session.stageAll(true, current: current, for: "one")
        #expect(!session.hasChanges)
        session.stageAll(false, current: current, for: "one")
        #expect(session.wanted["one"] == [0: false, 1: false])
        session.stageAll(true, current: current, for: "one")
        #expect(!session.hasChanges)
        session.selections = ["one": [0, 1]]
        session.stageAll(false, current: current, for: "one")
        #expect(!session.hasSelection)
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
