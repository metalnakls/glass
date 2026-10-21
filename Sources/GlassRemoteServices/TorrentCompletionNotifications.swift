import Foundation

@MainActor
public protocol TorrentCompletionNotifying: AnyObject {
    func prepareForNewDownload(sourceID: UUID, hashString: String)
    func requestAuthorization()
    func notifyTorrentCompleted(name: String)
    func notifyTorrentCompleted(name: String, sourceID: UUID, hashString: String, downloadDirectory: String?)
    func notifyTorrentCompleted(name: String, displayName: String, fileCount: Int?, filePath: String?, sourceID: UUID, hashString: String, downloadDirectory: String?)
    func notifyTorrentCompleted(name: String, displayName: String, fileCount: Int?, filePath: String?, sourceID: UUID, hashString: String, downloadDirectory: String?, completionDate: Int?)
    func clearBadge()
}

public extension TorrentCompletionNotifying {
    func prepareForNewDownload(sourceID: UUID, hashString: String) {}

    func notifyTorrentCompleted(name: String, displayName: String, fileCount: Int?, filePath: String?, sourceID: UUID, hashString: String, downloadDirectory: String?, completionDate: Int?) {
        notifyTorrentCompleted(name: name, displayName: displayName, fileCount: fileCount, filePath: filePath,
            sourceID: sourceID, hashString: hashString, downloadDirectory: downloadDirectory)
    }

    func notifyTorrentCompleted(name: String, displayName: String, fileCount: Int?, filePath: String?, sourceID: UUID, hashString: String, downloadDirectory: String?) {
        notifyTorrentCompleted(name: name, sourceID: sourceID, hashString: hashString, downloadDirectory: downloadDirectory)
    }

    func notifyTorrentCompleted(name: String, sourceID: UUID, hashString: String, downloadDirectory: String?) {
        notifyTorrentCompleted(name: name)
    }
}
