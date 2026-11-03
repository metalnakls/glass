import Foundation
import GlassRemoteCore
import GlassRemoteServices

/// Finder presentation for completed MKVs. Uses the same authorized SMB mapping
/// as previews; no payload renames, folder crawls, or mount/login prompts.
@MainActor
final class TorrentFinderMetadata {
    private let queue = DispatchQueue(label: "Glass.finder-metadata", qos: .utility)
    private var attempts: [String: Date] = [:]

    func run(model: RemoteAppModel) async {
        while !Task.isCancelled {
            for source in model.sources {
                let local = source.id == model.localSourceID
                let link = local ? nil : TorrentThumbnailService.shared.link(for: source.id)
                guard local || link != nil else { continue }
                let candidates = source.records.filter { !$0.isAdding && $0.summary.percentDone > 0 }
                    .sorted { (attempts[key($0.summary, sourceID: source.id, link: link)] ?? .distantPast)
                        < (attempts[key($1.summary, sourceID: source.id, link: link)] ?? .distantPast) }
                for record in candidates.prefix(32) {
                    guard !Task.isCancelled else { return }
                    let summary = record.summary
                    let key = key(summary, sourceID: source.id, link: link)
                    let interval: TimeInterval = summary.isCompleted ? 300 : 30
                    guard Date.now.timeIntervalSince(attempts[key] ?? .distantPast) >= interval else { continue }
                    attempts[key] = .now
                    guard let directory = summary.downloadDir,
                          let files = try? await model.fetchFilesOnly(hashString: summary.hashString, sourceID: source.id),
                          !Task.isCancelled else { continue }
                    await apply(files: files, directory: directory, link: link)
                }
            }
            // Bound history; old entries can safely be checked again.
            if attempts.count > 4096 { attempts = attempts.filter { Date.now.timeIntervalSince($0.value) < 300 } }
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
        }
    }

    private func key(_ summary: TorrentSummary, sourceID: UUID, link: TorrentThumbnailFolderLink?) -> String {
        "\(sourceID)|\(summary.hashString)|\(summary.downloadDir ?? "")|\(summary.name)|\(summary.isCompleted)|\(link?.localPath ?? "")|\(link?.remoteRoot ?? "")"
    }

    private func apply(files: [TorrentFile], directory: String, link: TorrentThumbnailFolderLink?) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                defer { continuation.resume() }
                var scope: URL?
                defer { scope?.stopAccessingSecurityScopedResource() }
                let root: URL
                if let link {
                    var stale = false
                    guard let resolved = try? URL(resolvingBookmarkData: link.bookmark,
                        options: [.withSecurityScope, .withoutUI, .withoutMounting],
                        relativeTo: nil, bookmarkDataIsStale: &stale),
                        !stale, resolved.startAccessingSecurityScopedResource() else { return }
                    root = resolved
                    scope = resolved
                } else {
                    root = URL(fileURLWithPath: directory, isDirectory: true)
                }
                for file in files where Self.shouldHideExtension(file) {
                    guard let url = TorrentThumbnailFolderLink.fileURL(remoteRoot: link?.remoteRoot ?? directory,
                        localRoot: root, directory: directory, filePath: file.name) else { continue }
                    // A failed/offline SMB write is retried on a later pass.
                    try? Self.hideExtension(at: url, expectedSize: file.length)
                }
            }
        }
    }

    nonisolated static func shouldHideExtension(_ file: TorrentFile) -> Bool {
        file.length > 0 && file.bytesCompleted >= file.length &&
            URL(fileURLWithPath: file.name).pathExtension.lowercased() == "mkv" &&
            TorrentThumbnailInput.isSafeRelativePath(file.name)
    }

    nonisolated static func hideExtension(at url: URL, expectedSize: UInt64) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .hasHiddenExtensionKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size >= 0, UInt64(size) == expectedSize,
              values.hasHiddenExtension != true else { return }
        var changes = URLResourceValues()
        changes.hasHiddenExtension = true
        var target = url
        try target.setResourceValues(changes)
    }
}
