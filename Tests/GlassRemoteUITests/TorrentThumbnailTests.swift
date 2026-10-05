import AppKit
import Foundation
@testable import GlassRemoteUI
import GlassRemoteCore
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


    @Test("a folder-named torrent resolves to the video inside its file list")
    func folderNamedTorrent() {
        let sourceID = UUID()
        let torrent = summary(name: "Mosquito Coast", fileCount: 1)
        // Without the file list there is nothing real to point at, so no path is fabricated.
        #expect(TorrentThumbnailInput.movie(torrent, sourceID: sourceID) == nil)

        let service = makeService()
        #expect(service.noteFileList([file("Mosquito Coast/Mosquito Coast.mkv", 1_400_000_000)],
            forHashString: torrent.hashString, sourceID: sourceID))
        let input = service.thumbnailInput(for: torrent, sourceID: sourceID)
        #expect(input?.filePath == "Mosquito Coast/Mosquito Coast.mkv")
        #expect(input?.downloadDirectory == "/downloads")
    }

    @Test("a multi-file torrent prefers the largest video and skips sidecars and samples")
    func largestVideoWins() {
        let sourceID = UUID()
        let service = makeService()
        let hash = "multi"
        service.noteFileList([
            file("Show/S01E01.mkv", 700_000_000),
            file("Show/S01E01.srt", 40_000),
            file("Show/Sample/S01E01-sample.mkv", 900_000_000),
            file("Show/cover.jpg", 2_000_000),
            file("Show/readme.nfo", 1_000),
            file("Show/S01E02.mkv", 750_000_000),
        ], forHashString: hash, sourceID: sourceID)
        let input = service.thumbnailInput(for: summary(name: "Show", fileCount: 6, hash: hash), sourceID: sourceID)
        // The 900 MB sample loses on eligibility even though it is the largest file.
        #expect(input?.filePath == "Show/S01E02.mkv")
    }

    @Test("non-media suffixes never resolve to a preview")
    func nonMediaRejected() {
        for suffix in ["srt", "sub", "idx", "txt", "nfo", "jpg", "png", "iso", "zip"] {
            #expect(!TorrentThumbnailInput.isPreviewableVideo("File.\(suffix)"))
            #expect(TorrentThumbnailInput.bestVideoPath(in: [file("File.\(suffix)", 9_000_000_000)]) == nil)
        }
        #expect(TorrentThumbnailInput.bestVideoPath(in: []) == nil)
        // Audio is never an artwork source even though the display policy treats it as media.
        #expect(!TorrentThumbnailInput.isPreviewableVideo("Track.mp3"))
    }

    @Test("naming, suffix display and previews share one media vocabulary")
    func sharedMediaVocabulary() {
        // The three features derive from one set in TorrentNameCleaner. Audio is
        // display-only: it may hide its suffix but can never yield a video frame.
        #expect(TorrentExtensionPolicy.mediaExtensions == TorrentNameCleaner.mediaExtensions)
        #expect(TorrentThumbnailInput.previewableExtensions == TorrentNameCleaner.previewableExtensions)
        #expect(TorrentNameCleaner.previewableExtensions == TorrentNameCleaner.videoExtensions)
        #expect(TorrentNameCleaner.mediaExtensions == TorrentNameCleaner.videoExtensions.union(["flac", "mp3", "wav"]))
        #expect(TorrentNameCleaner.mediaExtensions.isSuperset(of: TorrentNameCleaner.videoExtensions))
        for suffix in TorrentNameCleaner.videoExtensions {
            #expect(TorrentNameCleaner.isVideoFile("File.\(suffix)"))
            #expect(TorrentNameCleaner.isPreviewableVideo("File.\(suffix)"))
            #expect(TorrentNameCleaner.isVideoFile("File.\(suffix.uppercased())"))
            #expect(TorrentThumbnailInput.isPreviewableVideo("File.\(suffix)"))
            #expect(TorrentExtensionPolicy.hiddenExtension(paths: ["File.\(suffix)"]) == suffix)
        }
        for suffix in ["flac", "mp3", "wav"] {
            #expect(!TorrentNameCleaner.isVideoFile("Track.\(suffix)"))
            #expect(!TorrentThumbnailInput.isPreviewableVideo("Track.\(suffix)"))
            #expect(TorrentExtensionPolicy.hiddenExtension(paths: ["Track.\(suffix)"]) == suffix)
        }
        for suffix in ["srt", "sub", "idx", "txt", "nfo", "jpg", "png", "iso", "zip", "rar", "7z"] {
            #expect(!TorrentNameCleaner.isVideoFile("File.\(suffix)"))
            #expect(!TorrentThumbnailInput.isPreviewableVideo("File.\(suffix)"))
            #expect(TorrentExtensionPolicy.hiddenExtension(paths: ["File.\(suffix)"]) == nil)
        }
    }

    @Test("only relative, traversal-free paths are cached and resolved")
    func traversalSafe() {
        #expect(TorrentThumbnailInput.isSafeRelativePath("Mosquito Coast/Mosquito Coast.mkv"))
        #expect(!TorrentThumbnailInput.isSafeRelativePath("/etc/passwd.mkv"))
        #expect(!TorrentThumbnailInput.isSafeRelativePath("../../etc/passwd.mkv"))
        #expect(!TorrentThumbnailInput.isSafeRelativePath("Mosquito Coast/../../passwd.mkv"))
        #expect(TorrentThumbnailInput.bestVideoPath(in: [file("../Escape.mkv", 9_000_000_000)]) == nil)
        #expect(TorrentThumbnailInput.bestVideoPath(in: [file("/etc/passwd.mkv", 9_000_000_000)]) == nil)
        // A traversal attempt still dies on the existing share guard.
        #expect(TorrentThumbnailFolderLink.fileURL(remoteRoot: "/downloads", localRoot: URL(fileURLWithPath: "/Volumes/and"),
            directory: "/downloads", filePath: "../Escape.mkv") == nil)
    }

    @Test("the cache reports change once and remembers resolved torrents")
    func cacheRevisionAndBounding() {
        let service = makeService()
        let sourceID = UUID()
        let torrent = summary(name: "Mosquito Coast", fileCount: 1)
        let revision = service.revision
        let files = [file("Mosquito Coast/Mosquito Coast.mkv", 1_000)]
        #expect(!service.needsFileList(torrent, sourceID: sourceID))
        #expect(service.needsFileList(summary(name: "Mosquito Coast", fileCount: nil), sourceID: sourceID))
        #expect(service.noteFileList(files, forHashString: torrent.hashString, sourceID: sourceID))
        #expect(service.revision == revision + 1)
        // The same list again must not invalidate rows.
        #expect(!service.noteFileList(files, forHashString: torrent.hashString, sourceID: sourceID))
        #expect(service.revision == revision + 1)
        #expect(!service.needsFileList(torrent, sourceID: sourceID))
        // Named videos and single-file torrents never need the list in the first place.
        #expect(!service.needsFileList(summary(name: "Movie.mkv", fileCount: 1), sourceID: sourceID))
        #expect(!service.needsFileList(summary(name: "Single", fileCount: 1), sourceID: sourceID))
    }

    private func makeService() -> TorrentThumbnailService {
        let suite = "Glass-preview-resolve-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return TorrentThumbnailService(defaults: defaults,
            diskDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }

    private func file(_ name: String, _ length: UInt64) -> TorrentFile {
        TorrentFile(name: name, length: length, bytesCompleted: length)
    }

    private func summary(name: String, fileCount: Int?, hash: String = "hash") -> TorrentSummary {
        TorrentSummary(id: 1, hashString: hash, name: name, status: 0, percentDone: 1,
            rateDownload: 0, rateUpload: 0, sizeWhenDone: 1_400_000_000, leftUntilDone: 0, eta: -1,
            uploadRatio: 0, peersConnected: 0, downloadDir: "/downloads", fileCount: fileCount)
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
