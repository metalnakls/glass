import AppKit
import Foundation
@testable import GlassRemoteUI
import Testing

@MainActor
@Suite("File previews")
struct TorrentThumbnailTests {
    @Test("server paths map by directory components and reject traversal")
    func mapping() {
        let root = URL(fileURLWithPath: "/Volumes/and")
        func mapped(_ directory: String, _ file: String) -> String? {
            TorrentThumbnailFolderLink.fileURL(remoteRoot: "/downloads", localRoot: root, directory: directory, filePath: file)?.path
        }
        #expect(mapped("/downloads", "Fargo/S05E01.mkv") == "/Volumes/and/Fargo/S05E01.mkv")
        #expect(mapped("/downloads/Fargo", "S05E01.mkv") == "/Volumes/and/Fargo/S05E01.mkv")
        #expect(mapped("/downloads-other", "Movie.mkv") == nil)
        #expect(mapped("/downloads", "../Movie.mkv") == nil)
        #expect(mapped("/downloads", "/Movie.mkv") == nil)
        #expect(mapped("/downloads/../private", "Movie.mkv") == nil)
    }

    @Test("cache identity survives completion changes and separates sources and files")
    func identity() {
        var first = input(directory: "/downloads")
        let second = TorrentThumbnailInput(sourceID: first.sourceID, hashString: first.hashString,
            downloadDirectory: first.downloadDirectory, filePath: first.filePath, length: first.length, isComplete: false)
        #expect(first.key == second.key)
        let other = input(directory: "/downloads")
        #expect(first.key != other.key)
        first.isLocal = true
        #expect(first.key == second.key)
    }

    @Test("concurrent rows share a request and cached previews survive a missing file")
    func deduplicationAndOfflineCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        let file = root.appendingPathComponent("Movie.mkv")
        try data.write(to: file)
        let counter = PreviewCounter()
        let suite = "Glass-preview-test-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = root.appendingPathComponent("cache")
        let service = TorrentThumbnailService(defaults: defaults, diskDirectory: cache) { _ in
            await counter.increment()
            try? await Task.sleep(for: .milliseconds(30))
            await counter.end()
            return data
        }
        let request = input(directory: root.path, isLocal: true)
        async let first = service.image(for: request)
        async let second = service.image(for: request)
        let results = await (first, second)
        #expect(results.0 != nil && results.1 != nil)
        #expect(await counter.count == 1)
        async let third = service.image(for: input(directory: root.path, isLocal: true))
        async let fourth = service.image(for: input(directory: root.path, isLocal: true))
        let more = await (third, fourth)
        #expect(more.0 != nil && more.1 != nil)
        #expect(await counter.count == 3)
        #expect(await counter.maximumActive == 1)
        // Wait for the actual persisted pair, rather than assuming background writes completed.
        for _ in 0..<100 {
            if (try? FileManager.default.contentsOfDirectory(atPath: cache.path))?.contains(where: { $0.hasSuffix(".json") }) == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try FileManager.default.removeItem(at: file)
        #expect(await service.image(for: request) != nil)
        let restarted = TorrentThumbnailService(defaults: defaults, diskDirectory: cache) { _ in
            await counter.increment()
            return nil
        }
        #expect(await restarted.image(for: request) != nil)
        #expect(await counter.count == 3)
    }

    @Test("unlinked remote files and incomplete files never invoke a generator")
    func unavailableFiles() async {
        let counter = PreviewCounter()
        let suite = "Glass-preview-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = TorrentThumbnailService(defaults: defaults, diskDirectory: URL(fileURLWithPath: "/tmp/" + suite)) { _ in
            await counter.increment()
            return nil
        }
        let remote = input(directory: "/downloads")
        #expect(await service.image(for: remote) == nil)
        #expect(await service.image(for: remote) == nil)
        #expect(await counter.count == 0)
    }

    private func input(directory: String, isLocal: Bool = false) -> TorrentThumbnailInput {
        TorrentThumbnailInput(sourceID: UUID(), hashString: "movie", downloadDirectory: directory,
            filePath: "Movie.mkv", length: 100, isComplete: true, isLocal: isLocal)
    }
}

private actor PreviewCounter {
    private(set) var count = 0
    private var active = 0
    private(set) var maximumActive = 0
    func increment() { count += 1; active += 1; maximumActive = max(maximumActive, active) }
    func end() { active -= 1 }
}
