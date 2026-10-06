import Foundation
import GlassRemoteCore
import Testing

@Suite("Torrent add identity")
struct TorrentAddQueueTests {
    @Test("metainfo identity uses only the original info bytes")
    func metainfoIdentity() {
        let original = Data("d4:infod4:name11:Spider-Noiree".utf8)
        let withTracker = Data("d8:announce12:https://test4:infod4:name11:Spider-Noiree".utf8)
        let hashes = TorrentMetainfoIdentity.hashes(in: original)
        #expect(hashes.contains("aeddfc3b841a0eb14bbb58bc1517c9a78ec5e4b9"))
        #expect(hashes == TorrentMetainfoIdentity.hashes(in: withTracker))
    }

    @Test("truncated, oversized, duplicate info and deeply nested metainfo are rejected")
    func malformedMetainfo() {
        for value in ["d4:infod4:name11:Spider-Noir", "d4:info99999999999999999999999999999999999:xee",
                      "d4:infode4:infodee", "d4:info" + String(repeating: "l", count: 130) + String(repeating: "e", count: 131)] {
            #expect(TorrentMetainfoIdentity.hashes(in: Data(value.utf8)).isEmpty)
        }
    }

    @Test("hex and base32 magnets resolve the same source identity")
    func magnetIdentity() {
        let hex = String(repeating: "00", count: 20)
        #expect(TorrentMetainfoIdentity.hashes(inMagnet: "magnet:?xt=urn:btih:" + hex) == [hex])
        #expect(TorrentMetainfoIdentity.hashes(inMagnet: "magnet:?xt=urn:btih:" + String(repeating: "A", count: 32)) == [hex])
        #expect(TorrentMetainfoIdentity.hashes(inMagnet: "magnet:?xt=urn:btih:invalid").isEmpty)
    }
}
