import Foundation

/// A suffix is hidden only when every file in the torrent uses the same media type.
enum TorrentExtensionPolicy {
    static let mediaExtensions: Set<String> = ["mkv", "mov", "mp4", "wav", "flac", "mp3"]

    static func hiddenExtension(paths: [String]) -> String? {
        guard let first = paths.first else { return nil }
        let suffix = (first as NSString).pathExtension.lowercased()
        guard mediaExtensions.contains(suffix), paths.allSatisfy({ ($0 as NSString).pathExtension.lowercased() == suffix }) else { return nil }
        return suffix
    }

    static func name(_ name: String, hiding suffix: String?) -> String {
        guard let suffix, (name as NSString).pathExtension.lowercased() == suffix else { return name }
        return (name as NSString).deletingPathExtension
    }
}
