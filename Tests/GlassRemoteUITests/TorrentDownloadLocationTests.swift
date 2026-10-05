import Foundation
@testable import GlassRemoteUI
import Testing

@Suite("Inspector download locations")
struct TorrentDownloadLocationTests {
    @Test("shows the mounted share and folder instead of a container path")
    func mappedShare() {
        let link = TorrentThumbnailFolderLink(remoteRoot: "/data", localPath: "/Volumes/Media/Downloads", bookmark: Data())
        let location = TorrentDownloadLocation(directory: "/data/Movies", localName: nil, link: link)
        #expect(location.sourceName == "Media")
        #expect(location.folderName == "Movies")
        #expect(location.directoryURL?.path == "/Volumes/Media/Downloads/Movies")
        let root = TorrentDownloadLocation(directory: "/data", localName: nil, link: link)
        #expect(root.folderName == "Downloads")
        #expect(root.directoryURL?.path == "/Volumes/Media/Downloads")
    }

    @Test("an unrelated server path cannot open the linked share")
    func unrelatedDirectory() {
        let link = TorrentThumbnailFolderLink(remoteRoot: "/data", localPath: "/Volumes/Media", bookmark: Data())
        #expect(TorrentDownloadLocation(directory: "/data-other/Movies", localName: nil, link: link).directoryURL == nil)
        #expect(TorrentDownloadLocation(directory: "/data/../private", localName: nil, link: link).directoryURL == nil)
    }

    @Test("local locations show the destination folder as the authority")
    func localDirectory() {
        let location = TorrentDownloadLocation(directory: "/Users/test/Downloads", localName: "Studio Mac", link: nil)
        #expect(location.sourceName == "Downloads")
        #expect(location.folderName == "Downloads")
        #expect(location.directoryURL?.path == "/Users/test/Downloads")
    }

    @Test("unlinked remote folders use the server name until a share is mapped")
    func unlinkedDirectory() {
        let location = TorrentDownloadLocation(directory: "/container/downloads/Movies", localName: nil, serverName: "Ultra", link: nil)
        #expect(location.sourceName == "Ultra")
        #expect(location.folderName == "Movies")
        #expect(location.directoryURL == nil)
    }

    @Test("a mapped share owns the label, including nested server folders")
    func shareAuthority() {
        let link = TorrentThumbnailFolderLink(remoteRoot: "/downloads", localPath: "/Volumes/and", bookmark: Data())
        for directory in ["/downloads", "/downloads/Fargo", "/downloads/Fargo/Season 2"] {
            let location = TorrentDownloadLocation(directory: directory, localName: nil, serverName: "Ultra", link: link)
            #expect(location.sourceName == "and")
            #expect(!location.sourceName.contains("\n"))
        }
        let unrelated = TorrentDownloadLocation(directory: "/other", localName: nil, serverName: "Ultra", link: link)
        #expect(unrelated.sourceName == "Ultra")
        #expect(unrelated.directoryURL == nil)
    }

    @Test("local custom folders keep their name without the Mac or parent folder")
    func localAuthority() {
        let location = TorrentDownloadLocation(directory: "/Users/test/Movies/Real Movies", localName: "Studio Mac", link: nil)
        #expect(location.sourceName == "Real Movies")
        #expect(TorrentDownloadLocation.shareName(link: nil, fallback: "Ultra") == "Ultra")
    }
}
