import AppKit
import GlassRemoteCore
@testable import GlassRemoteUI
import Testing

@Suite("Torrent ghost artwork", .serialized)
struct TorrentGhostIconTests {
    @Test("Ghosts retain transparent space, detail, and different payload silhouettes", arguments: [32, 128, 512])
    @MainActor func artwork(size: Int) async throws {
        _ = NSApplication.shared
        let folder = try #require(await TorrentGhostIcon.image(content: .folder, pixelSize: size))
        let movie = try #require(await TorrentGhostIcon.image(content: .file(name: "Movie.mkv"), pixelSize: size))
        #expect(folder.width == size && movie.width == size)
        #expect(folder.dataProvider?.data != movie.dataProvider?.data)
        let bitmap = NSBitmapImageRep(cgImage: movie)
        #expect(bitmap.colorAt(x: 0, y: 0)?.alphaComponent == 0)
        // The sheet interior is ghosted, not an opaque Finder document.
        #expect((bitmap.colorAt(x: size / 2, y: size / 3)?.alphaComponent ?? 1) < 0.5)
        let ink = try #require(NativeIconGeometry.artwork(for: TorrentFileIconCache.icon(fileName: "Movie.mkv", isFolder: false)))
        let pixels = try #require(ink.ink.dataProvider?.data) as Data
        #expect(pixels.contains { $0 > 100 }) // file-type glyph/fold survive extraction
    }

    @Test("Finder writes are idempotent, preserve bytes and respect user icons")
    @MainActor func finderMetadata() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Movie.torrent")
        let data = Data("d4:infod6:lengthi123e4:name9:Movie.MKVee".utf8)
        try data.write(to: url)
        let modified = try #require(url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        let writer = TorrentFinderIconWriter()
        #expect(await writer.apply(to: url, content: .file(name: "Movie.MKV"), modified: modified) == .applied)
        #expect(try Data(contentsOf: url) == data)
        #expect(await writer.apply(to: url, content: .file(name: "Movie.MKV"), modified: modified) == .current)
        // A custom replacement must not be overwritten, even after Glass wrote one.
        #expect(NSWorkspace.shared.setIcon(NSWorkspace.shared.icon(for: .folder), forFile: url.path, options: []))
        #expect(await writer.apply(to: url, content: .file(name: "Other.pdf"), modified: modified) == .preserved)
        #expect(try Data(contentsOf: url) == data)
    }
}
