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

    @Test("local locations show the Mac name and final folder only")
    func localDirectory() {
        let location = TorrentDownloadLocation(directory: "/Users/test/Downloads", localName: "Studio Mac", link: nil)
        #expect(location.sourceName == "Studio Mac")
        #expect(location.folderName == "Downloads")
        #expect(location.directoryURL?.path == "/Users/test/Downloads")
    }

    @Test("unlinked remote folders offer a share connection")
    func unlinkedDirectory() {
        let location = TorrentDownloadLocation(directory: "/container/downloads/Movies", localName: nil, link: nil)
        #expect(location.sourceName == "Connect share…")
        #expect(location.folderName == "Movies")
        #expect(location.directoryURL == nil)
    }
}
