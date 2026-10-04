import CoreTransferable
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import GlassRemoteUI

@Suite("Internal drag isolation")
struct TorrentReorderItemTests {
    @Test("reordering cannot intercept torrent URLs or magnet text")
    func isolatesReordering() throws {
        let type = TorrentReorderItem.contentType
        #expect(type.identifier == "com.glass.torrent-reorder")
        // The SwiftPM test host does not register the app's exported UTIs.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Apps/Glass/Info.plist"))
        let plist = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let declarations = try #require(plist["UTExportedTypeDeclarations"] as? [[String: Any]])
        let declaration = try #require(declarations.first { $0["UTTypeIdentifier"] as? String == type.identifier })
        #expect(declaration["UTTypeConformsTo"] as? [String] == ["public.data"])
        #expect(!type.conforms(to: .text))
        #expect(!type.conforms(to: .url))
        #expect(!type.conforms(to: .fileURL))
        let item = TorrentReorderItem(id: "source:torrent-hash")
        #expect(try JSONDecoder().decode(TorrentReorderItem.self, from: JSONEncoder().encode(item)) == item)
    }
}
