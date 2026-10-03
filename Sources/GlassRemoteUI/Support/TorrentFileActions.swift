import AppKit
import Quartz

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
        let resolved = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(URL, URL?), Error>) in
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
                    guard let url = TorrentThumbnailFolderLink.fileURL(remoteRoot: remoteRoot, localRoot: root, directory: directory, filePath: path),
                          FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileNoSuchFile) }
                    continuation.resume(returning: (url, scope))
                } catch { scope?.stopAccessingSecurityScopedResource(); continuation.resume(throwing: error) }
            }
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
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURL == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! { previewURL as NSURL? }
    isolated deinit { previewScope?.stopAccessingSecurityScopedResource() }
}
