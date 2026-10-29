import Foundation
import GlassRemoteCore
import GlassRemoteUI
import QuickLookThumbnailing

final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        let url = request.fileURL
        let side = min(request.maximumSize.width, request.maximumSize.height)
        let pixels = Int(min(512, max(16, ceil(side * request.scale))))
        let completion = Completion(handler)
        Task {
            guard let content = await Self.load(url: url),
                  let image = await TorrentGhostIcon.image(content: content, pixelSize: pixels) else {
                completion.call(nil, CocoaError(.fileReadCorruptFile)); return
            }
            let size = CGSize(width: side, height: side)
            let reply = QLThumbnailReply(contextSize: size) { context in
                // Quick Look allocates a scale-adjusted bitmap. Its Core
                // Graphics callback uses that bitmap's coordinates, not the
                // request's point size (otherwise Retina icons fill one quarter).
                context.draw(image, in: context.boundingBoxOfClipPath)
                return true
            }
            reply.extensionBadge = ""
            completion.call(reply, nil)
        }
    }

    @concurrent private static func load(url: URL) async -> TorrentIconContent? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let limit = 8 * 1_024 * 1_024
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let count = values.fileSize, count > 0, count <= limit,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit + 1), data.count <= limit,
              !TorrentMetainfoIdentity.hashes(in: data).isEmpty else { return nil }
        return TorrentMetainfoPreview(data: data)?.iconContent
    }
}

/// Quick Look's completion is called once, after async file loading/rendering.
private final class Completion: @unchecked Sendable {
    private let handler: (QLThumbnailReply?, Error?) -> Void
    init(_ handler: @escaping (QLThumbnailReply?, Error?) -> Void) { self.handler = handler }
    func call(_ reply: QLThumbnailReply?, _ error: Error?) { handler(reply, error) }
}
