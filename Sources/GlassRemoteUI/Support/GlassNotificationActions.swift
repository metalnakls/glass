import Foundation

@MainActor
public func glassOpenCompletedTorrent(sourceID: UUID, directory: String, name: String, isLocal: Bool) async {
    try? await TorrentFileActions.shared.perform(.open, sourceID: sourceID,
        directory: directory, path: name, isLocal: isLocal)
}
