import AppKit
import GlassRemoteCore
import GlassRemoteUI
import QuickLookUI

@MainActor
final class GlassMacPlatformIntegration: NSObject, GlassPlatformIntegrating, @preconcurrency QLPreviewPanelDataSource {
    private static let bookmarkDefaultsKey = "Glass.LocalDownloadDirectoryBookmarks"

    private let defaults: UserDefaults
    private var activeSecurityScopedURLs: [String: URL] = [:]
    private var previewURL: URL?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
        restoreSecurityScopedDirectoryAccess()
    }

    func chooseLocalDownloadDirectory(startingAt path: String?) async throws -> String? {
        try await chooseDirectory(startingAt: path, forThumbnails: false)?.path
    }

    func prepareLocalDownloadDirectory(_ path: String) async throws -> String? {
        if FileManager.default.isWritableFile(atPath: path) { return path }
        return try await chooseLocalDownloadDirectory(startingAt: path)
    }

    func chooseThumbnailDirectory() async throws -> URL? {
        try await chooseDirectory(startingAt: nil, forThumbnails: true)
    }

    private func chooseDirectory(startingAt path: String?, forThumbnails: Bool) async throws -> URL? {
        let panel = NSOpenPanel()
        panel.title = glassText(forThumbnails ? "Link Mounted Download Folder" : "Choose Download Folder")
        panel.prompt = glassText("Choose")
        panel.message = glassText(forThumbnails ? "Choose this server’s download folder on a share already mounted on your Mac." : "Glass will keep access to this folder for local downloads.")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true

        if let path, !path.isEmpty {
            let directoryURL = URL(fileURLWithPath: path, isDirectory: true)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory),
               isDirectory.boolValue
            {
                panel.directoryURL = directoryURL
            }
        }

        let response = await withCheckedContinuation { continuation in
            if let window = NSApp.keyWindow {
                panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            } else {
                panel.begin { continuation.resume(returning: $0) }
            }
        }

        guard response == .OK, let url = panel.url else { return nil }
        if !forThumbnails { try retainSecurityScopedAccess(to: url) }
        return url
    }

    func canRevealDownloadedItem(for torrent: TorrentSummary) -> Bool {
        revealURL(for: torrent) != nil
    }

    func revealDownloadedItem(for torrent: TorrentSummary) {
        guard let url = revealURL(for: torrent) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func canPreviewDownloadedItem(for torrent: TorrentSummary) -> Bool {
        guard let url = downloadedItemURL(for: torrent) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    func previewDownloadedItem(for torrent: TorrentSummary) {
        guard
            let url = downloadedItemURL(for: torrent),
            FileManager.default.fileExists(atPath: url.path),
            let panel = QLPreviewPanel.shared()
        else {
            return
        }

        if panel.isVisible, previewURL == url {
            panel.orderOut(nil)
            return
        }

        previewURL = url
        NSApp.activate()
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURL == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        previewURL as NSURL?
    }

    private func downloadedItemURL(for torrent: TorrentSummary) -> URL? {
        guard
            let downloadDirectory = torrent.downloadDir?.trimmingCharacters(in: .whitespacesAndNewlines),
            !downloadDirectory.isEmpty,
            !torrent.name.isEmpty
        else {
            return nil
        }

        let directoryURL = URL(fileURLWithPath: downloadDirectory, isDirectory: true).standardizedFileURL
        let itemURL = directoryURL.appendingPathComponent(torrent.name).standardizedFileURL
        let directoryPrefix = directoryURL.path.hasSuffix("/") ? directoryURL.path : directoryURL.path + "/"
        guard itemURL.path.hasPrefix(directoryPrefix) else { return nil }
        return itemURL
    }

    private func revealURL(for torrent: TorrentSummary) -> URL? {
        if let itemURL = downloadedItemURL(for: torrent),
           FileManager.default.fileExists(atPath: itemURL.path)
        {
            return itemURL
        }

        guard
            let downloadDirectory = torrent.downloadDir?.trimmingCharacters(in: .whitespacesAndNewlines),
            !downloadDirectory.isEmpty
        else {
            return nil
        }
        let directoryURL = URL(fileURLWithPath: downloadDirectory, isDirectory: true)
        return FileManager.default.fileExists(atPath: directoryURL.path) ? directoryURL : nil
    }

    private func retainSecurityScopedAccess(to url: URL) throws {
        let bookmarkData = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        var isStale = false
        let retainedURL = try URL(resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &isStale)
        // Keep the resolved scope alive for libtransmission’s asynchronous writes.
        startAccessingIfNeeded(retainedURL)
        guard FileManager.default.isWritableFile(atPath: retainedURL.path) else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: retainedURL.path])
        }
        var bookmarks = storedBookmarks
        bookmarks[retainedURL.path] = bookmarkData.base64EncodedString()
        defaults.set(bookmarks, forKey: Self.bookmarkDefaultsKey)
    }

    private func restoreSecurityScopedDirectoryAccess() {
        var refreshedBookmarks = storedBookmarks

        for (storedPath, encodedBookmark) in storedBookmarks {
            guard let data = Data(base64Encoded: encodedBookmark) else {
                refreshedBookmarks[storedPath] = nil
                continue
            }

            do {
                var isStale = false
                let url = try URL(
                    resolvingBookmarkData: data,
                    options: [.withSecurityScope, .withoutUI],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                startAccessingIfNeeded(url)

                if isStale || storedPath != url.path {
                    let refreshedData = try url.bookmarkData(
                        options: .withSecurityScope,
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    )
                    refreshedBookmarks[storedPath] = nil
                    refreshedBookmarks[url.path] = refreshedData.base64EncodedString()
                }
            } catch {
                // A temporarily unavailable volume must not erase the user’s grant.
                // Selecting this saved folder will offer the native picker again.
                continue
            }
        }

        defaults.set(refreshedBookmarks, forKey: Self.bookmarkDefaultsKey)
    }

    private var storedBookmarks: [String: String] {
        defaults.dictionary(forKey: Self.bookmarkDefaultsKey) as? [String: String] ?? [:]
    }

    private func startAccessingIfNeeded(_ url: URL) {
        let path = url.path
        guard activeSecurityScopedURLs[path] == nil else { return }
        if url.startAccessingSecurityScopedResource() {
            activeSecurityScopedURLs[path] = url
        }
    }
}
