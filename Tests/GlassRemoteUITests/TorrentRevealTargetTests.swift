import Foundation
import Testing
@testable import GlassRemoteUI

struct TorrentRevealTargetTests {
    @Test func partialBecomesCompletedFileAndMissingFilesRevealParent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let group = root.appendingPathComponent("Fargo")
        try FileManager.default.createDirectory(at: group, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let episode = group.appendingPathComponent("S05E01.mkv")
        let partial = group.appendingPathComponent("S05E01.mkv.part")
        try Data([0]).write(to: partial)
        #expect(TorrentThumbnailService.revealTarget(item: episode, root: root) == partial)
        try FileManager.default.moveItem(at: partial, to: episode)
        #expect(TorrentThumbnailService.revealTarget(item: episode, root: root) == episode)
        #expect(TorrentThumbnailService.revealTarget(item: group.appendingPathComponent("Season 2/absent.mkv"), root: root)?.path == group.path)
        #expect(TorrentThumbnailService.revealTarget(item: root.deletingLastPathComponent().appendingPathComponent("outside/absent.mkv"), root: root) == nil)
    }
}
