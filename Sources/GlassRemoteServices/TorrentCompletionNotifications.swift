import Foundation

@MainActor
public protocol TorrentCompletionNotifying: AnyObject {
    func requestAuthorization()
    func notifyTorrentCompleted(name: String)
    func clearBadge()
}
