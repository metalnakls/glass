import Foundation

/// A suffix is hidden only when every file in the torrent uses the same media type.
enum TorrentExtensionPolicy {
    /// Playable media containers only. Subtitles, artwork, disc images and archives are never hidden.
    ///
    /// Video entries mirror `TorrentNameCleaner.mediaExtensions`; `divx` and `xvid` cover the
    /// legacy peers of `avi`, and `wav`/`flac`/`mp3` cover audio. Artwork extraction reuses the
    /// video subset via `TorrentThumbnailInput.previewableExtensions`, minus audio.
    static let mediaExtensions: Set<String> = [
        "avi", "divx", "flac", "m2ts", "m4v", "mkv", "mov", "mp3", "mp4",
        "mpeg", "mpg", "ts", "wav", "webm", "xvid"
    ]

    static func hiddenExtension(paths: [String]) -> String? {
        guard let first = paths.first else { return nil }
        let suffix = (first as NSString).pathExtension.lowercased()
        guard mediaExtensions.contains(suffix), paths.allSatisfy({ ($0 as NSString).pathExtension.lowercased() == suffix }) else { return nil }
        return suffix
    }

    static func editedName(_ title: String, original: String, hiding suffix: String?) -> String {
        guard let suffix, (original as NSString).pathExtension.lowercased() == suffix else { return title }
        return (title as NSString).pathExtension.lowercased() == suffix ? title : title + "." + (original as NSString).pathExtension
    }

    static func name(_ name: String, hiding suffix: String?) -> String {
        guard let suffix, (name as NSString).pathExtension.lowercased() == suffix else { return name }
        return (name as NSString).deletingPathExtension
    }
}
