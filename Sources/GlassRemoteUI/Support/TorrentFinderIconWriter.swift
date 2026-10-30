import AppKit
import CryptoKit
import Darwin
import GlassRemoteCore

/// One serial writer for NSWorkspace custom icons. File contents are never
/// rewritten; Finder stores the image in the file's resource-fork metadata.
actor TorrentFinderIconWriter {
    static let shared = TorrentFinderIconWriter()
    enum Result: Equatable { case applied, current, preserved, failed }
    private let markerName = "tsmc.glass.ghost-icon"

    func apply(to url: URL, content: TorrentIconContent, modified: Date) async -> Result {
        guard content != .unknown else { return .preserved }
        let kind: String
        switch content {
        case .folder: kind = "folder"
        case .file(let name): kind = "file:" + URL(fileURLWithPath: name).pathExtension.lowercased()
        case .unknown: return .preserved
        }
        let version = "6:\(kind):"
        if let result = existingResult(url: url, version: version) { return result }
        guard let image = await TorrentGhostIcon.image(content: content, pixelSize: 512) else { return .failed }
        // Recheck after the actor hop: another scan or the user may have changed
        // the file/icon while Finder artwork was being prepared.
        if let result = existingResult(url: url, version: version) { return result }
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
              values.isRegularFile == true, values.contentModificationDate == modified else { return .failed }
        let icon = NSImage(cgImage: image, size: NSSize(width: 512, height: 512))
        guard NSWorkspace.shared.setIcon(icon, forFile: url.path, options: []),
              let digest = resourceDigest(url) else { return .failed }
        let marker = Data((version + digest).utf8)
        let saved = marker.withUnsafeBytes { bytes in
            setxattr(url.path, markerName, bytes.baseAddress, bytes.count, 0, XATTR_NOFOLLOW)
        }
        return saved == 0 ? .applied : .failed
    }

    private func existingResult(url: URL, version: String) -> Result? {
        let marker = attribute(markerName, url: url).flatMap { String(data: $0, encoding: .utf8) }
        let info = attribute("com.apple.FinderInfo", url: url)
        // Public Finder flags: bytes 8–9, big endian; kHasCustomIcon = 0x0400.
        let hasIcon = info.map { $0.count >= 10 && $0[8] & 0x04 != 0 } ?? false
        guard hasIcon else { return marker == nil ? nil : .preserved }
        guard let marker, let digest = resourceDigest(url), marker.hasSuffix(":" + digest) else {
            return .preserved // An existing or subsequently replaced user icon.
        }
        return marker == version + digest ? .current : nil
    }

    private func resourceDigest(_ url: URL) -> String? {
        attribute("com.apple.ResourceFork", url: url).map {
            SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined()
        }
    }

    private func attribute(_ name: String, url: URL) -> Data? {
        let count = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard count > 0, count <= 2 * 1_024 * 1_024 else { return nil }
        var data = Data(count: count)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, count, 0, XATTR_NOFOLLOW) }
        return read == count ? data : nil
    }
}
