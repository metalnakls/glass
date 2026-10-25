import Foundation
@testable import GlassRemoteUI
import GlassRemoteCore
import Testing

@Suite("Episode index export safety")
struct ShowEpisodeIndexExporterTests {
    @Test("accepts a nested show root inside the mapped download folder")
    func nestedShowRoot() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let showRoot = root.appendingPathComponent("Series", isDirectory: true)
        try FileManager.default.createDirectory(at: showRoot, withIntermediateDirectories: true)
        try ShowEpisodeIndexExporter.validateExistingPaths(
            showRoot: showRoot,
            downloadRoot: root,
            details: details(directory: root.path, path: "Series/Season 1/Series.S01E01.mkv"),
            prefix: "Series"
        )
    }

    @Test("rejects a media path whose existing symlink escapes the show folder")
    func symlinkEscape() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let showRoot = root.appendingPathComponent("Series", isDirectory: true)
        let season = showRoot.appendingPathComponent("Season 1", isDirectory: true)
        let outside = root.appendingPathComponent("outside.mkv")
        try FileManager.default.createDirectory(at: season, withIntermediateDirectories: true)
        try Data("video".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: season.appendingPathComponent("Series.S01E01.mkv"),
            withDestinationURL: outside
        )

        #expect(throws: ShowEpisodeIndexExporter.ExportError.unsafeExistingPath) {
            try ShowEpisodeIndexExporter.validateExistingPaths(
                showRoot: showRoot,
                downloadRoot: root,
                details: details(directory: root.path, path: "Series/Season 1/Series.S01E01.mkv"),
                prefix: "Series"
            )
        }
    }

    @Test("only replaces a recognized sidecar for the same torrent")
    func replaceableManifestChecks() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent(".yina.json")
        let snapshot = try ShowEpisodeIndex(details: details(directory: root.path, path: "Series.S01E01.mkv"), relativePathPrefix: "")
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: target)
        try ShowEpisodeIndexExporter.validateReplaceableIndex(at: target, expectedHash: snapshot.hashString)

        let unnumberedTarget = root.appendingPathComponent("unnumbered.json")
        let unnumbered = try ShowEpisodeIndex(details: details(directory: root.path, path: "Behind the Scenes.mkv"), relativePathPrefix: "")
        try JSONEncoder().encode(unnumbered).write(to: unnumberedTarget)
        try ShowEpisodeIndexExporter.validateReplaceableIndex(at: unnumberedTarget, expectedHash: unnumbered.hashString)

        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["unrelated"] = true
        try JSONSerialization.data(withJSONObject: object).write(to: target)
        #expect(throws: ShowEpisodeIndexExporter.ExportError.incompatibleExistingIndex) {
            try ShowEpisodeIndexExporter.validateReplaceableIndex(at: target, expectedHash: snapshot.hashString)
        }

        object.removeValue(forKey: "unrelated")
        object["hashString"] = "different"
        try JSONSerialization.data(withJSONObject: object).write(to: target)
        #expect(throws: ShowEpisodeIndexExporter.ExportError.incompatibleExistingIndex) {
            try ShowEpisodeIndexExporter.validateReplaceableIndex(at: target, expectedHash: snapshot.hashString)
        }
    }

    @Test("refuses to read through an existing sidecar symlink")
    func sidecarSymlink() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside.json")
        let destination = root.appendingPathComponent(".yina.json")
        let snapshot = try ShowEpisodeIndex(details: details(directory: root.path, path: "Series.S01E01.mkv"), relativePathPrefix: "")
        try JSONEncoder().encode(snapshot).write(to: outside)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: outside)

        #expect(throws: ShowEpisodeIndexExporter.ExportError.incompatibleExistingIndex) {
            try ShowEpisodeIndexExporter.validateReplaceableIndex(at: destination, expectedHash: snapshot.hashString)
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func details(directory: String, path: String) -> TorrentDetails {
        TorrentDetails(
            id: 1,
            hashString: "ab12cd34",
            name: "Series",
            downloadDir: directory,
            files: [TorrentFile(name: path, length: 100, bytesCompleted: 0)],
            fileStats: [TorrentFileStats(bytesCompleted: 0, wanted: true, priority: 0)]
        )
    }
}
