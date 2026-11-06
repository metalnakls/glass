import Foundation
import GlassRemoteCore
import Testing
@testable import GlassRemoteUI

@Suite("Downloads worker imports")
struct DownloadsWorkerImportTests {
    @Test func renamedFileOpensByItsPreviousName() async throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        let original = folder.appendingPathComponent("original.torrent")
        let renamed = folder.appendingPathComponent("clean.torrent")
        let data = Data("d4:infod6:lengthi1e4:name5:Track12:piece lengthi1e6:pieces20:01234567890123456789ee".utf8)
        try data.write(to: original)
        try DownloadsTorrentRename.move(original, to: renamed)
        let draft = try await TorrentFileAddDraft.load(from: original, downloadsDirectory: folder)
        #expect(draft.data == data)
        #expect(draft.sourceURL?.lastPathComponent == renamed.lastPathComponent)
        try fm.copyItem(at: renamed, to: folder.appendingPathComponent("duplicate.torrent"))
        try fm.removeItem(at: renamed)
        #expect(throws: (any Error).self) {
            try DownloadsTorrentRename.currentURL(forMissing: original, in: folder)
        }
    }

    @Test func albumRowsBeginAtContentsAndKeepActualSubfolders() {
        let root = "[2026-05-15] Drake - HABIBTI"
        let paths = ["01. Drake - Rusty Intro.flac", "02. Drake - WNBA.flac", "Artwork/Cover.jpg"]
        let entries = paths.enumerated().map { index, path in
            let entry = TorrentFileBrowserEntry(index: index,
                file: TorrentFile(name: root + "/" + path, length: 100, bytesCompleted: 0), rootName: root)
            return TorrentFileBrowserEntry(grouping: entry, index: index, prefix: "")
        }
        let rows = TorrentFileTreeRow.rows(entries: entries, collapsed: [], query: "")
        #expect(rows.filter(\.isFolder).map(\.name) == ["Artwork"])
        #expect(rows.filter { !$0.isFolder }.map(\.depth) == [0, 0, 1])
        #expect(entries.map(\.originalPath) == paths.map { root + "/" + $0 })
        #expect(TorrentFileBrowserEntry(grouping: entries[0], index: 4, prefix: "Season 1/").displayName == "Season 1/" + paths[0])
    }
}
