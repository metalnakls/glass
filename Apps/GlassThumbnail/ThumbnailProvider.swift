import Foundation
import QuickLookThumbnailing

final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        // Torrent artwork is a Finder icon, not a document preview. Returning
        // the ghost as a thumbnail makes Finder add a white card and padding.
        // Let Finder display the file's custom icon (or its native fallback)
        // even before the independent Downloads worker has processed it.
        handler(nil, CocoaError(.featureUnsupported))
    }
}
