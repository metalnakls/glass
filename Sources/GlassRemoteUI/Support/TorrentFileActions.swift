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

    /// Space-key Quick Look is available only for a completed, readable file at its mapped location.
    /// Both bookmark resolution and filesystem checks run on the file-actions queue.
    func previewIfAvailable(sourceID: UUID, directory: String, path: String, isLocal: Bool,
                            expectedSize: UInt64, originatingWindow: NSWindow,
                            isStillEligible: @MainActor () -> Bool) async {
        guard expectedSize > 0, TorrentThumbnailInput.isPreviewableVideo(path) else { return }
        revision += 1
        let token = revision
        let resolved: (URL, URL?)
        do {
            resolved = try await resolveFile(sourceID: sourceID, directory: directory, path: path,
                isLocal: isLocal, expectedSize: expectedSize)
        } catch {
            return
        }
        guard token == revision, isStillEligible(),
              TorrentKeyboardQuickLookPolicy.requestStillBelongs(
                to: originatingWindow, currentKeyWindow: NSApp.keyWindow,
                applicationIsActive: NSApp.isActive
              ),
              !TorrentKeyboardQuickLookPolicy.isTextInputFirstResponder(NSApp.keyWindow?.firstResponder) else {
            resolved.1?.stopAccessingSecurityScopedResource()
            return
        }
        showPreview(resolved.0, scope: resolved.1)
    }

    func perform(_ action: Action, sourceID: UUID, directory: String, path: String, isLocal: Bool) async throws {
        revision += 1
        let token = revision
        let resolved: (URL, URL?)
        do {
            resolved = try await resolveFile(sourceID: sourceID, directory: directory, path: path, isLocal: isLocal)
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            guard token == revision else { return }
            if action == .preview { showEmptyPreview(); return }
            throw error
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
            showPreview(resolved.0, scope: resolved.1)
        }
    }

    private func resolveFile(sourceID: UUID, directory: String, path: String, isLocal: Bool,
                             expectedSize: UInt64? = nil) async throws -> (URL, URL?) {
        let link = isLocal ? nil : TorrentThumbnailService.shared.link(for: sourceID)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                var scope: URL?
                do {
                    let root: URL
                    let remoteRoot: String
                    if isLocal {
                        root = URL(fileURLWithPath: directory, isDirectory: true)
                        remoteRoot = directory
                    } else {
                        guard let link else { throw CocoaError(.fileNoSuchFile) }
                        var stale = false
                        root = try URL(resolvingBookmarkData: link.bookmark,
                            options: [.withSecurityScope, .withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale)
                        remoteRoot = link.remoteRoot
                        if root.startAccessingSecurityScopedResource() { scope = root }
                    }
                    let url = path == "."
                        ? TorrentThumbnailFolderLink.directoryURL(remoteRoot: remoteRoot, localRoot: root, directory: directory)
                        : TorrentThumbnailFolderLink.fileURL(remoteRoot: remoteRoot, localRoot: root, directory: directory, filePath: path)
                    guard let url, FileManager.default.fileExists(atPath: url.path) else {
                        throw CocoaError(.fileNoSuchFile)
                    }
                    if let expectedSize, !TorrentKeyboardQuickLookPolicy.fileIsAvailable(at: url, expectedSize: expectedSize) {
                        throw CocoaError(.fileNoSuchFile)
                    }
                    continuation.resume(returning: (url, scope))
                } catch {
                    scope?.stopAccessingSecurityScopedResource()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func showPreview(_ url: URL, scope: URL?) {
        guard let panel = QLPreviewPanel.shared() else { scope?.stopAccessingSecurityScopedResource(); return }
        if panel.isVisible, previewURL == url {
            panel.orderOut(nil)
            previewScope?.stopAccessingSecurityScopedResource(); previewScope = nil; previewURL = nil
            scope?.stopAccessingSecurityScopedResource()
            return
        }
        previewScope?.stopAccessingSecurityScopedResource()
        previewScope = scope; previewURL = url
        panel.dataSource = self
        panel.reloadData(); panel.makeKeyAndOrderFront(nil)
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
