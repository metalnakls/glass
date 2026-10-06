import AppKit
@preconcurrency import AVFoundation
import MediaToolbox
import VideoToolbox
import CryptoKit
import Darwin
import Foundation
import GlassRemoteCore
import GlassRemoteServices
import Observation
@preconcurrency import QuickLookThumbnailing

struct TorrentThumbnailInput: Hashable, Sendable {
    let sourceID: UUID
    let hashString: String
    let downloadDirectory: String
    let filePath: String
    let length: UInt64
    let isComplete: Bool
    var isLocal = false

    var key: String {
        let value = "\(sourceID)|\(hashString)|\(downloadDirectory)|\(filePath)|\(length)|72-v1"
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Resolves the video path for a row without touching the network or the disk.
    ///
    /// A torrent name such as `Mosquito Coast` carries no media suffix, and multi-file torrents
    /// nest the movie under a folder, so the resolved file list is consulted first. The torrent's
    /// own name is used only when it already names a supported video. Nothing is ever guessed.
    static func movie(_ torrent: TorrentSummary, sourceID: UUID, isLocal: Bool = false) -> Self? {
        guard let directory = torrent.downloadDir else { return nil }
        let resolved = isPreviewableVideo(torrent.name) ? torrent.name : nil
        guard let path = resolved, isSafeRelativePath(path) else { return nil }
        return Self(sourceID: sourceID, hashString: torrent.hashString, downloadDirectory: directory,
                    filePath: path, length: torrent.sizeWhenDone, isComplete: torrent.isCompleted, isLocal: isLocal)
    }

    /// Previewable video only. Subtitles, artwork, disc images and archives are never eligible, and
    /// audio is deliberately excluded because artwork extraction needs video frames. The set itself
    /// lives in `TorrentNameCleaner` so naming, suffix display and previews cannot drift apart.
    static let previewableExtensions = TorrentNameCleaner.previewableExtensions

    static func isPreviewableVideo(_ path: String) -> Bool {
        TorrentNameCleaner.isPreviewableVideo(path)
    }

    /// A path only reaches `TorrentThumbnailFolderLink.fileURL` when it is relative and free of `..`.
    /// That function stays the single traversal guard for every resolved file.
    static func isSafeRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.split(separator: "/").contains("..")
    }

    /// The largest playable video inside a torrent. Sidecars and samples lose on eligibility before
    /// size is considered, so a bundled trailer never outranks the feature presentation.
    static func bestVideoPath(in files: [TorrentFile]) -> String? {
        files.filter { file in
            isPreviewableVideo(file.name) && isSafeRelativePath(file.name) && !isSample(file.name)
        }.max { $0.length < $1.length }?.name
    }

    private static let sampleTokens: Set<String> = ["sample", "trailer", "preview", "teaser", "proof"]

    private static func isSample(_ path: String) -> Bool {
        let stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent.lowercased()
        let tokens = Set(stem.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        return !tokens.isDisjoint(with: sampleTokens)
    }
}

struct TorrentThumbnailFolderLink: Codable, Sendable, Equatable {
    let remoteRoot: String
    let localPath: String
    let bookmark: Data

    static func directoryURL(remoteRoot: String, localRoot: URL, directory: String) -> URL? {
        fileURL(remoteRoot: remoteRoot, localRoot: localRoot, directory: directory, filePath: ".glass-location")?.deletingLastPathComponent()
    }

