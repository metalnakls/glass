import GlassRemoteCore
import Testing
@testable import GlassRemoteUI

@MainActor
@Suite("Compact file tree")
struct TorrentFileTreeTests {
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
