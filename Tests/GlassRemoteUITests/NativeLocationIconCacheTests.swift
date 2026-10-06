import AppKit
import Foundation
import UniformTypeIdentifiers
@testable import GlassRemoteUI
import Testing

@MainActor @Suite("Finder NAS icon persistence")
struct NativeLocationIconCacheTests {
    @Test("last known Finder image survives unavailable or unrecognized devices")
    func cachedIconSurvives() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let data = try #require(NSWorkspace.shared.icon(for: .folder).tiffRepresentation)
        let record: [String: Any] = ["name": "Studio NAS", "aliases": ["ultra.local"], "image": data.base64EncodedString()]
        try JSONSerialization.data(withJSONObject: record).write(to: directory.appendingPathComponent(id.uuidString + ".json"))
        let cache = NativeLocationIconCache(directory: directory, discover: false)
        let previous = try #require(cache.images[id])
        cache.noteResolvedDevice(name: "Ultra", host: "Ultra.local.", model: "unrecognized-model")
        #expect(cache.images[id] === previous)
        cache.noteResolvedDevice(name: "Ultra", host: "Ultra.local.", model: "MacPro7,1@ECOLOR=226,226,224")
        #expect(cache.images[id] !== previous)
    }
}
