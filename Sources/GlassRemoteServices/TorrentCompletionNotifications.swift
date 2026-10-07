import Foundation

@MainActor
public protocol TorrentCompletionNotifying: AnyObject {
    func requestAuthorization()
    func notifyTorrentCompleted(name: String)
    func notifyTorrentCompleted(name: String, sourceID: UUID, hashString: String, downloadDirectory: String?)
    func clearBadge()
}

public extension TorrentCompletionNotifying {
    func notifyTorrentCompleted(name: String, sourceID: UUID, hashString: String, downloadDirectory: String?) {
        notifyTorrentCompleted(name: name)
    }
}
