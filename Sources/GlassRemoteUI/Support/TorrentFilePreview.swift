import Foundation
import GlassRemoteCore

struct TorrentFilePreview: Sendable {
    let name: String
    let size: UInt64
    let files: [TorrentFile]

    init(data: Data, fallbackURL: URL?) {
        if let parsed = TorrentMetainfoPreview(data: data) {
            self.name = parsed.name
            self.size = parsed.size
            self.files = parsed.files
            return
        }

        let fallbackName = fallbackURL?.deletingPathExtension().lastPathComponent
        self.name = fallbackName?.isEmpty == false ? fallbackName! : "Torrent File"
        self.size = UInt64(data.count)
        self.files = [TorrentFile(name: self.name, length: self.size, bytesCompleted: 0)]
    }
}