    static func fileURL(remoteRoot: String, localRoot: URL, directory: String, filePath: String) -> URL? {
        guard remoteRoot.hasPrefix("/"), directory.hasPrefix("/"), !filePath.isEmpty else { return nil }
        let remote = URL(fileURLWithPath: remoteRoot, isDirectory: true).standardizedFileURL.path
        let folder = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL.path
        guard folder == remote || folder.hasPrefix(remote == "/" ? "/" : remote + "/"),
              !filePath.hasPrefix("/"), !filePath.split(separator: "/").contains("..") else { return nil }
        let suffix = String(folder.dropFirst(remote.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let root = localRoot.standardizedFileURL
        let url = root.appendingPathComponent(suffix, isDirectory: true).appendingPathComponent(filePath).standardizedFileURL
        guard url.path.hasPrefix(root.path == "/" ? "/" : root.path + "/") else { return nil }
        return url
    }
}

private struct ThumbnailStamp: Codable, Sendable, Equatable {
    let size: Int
    let modified: Date
    var checked: Date
}

private struct ThumbnailDiskResult: Sendable {
    let data: Data
    let stamp: ThumbnailStamp
}

@MainActor
@Observable
final class TorrentThumbnailService {
    static let shared = TorrentThumbnailService()
    private(set) var revision = 0
    private(set) var links: [String: TorrentThumbnailFolderLink] = [:]
    private var mountedPaths = TorrentThumbnailService.mountedVolumePaths()
    @ObservationIgnored private let generationOverride: (@Sendable (URL) async -> Data?)?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let diskDirectory: URL
    @ObservationIgnored private let images = NSCache<NSString, CachedThumbnail>()
    // Stable keys avoid repeating SHA-256 and hex formatting during row updates.
    @ObservationIgnored private var lookupKeys: [TorrentThumbnailInput: String] = [:]
    /// Video path per torrent, filled in the background by the preloader. `nil` means "not resolved yet"
    /// and `""` means "resolved, nothing previewable inside" so a torrent is only asked once.
    @ObservationIgnored private var videoPaths: [String: String] = [:]
    @ObservationIgnored private var failures: [String: Date] = [:]
    @ObservationIgnored private var pending: [String: Work] = [:]
    @ObservationIgnored private var queue: [String] = []
    @ObservationIgnored private var writes = 0
    @ObservationIgnored private var active: String?
    @ObservationIgnored private var notifications: [NSObjectProtocol] = []
    @ObservationIgnored private let diskQueue = DispatchQueue(label: "Glass.thumbnail-cache", qos: .utility)
    // A stuck SMB metadata lookup occupies this one lane instead of the main thread or an expanding task pool.
    @ObservationIgnored private let fileQueue = DispatchQueue(label: "Glass.thumbnail-file", qos: .utility)
    private static let defaultsKey = "Glass.ThumbnailFolderLinks"
    private static let freshness: TimeInterval = 6 * 60 * 60

    private final class CachedThumbnail {
        let image: NSImage
        let stamp: ThumbnailStamp
        init(image: NSImage, stamp: ThumbnailStamp) { self.image = image; self.stamp = stamp }
    }

    @MainActor private final class Work {
        let input: TorrentThumbnailInput
        let fallback: ThumbnailDiskResult?
        var subscribers: [UUID: CheckedContinuation<NSImage?, Never>] = [:]
        var video: AVAssetImageGenerator?
        var videoTask: Task<Void, Never>?
        var request: QLThumbnailGenerator.Request?
        var timeout: Task<Void, Never>?
        init(input: TorrentThumbnailInput, fallback: ThumbnailDiskResult?) {
            self.input = input; self.fallback = fallback
        }
    }

    init(defaults: UserDefaults = .standard, diskDirectory: URL? = nil, generationOverride: (@Sendable (URL) async -> Data?)? = nil) {
        self.generationOverride = generationOverride
        self.defaults = defaults
        self.diskDirectory = diskDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Glass/Thumbnails", isDirectory: true)
        _ = NativeLocationIconCache.shared
        images.totalCostLimit = 16 * 1024 * 1024
        images.countLimit = 512
        if let data = defaults.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([String: TorrentThumbnailFolderLink].self, from: data) {
            links = saved
        }
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            notifications.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.mountedPaths = Self.mountedVolumePaths()
                    self?.failures.removeAll()
                    self?.revision &+= 1
                }
            })
        }
    }

    isolated deinit {
        for token in notifications { NSWorkspace.shared.notificationCenter.removeObserver(token) }
    }

    // Enumerating installed media extensions crosses XPC; never register on the main actor.
    private static let mediaRegistration = Task.detached(priority: .utility) {
        MTRegisterProfessionalVideoWorkflowFormatReaders()
        VTRegisterProfessionalVideoWorkflowVideoDecoders()
    }

    func link(for sourceID: UUID) -> TorrentThumbnailFolderLink? { links[sourceID.uuidString] }

    /// The library model, used only to reach a torrent's file list off the viewport path.
    /// Held weakly: the model owns the view that owns this service.
    @ObservationIgnored private weak var model: RemoteAppModel?

    func attach(model: RemoteAppModel?) { self.model = model }

    /// Resolves one torrent's file list without touching the inspector's selection cache.
    func resolveFileList(hashString: String, sourceID: UUID) async {
        guard let model, let files = try? await model.fetchFilesOnly(hashString: hashString, sourceID: sourceID) else { return }
        noteFileList(files, forHashString: hashString, sourceID: sourceID)
    }

    private static func videoKey(sourceID: UUID, hashString: String) -> String { "\(sourceID.uuidString)|\(hashString)" }

    private static let videoPathLimit = 2048

    /// The cached path takes precedence over a bare torrent name, so a torrent whose movie sits
    /// inside a folder resolves from its file list instead of pointing at the folder itself.
    func thumbnailInput(for torrent: TorrentSummary, sourceID: UUID, isLocal: Bool = false) -> TorrentThumbnailInput? {
        guard let directory = torrent.downloadDir else { return nil }
        let path = resolvedVideoPath(for: torrent.hashString, sourceID: sourceID)
            ?? (TorrentThumbnailInput.isPreviewableVideo(torrent.name) ? torrent.name : nil)
        guard let path, TorrentThumbnailInput.isSafeRelativePath(path) else { return nil }
        return TorrentThumbnailInput(sourceID: sourceID, hashString: torrent.hashString,
            downloadDirectory: directory, filePath: path, length: torrent.sizeWhenDone,
            isComplete: torrent.isCompleted, isLocal: isLocal)
    }

    /// Stores the best video path for a torrent. Opportunistic: rows never wait on it, and the
    /// revision only moves when a row that previously showed a generic icon gains a real path.
    @discardableResult
    func noteFileList(_ files: [TorrentFile], forHashString hashString: String, sourceID: UUID) -> Bool {
        let key = Self.videoKey(sourceID: sourceID, hashString: hashString)
        let path = TorrentThumbnailInput.bestVideoPath(in: files) ?? ""
        guard videoPaths[key] != path else { return false }
        if videoPaths.count >= Self.videoPathLimit, videoPaths[key] == nil {
            videoPaths.removeAll(keepingCapacity: true)
        }
        videoPaths[key] = path
        revision &+= 1
        return true
    }

    /// A torrent whose name carries no media suffix needs its file list before a preview can resolve.
    func needsFileList(_ torrent: TorrentSummary, sourceID: UUID) -> Bool {
        guard torrent.fileCount != 1, torrent.downloadDir != nil else { return false }
        guard !TorrentThumbnailInput.isPreviewableVideo(torrent.name) else { return false }
        return videoPaths[Self.videoKey(sourceID: sourceID, hashString: torrent.hashString)] == nil
    }

    func isShareUnavailable(sourceID: UUID, directory: String?, isLocal: Bool) -> Bool {
        let path: String
        if isLocal {
            guard let directory else { return false }
            path = directory
        } else {
            guard let link = link(for: sourceID) else { return false }
            path = link.localPath
        }
        guard path.hasPrefix("/Volumes/") else { return false }
        return !mountedPaths.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// Resolve bookmarks and check mounted files on the existing background file lane.
    func openDownloadLocation(sourceID: UUID, directory: String, itemPath: String, isLocal: Bool) async throws {
        let link = isLocal ? nil : link(for: sourceID)
        let target = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(target: URL, scope: URL?), Error>) in
            fileQueue.async {
                do {
                    if isLocal {
                        let root = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL
                        let item = root.appendingPathComponent(itemPath).standardizedFileURL
                        guard !itemPath.hasPrefix("/"), !itemPath.split(separator: "/").contains(".."),
                              item.path.hasPrefix(root.path == "/" ? "/" : root.path + "/") else {
                            throw CocoaError(.fileReadInvalidFileName)
                        }
                        let target = FileManager.default.fileExists(atPath: item.path) ? item : root
                        guard FileManager.default.fileExists(atPath: target.path) else { throw CocoaError(.fileNoSuchFile) }
                        continuation.resume(returning: (target, nil))
                    } else {
                        guard let link else { throw CocoaError(.fileNoSuchFile) }
                        var stale = false
                        let root = try URL(resolvingBookmarkData: link.bookmark, options: [.withSecurityScope, .withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale)
                        let scoped = root.startAccessingSecurityScopedResource()
                        guard TorrentThumbnailFolderLink.directoryURL(remoteRoot: link.remoteRoot, localRoot: root, directory: directory) != nil,
                              FileManager.default.fileExists(atPath: root.path) else {
                            if scoped { root.stopAccessingSecurityScopedResource() }
                            throw CocoaError(.fileNoSuchFile)
                        }
                        // Open the mounted share, even when its linked download folder is nested.
                        let components = root.pathComponents
                        let share = components.count > 2 && components[1] == "Volumes"
                            ? URL(fileURLWithPath: "/Volumes").appendingPathComponent(components[2], isDirectory: true) : root
                        continuation.resume(returning: (share, scoped ? root : nil))
                    }
                } catch { continuation.resume(throwing: error) }
            }
        }
        defer { target.scope?.stopAccessingSecurityScopedResource() }
        if isLocal {
            NSWorkspace.shared.activateFileViewerSelecting([target.target])
        } else if !NSWorkspace.shared.open(target.target) {
            throw CocoaError(.fileReadUnknown)
        }
    }

    func updateRemoteRoot(sourceID: UUID, remoteRoot: String) throws {
        guard remoteRoot.hasPrefix("/"), let previous = link(for: sourceID) else { throw CocoaError(.fileReadInvalidFileName) }
        var updated = links
        updated[sourceID.uuidString] = TorrentThumbnailFolderLink(remoteRoot: remoteRoot, localPath: previous.localPath, bookmark: previous.bookmark)
        defaults.set(try JSONEncoder().encode(updated), forKey: Self.defaultsKey)
        links = updated
        lookupKeys.removeAll(keepingCapacity: true)
        videoPaths.removeAll(keepingCapacity: true)
        images.removeAllObjects()
        failures.removeAll()
        cancelAll()
        revision &+= 1
    }

    private func cacheKey(_ input: TorrentThumbnailInput) -> String {
        if let key = lookupKeys[input] { return key }
        let link = link(for: input.sourceID)
        let value = input.key + "|" + (link?.remoteRoot ?? "") + "|" + (link?.localPath ?? "")
        let key = SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        // Bound bookkeeping independently of the image cache for long-running libraries.
        if lookupKeys.count >= 4096 { lookupKeys.removeAll(keepingCapacity: true) }
        lookupKeys[input] = key
        return key
    }

    func setLink(sourceID: UUID, remoteRoot: String, localURL: URL?) async throws {
        var updated = links
        if let localURL {
            let root = remoteRoot.trimmingCharacters(in: .whitespacesAndNewlines)
            guard root.hasPrefix("/") else { throw CocoaError(.fileReadInvalidFileName) }
            let bookmark = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                fileQueue.async {
                    do {
                        continuation.resume(returning: try localURL.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil))
                    } catch { continuation.resume(throwing: error) }
                }
            }
            updated[sourceID.uuidString] = TorrentThumbnailFolderLink(remoteRoot: root, localPath: localURL.path, bookmark: bookmark)
        } else { updated[sourceID.uuidString] = nil }
        defaults.set(try JSONEncoder().encode(updated), forKey: Self.defaultsKey)
        links = updated
        lookupKeys.removeAll(keepingCapacity: true)
        images.removeAllObjects()
        failures.removeAll()
        cancelAll()
        revision &+= 1
    }

    /// Rows pass the torrent-shaped input they were built with; the cached file list may point it
    /// at the real video instead, so resolve before the cache key is derived.
    private func resolved(_ input: TorrentThumbnailInput) -> TorrentThumbnailInput {
        guard let path = resolvedVideoPath(for: input.hashString, sourceID: input.sourceID),
              path != input.filePath else { return input }
        return TorrentThumbnailInput(sourceID: input.sourceID, hashString: input.hashString,
            downloadDirectory: input.downloadDirectory, filePath: path, length: input.length,
            isComplete: input.isComplete, isLocal: input.isLocal)
    }

    private func resolvedVideoPath(for hashString: String, sourceID: UUID) -> String? {
        guard let path = videoPaths[Self.videoKey(sourceID: sourceID, hashString: hashString)],
              !path.isEmpty else { return nil }
        return path
    }

    func cachedImage(for input: TorrentThumbnailInput) -> NSImage? { images.object(forKey: cacheKey(resolved(input)) as NSString)?.image }

    func image(for input: TorrentThumbnailInput) async -> NSImage? {
        let input = resolved(input)
        let key = cacheKey(input)
        if let cached = images.object(forKey: key as NSString), Date().timeIntervalSince(cached.stamp.checked) < Self.freshness {
            return cached.image
        }
        let directory = diskDirectory
        let disk: ThumbnailDiskResult? = await withCheckedContinuation { continuation in
            diskQueue.async { continuation.resume(returning: Self.readDisk(directory: directory, key: key)) }
        }
        guard !Task.isCancelled else { return nil }
        let fallback = disk.flatMap { cache($0, key: key) }
        if let disk, Date().timeIntervalSince(disk.stamp.checked) < Self.freshness { return fallback }
        guard input.isComplete, failures[key].map({ Date().timeIntervalSince($0) < 15 * 60 }) != true else { return fallback }
        let subscriber = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: fallback); return }
                let work = pending[key] ?? Work(input: input, fallback: disk)
                work.subscribers[subscriber] = continuation
                if pending[key] == nil { pending[key] = work; queue.append(key) }
                pump()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(key: key, subscriber: subscriber) }
        }
    }

    func refresh(_ input: TorrentThumbnailInput) async {
        let input = resolved(input)
        let key = cacheKey(input)
        images.removeObject(forKey: key as NSString)
        failures[key] = nil
        let directory = diskDirectory
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            diskQueue.async {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(key + ".png"))
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(key + ".json"))
                continuation.resume()
            }
        }
        revision &+= 1
    }

    private func pump() {
        guard active == nil else { return }
        while let key = queue.first {
            queue.removeFirst()
            guard let work = pending[key], !work.subscribers.isEmpty else { continue }
            active = key
            let link = link(for: work.input.sourceID)
            let input = work.input
            fileQueue.async { [weak self] in
                let resolved = Self.resolve(input: input, link: link)
                Task { @MainActor in self?.resolved(resolved, key: key) }
            }
            return
        }
    }

    private struct ResolvedFile: Sendable {
        let url: URL
        let scope: URL?
        let stamp: ThumbnailStamp
    }

    nonisolated private static func resolve(input: TorrentThumbnailInput, link: TorrentThumbnailFolderLink?) -> ResolvedFile? {
        var scope: URL?
        let url: URL
        if let link {
            var stale = false
            guard let root = try? URL(resolvingBookmarkData: link.bookmark, options: [.withSecurityScope, .withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale),
                  let mapped = TorrentThumbnailFolderLink.fileURL(remoteRoot: link.remoteRoot, localRoot: root, directory: input.downloadDirectory, filePath: input.filePath) else { return nil }
            if root.startAccessingSecurityScopedResource() { scope = root }
            url = mapped
        } else {
            guard input.isLocal, let mapped = TorrentThumbnailFolderLink.fileURL(remoteRoot: input.downloadDirectory, localRoot: URL(fileURLWithPath: input.downloadDirectory), directory: input.downloadDirectory, filePath: input.filePath) else { return nil }
            url = mapped
        }
        guard isMounted(url) else { scope?.stopAccessingSecurityScopedResource(); return nil }
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
              values.isRegularFile == true, let size = values.fileSize, let modified = values.contentModificationDate else {
            scope?.stopAccessingSecurityScopedResource()
            return nil
        }
        return ResolvedFile(url: url, scope: scope, stamp: ThumbnailStamp(size: size, modified: modified, checked: Date()))
    }

    nonisolated private static func isMounted(_ url: URL) -> Bool {
        guard url.path.hasPrefix("/Volumes/") else { return true }
        return mountedVolumePaths().contains { url.path == $0 || url.path.hasPrefix($0 + "/") }
    }

    nonisolated private static func mountedVolumePaths() -> [String] {
        var mounts: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&mounts, MNT_NOWAIT)
        guard let mounts else { return [] }
        return (0..<Int(count)).compactMap { index in
            var name = mounts[index].f_mntonname
            let capacity = MemoryLayout.size(ofValue: name)
            let path = withUnsafePointer(to: &name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
            }
            return path == "/" ? nil : path
        }
    }

    private func resolved(_ file: ResolvedFile?, key: String) {
        guard let work = pending[key], active == key else { file?.scope?.stopAccessingSecurityScopedResource(); return }
        guard !work.subscribers.isEmpty, let file else { file?.scope?.stopAccessingSecurityScopedResource(); finish(key: key, result: work.fallback); return }
        if let existing = work.fallback, existing.stamp.size == file.stamp.size, existing.stamp.modified == file.stamp.modified {
            file.scope?.stopAccessingSecurityScopedResource()
            let refreshed = ThumbnailDiskResult(data: existing.data, stamp: file.stamp)
            save(refreshed, key: key)
            finish(key: key, result: refreshed)
            return
        }
        if let generationOverride {
            work.videoTask = Task { [weak self] in
                let data = await generationOverride(file.url)
                file.scope?.stopAccessingSecurityScopedResource()
                guard let self, self.pending[key] === work else { return }
                let result = !Task.isCancelled ? data.map { ThumbnailDiskResult(data: $0, stamp: file.stamp) } : nil
                if let result { self.save(result, key: key) }
                self.finish(key: key, result: result ?? work.fallback)
            }
            return
        }
        let request = QLThumbnailGenerator.Request(fileAt: file.url, size: CGSize(width: 36, height: 36), scale: 2, representationTypes: .thumbnail)
        work.request = request
        work.timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, self.pending[key] === work else { return }
            QLThumbnailGenerator.shared.cancel(request)
            work.video?.cancelAllCGImageGeneration()
            work.videoTask?.cancel()
            // Scope is released by the completion callback, after Quick Look has stopped using it.
            let fallback = work.fallback.flatMap { self.cache($0, key: key) }
            for continuation in work.subscribers.values { continuation.resume(returning: fallback) }
            work.subscribers.removeAll()
            self.failures[key] = Date()
            // Retain the lane until the provider acknowledges cancellation.
        }
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            let data = representation.flatMap { NSBitmapImageRep(cgImage: $0.cgImage).representation(using: .png, properties: [:]) }
            Task { @MainActor in
                guard let self, self.pending[key] === work else { file.scope?.stopAccessingSecurityScopedResource(); return }
                if data == nil, !work.subscribers.isEmpty {
                    self.generateVideo(file: file, work: work, key: key)
                    return
                }
                file.scope?.stopAccessingSecurityScopedResource()
                if let data {
                    let result = ThumbnailDiskResult(data: data, stamp: file.stamp)
                    self.save(result, key: key)
                    self.finish(key: key, result: result)
                } else { self.finish(key: key, result: work.fallback) }
            }
        }
    }

    private func generateVideo(file: ResolvedFile, work: Work, key: String) {
        work.videoTask = Task { [weak self] in
            defer { file.scope?.stopAccessingSecurityScopedResource() }
            await Self.mediaRegistration.value
            do {
                try Task.checkCancellation()
                let asset = AVURLAsset(url: file.url)
                let generator = AVAssetImageGenerator(asset: asset)
                work.video = generator
                generator.maximumSize = CGSize(width: 72, height: 72)
                generator.appliesPreferredTrackTransform = true
                let duration = try await asset.load(.duration)
                let seconds = duration.seconds.isFinite ? max(0, min(60, duration.seconds * 0.1)) : 0
                let frame = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
                try Task.checkCancellation()
                guard let self, self.pending[key] === work else { return }
                guard let data = NSBitmapImageRep(cgImage: frame.image).representation(using: .png, properties: [:]) else {
                    self.finish(key: key, result: work.fallback)
                    return
                }
                let result = ThumbnailDiskResult(data: data, stamp: file.stamp)
                self.save(result, key: key)
                self.finish(key: key, result: result)
            } catch {
                guard let self, self.pending[key] === work else { return }
                self.finish(key: key, result: work.fallback)
            }
        }
    }

    private func cache(_ result: ThumbnailDiskResult, key: String) -> NSImage? {
        guard let image = NSImage(data: result.data) else { return nil }
        images.setObject(CachedThumbnail(image: image, stamp: result.stamp), forKey: key as NSString, cost: 72 * 72 * 4)
        return image
    }

    private func finish(key: String, result: ThumbnailDiskResult?) {
        guard let work = pending.removeValue(forKey: key) else { return }
        work.timeout?.cancel()
        let image = result.flatMap { cache($0, key: key) }
        if result == nil || result?.stamp == work.fallback?.stamp { failures[key] = Date() }
        if failures.count > 1024 { failures = Dictionary(uniqueKeysWithValues: failures.sorted { $0.value > $1.value }.prefix(1024).map { ($0.key, $0.value) }) }
        for continuation in work.subscribers.values { continuation.resume(returning: image) }
        if active == key { active = nil }
        pump()
    }

    private func cancel(key: String, subscriber: UUID) {
        guard let work = pending[key] else { return }
        work.subscribers.removeValue(forKey: subscriber)?.resume(returning: nil)
        guard work.subscribers.isEmpty else { return }
        work.video?.cancelAllCGImageGeneration()
        work.videoTask?.cancel()
        if let request = work.request {
            QLThumbnailGenerator.shared.cancel(request)
            work.video?.cancelAllCGImageGeneration()
            work.videoTask?.cancel()
            // Keep the active lane until cancellation completes; late callbacks cannot overwrite a replacement request.
        } else if active != key {
            pending[key] = nil
            queue.removeAll { $0 == key }
        }
    }

    private func cancelAll() {
        for (key, work) in pending {
            for subscriber in Array(work.subscribers.keys) { cancel(key: key, subscriber: subscriber) }
        }
    }

    nonisolated private static func readDisk(directory: URL, key: String) -> ThumbnailDiskResult? {
        guard let stampData = try? Data(contentsOf: directory.appendingPathComponent(key + ".json")),
              let stamp = try? JSONDecoder().decode(ThumbnailStamp.self, from: stampData),
              let data = try? Data(contentsOf: directory.appendingPathComponent(key + ".png")) else { return nil }
        return ThumbnailDiskResult(data: data, stamp: stamp)
    }

    private func save(_ result: ThumbnailDiskResult, key: String) {
        let directory = diskDirectory
        writes += 1
        let prune = writes == 1 || writes % 16 == 0
        diskQueue.async {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try result.data.write(to: directory.appendingPathComponent(key + ".png"), options: .atomic)
                try JSONEncoder().encode(result.stamp).write(to: directory.appendingPathComponent(key + ".json"), options: .atomic)
                guard prune else { return }
                let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
                    .filter { $0.pathExtension == "png" }
                    .compactMap { url -> (URL, Int, Date)? in
                        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
                        return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
                    }.sorted { $0.2 > $1.2 }
                var bytes = 0
                for (index, file) in files.enumerated() {
                    bytes += file.1
                    if index >= 2048 || bytes > 100 * 1024 * 1024 {
                        try? FileManager.default.removeItem(at: file.0)
                        try? FileManager.default.removeItem(at: file.0.deletingPathExtension().appendingPathExtension("json"))
                    }
                }
            } catch { /* A cache miss is recoverable; the row retains its generic icon. */ }
        }
    }
}
