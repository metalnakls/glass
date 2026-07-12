import Foundation

@MainActor
public final class GlassOpenURLRouter {
    public static let shared = GlassOpenURLRouter()

    private var pendingURLs: [URL] = []
    private var handler: (@MainActor ([URL]) -> Void)?

    private init() {}

    public func register(_ handler: @escaping @MainActor ([URL]) -> Void) {
        self.handler = handler
        guard !pendingURLs.isEmpty else { return }
        let urls = pendingURLs
        pendingURLs = []
        handler(urls)
    }

    public func open(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        if let handler {
            handler(urls)
        } else {
            pendingURLs.append(contentsOf: urls)
        }
    }
}

extension Notification.Name {
    public static let glassCommandAddServer = Notification.Name("GlassCommandAddServer")
    public static let glassCommandAddMagnet = Notification.Name("GlassCommandAddMagnet")
    public static let glassCommandAddTorrentFile = Notification.Name("GlassCommandAddTorrentFile")
    public static let glassCommandToggleDownloadingFilter = Notification.Name("GlassCommandToggleDownloadingFilter")
    public static let glassCommandRemoveSelectedTorrent = Notification.Name("GlassCommandRemoveSelectedTorrent")
    public static let glassCommandRemoveSelectedTorrentAndData = Notification.Name("GlassCommandRemoveSelectedTorrentAndData")
    public static let glassOpenURLs = Notification.Name("GlassOpenURLs")
}
