import AppKit
import Quartz
import GlassRemoteCore

/// Native file actions share the same mounted-folder mapping as artwork.
@MainActor final class TorrentFileActions: NSObject, @MainActor QLPreviewPanelDataSource {
    enum Action { case preview, open, reveal }
    static let shared = TorrentFileActions()
    private let queue = DispatchQueue(label: "Glass.file-actions", qos: .userInitiated)
    private var previewURL: URL?
    private var previewScope: URL?
    private var revision = 0

    func perform(_ action: Action, sourceID: UUID, directory: String, path: String, isLocal: Bool) async throws {
        revision += 1
        let token = revision
        let link = isLocal ? nil : TorrentThumbnailService.shared.link(for: sourceID)
        let resolved: (URL, URL?)
        do {
        resolved = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(URL, URL?), Error>) in
            queue.async {
                var scope: URL?
                do {
                    let root: URL
                    let remoteRoot: String
                    if isLocal { root = URL(fileURLWithPath: directory, isDirectory: true); remoteRoot = directory }
                    else {
                        guard let link else { throw CocoaError(.fileNoSuchFile) }
                        var stale = false
                        root = try URL(resolvingBookmarkData: link.bookmark,
                            options: [.withSecurityScope, .withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale)
                        remoteRoot = link.remoteRoot
                        if root.startAccessingSecurityScopedResource() { scope = root }
                    }
                    guard let url = path == "."
                        ? TorrentThumbnailFolderLink.directoryURL(remoteRoot: remoteRoot, localRoot: root, directory: directory)
                        : TorrentThumbnailFolderLink.fileURL(remoteRoot: remoteRoot, localRoot: root, directory: directory, filePath: path),
                          FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileNoSuchFile) }
                    continuation.resume(returning: (url, scope))
                } catch { scope?.stopAccessingSecurityScopedResource(); continuation.resume(throwing: error) }
            }
        }
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            guard token == revision else { return }
            showEmptyPreview()
            return
        }
        guard token == revision else { resolved.1?.stopAccessingSecurityScopedResource(); return }
        switch action {
        case .open:
            defer { resolved.1?.stopAccessingSecurityScopedResource() }
            guard NSWorkspace.shared.open(resolved.0) else { throw CocoaError(.fileReadUnknown) }
        case .reveal:
            defer { resolved.1?.stopAccessingSecurityScopedResource() }
            NSWorkspace.shared.activateFileViewerSelecting([resolved.0])
        case .preview:
            guard let panel = QLPreviewPanel.shared() else { resolved.1?.stopAccessingSecurityScopedResource(); return }
            if panel.isVisible, previewURL == resolved.0 {
                panel.orderOut(nil)
                previewScope?.stopAccessingSecurityScopedResource(); previewScope = nil; previewURL = nil
                resolved.1?.stopAccessingSecurityScopedResource()
                return
            }
            previewScope?.stopAccessingSecurityScopedResource()
            previewScope = resolved.1; previewURL = resolved.0
            panel.dataSource = self
            panel.reloadData(); panel.makeKeyAndOrderFront(nil)
        }
    }
    func showEmptyPreview() {
        previewScope?.stopAccessingSecurityScopedResource()
        previewScope = nil
        previewURL = nil
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    static func groupDirectory(_ torrents: [TorrentSummary]) -> String? {
        let roots = torrents.compactMap { torrent -> String? in
            guard let directory = torrent.downloadDir else { return nil }
            guard TorrentArtworkKind.isFolder(name: torrent.name, fileCount: torrent.fileCount) else { return directory }
            return URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(torrent.name).path
        }
        guard roots.count == torrents.count else { return nil }
        return groupDirectory(roots)
    }

    static func groupDirectory(_ directories: [String]) -> String? {
        guard !directories.isEmpty else { return nil }
        var components = URL(fileURLWithPath: directories[0], isDirectory: true).standardizedFileURL.pathComponents
        for directory in directories.dropFirst() {
            let other = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL.pathComponents
            components = Array(zip(components, other).prefix { $0 == $1 }.map { $0.0 })
        }
        guard components.count > 1 else { return nil }
        return NSString.path(withComponents: components)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURL == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! { previewURL as NSURL? }
    isolated deinit { previewScope?.stopAccessingSecurityScopedResource() }
}
