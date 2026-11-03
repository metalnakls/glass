import Foundation
import GlassRemoteCore
@testable import GlassRemoteUI
import Testing

struct TorrentFinderMetadataTests {
    @Test func onlyCompletedMKVs() {
        #expect(TorrentFinderMetadata.shouldHideExtension(.init(name: "Movie.MKV", length: 10, bytesCompleted: 10)))
        for name in ["Movie.mkv.part", "Movie.mp4", "../Movie.mkv", "/Movie.mkv"] {
            #expect(!TorrentFinderMetadata.shouldHideExtension(.init(name: name, length: 10, bytesCompleted: 10)))
        }
        #expect(!TorrentFinderMetadata.shouldHideExtension(.init(name: "Movie.mkv", length: 10, bytesCompleted: 9)))
    }

    @Test func mountedSMBFinderFlag() throws {
        guard let paths = ProcessInfo.processInfo.environment["GLASS_TEST_SMB_ROOTS"] else { return }
        for path in paths.split(separator: ":") {
            try checkFinderFlag(in: URL(fileURLWithPath: String(path)))
        }
    }

    @Test func finderFlagPreservesFilenameAndContents() throws {
        try checkFinderFlag(in: FileManager.default.temporaryDirectory)
    }

    private func checkFinderFlag(in parent: URL) throws {
        let root = parent.appendingPathComponent("GlassMetadataTest-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Exercise the remote-directory mapping used for a mounted SMB root.
        let file = try #require(TorrentThumbnailFolderLink.fileURL(remoteRoot: "/server/downloads", localRoot: root,
            directory: "/server/downloads", filePath: "Movie.MKV"))
        let data = Data("movie bytes".utf8)
        try data.write(to: file)
        try TorrentFinderMetadata.hideExtension(at: file, expectedSize: 99)
        #expect(try file.resourceValues(forKeys: [.hasHiddenExtensionKey]).hasHiddenExtension != true)
        try TorrentFinderMetadata.hideExtension(at: file, expectedSize: UInt64(data.count))
        // Use a new URL to avoid Foundation's resource-value cache.
        let fresh = URL(fileURLWithPath: file.path)
        #expect(try fresh.resourceValues(forKeys: [.hasHiddenExtensionKey]).hasHiddenExtension == true)
        #expect(try Data(contentsOf: fresh) == data)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["Movie.MKV"])
        try TorrentFinderMetadata.hideExtension(at: fresh, expectedSize: UInt64(data.count))
    }
}
