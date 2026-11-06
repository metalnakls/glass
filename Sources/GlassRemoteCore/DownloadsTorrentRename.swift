import Foundation
import Darwin

/// Finder can deliver an open event using the name from just before a move.
/// Leave the previous name on the same inode before publishing the new name.
public enum DownloadsTorrentRename {
    private static let attribute = "tsmc.glass.previous-torrent-name"

    public static func move(_ source: URL, to target: URL) throws {
        var status = stat()
        guard lstat(source.path, &status) == 0 else { throw POSIXError(.ENOENT) }
        let value = Data("\(status.st_ino):\(source.lastPathComponent)".utf8)
        try value.withUnsafeBytes {
            guard setxattr(source.path, attribute, $0.baseAddress, value.count, 0, XATTR_NOFOLLOW) == 0
            else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        try FileManager.default.moveItem(at: source, to: target)
    }

    public static func currentURL(forMissing source: URL, in downloads: URL) throws -> URL {
        let folder = downloads.resolvingSymlinksInPath().standardizedFileURL
        guard source.pathExtension.lowercased() == "torrent",
              source.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path == folder.path
        else { throw CocoaError(.fileReadNoSuchFile) }
        let candidates = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])
        let matches = candidates.filter { url in
            guard url.pathExtension.lowercased() == "torrent" else { return false }
            var status = stat()
            guard lstat(url.path, &status) == 0, status.st_mode & S_IFMT == S_IFREG else { return false }
            let expected = Data("\(status.st_ino):\(source.lastPathComponent)".utf8)
            var bytes = Data(count: expected.count)
            let count = bytes.withUnsafeMutableBytes {
                getxattr(url.path, attribute, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW)
            }
            return count == expected.count && bytes == expected
        }
        guard matches.count == 1, let match = matches.first else { throw CocoaError(.fileReadNoSuchFile) }
        return match
    }
}
