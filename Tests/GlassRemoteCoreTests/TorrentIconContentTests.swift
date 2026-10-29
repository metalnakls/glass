import Foundation
import GlassRemoteCore
import Testing

@Suite("Torrent payload icons")
struct TorrentIconContentTests {
    private func preview(_ info: String) throws -> TorrentMetainfoPreview {
        try #require(TorrentMetainfoPreview(data: Data("d4:infod\(info)ee".utf8)))
    }

    @Test("Single-file icons use the original filename, including extension case")
    func singleFile() throws {
        #expect(try preview("6:lengthi123e4:name9:Movie.MKV").iconContent == .file(name: "Movie.MKV"))
        #expect(try preview("6:lengthi0e4:name6:README").iconContent == .file(name: "README"))
    }

    @Test("One file in a multifile torrent is still a folder")
    func oneFileFolder() throws {
        let result = try preview("5:filesld6:lengthi123e4:pathl9:Movie.mkveee4:name11:Folder.mkvx")
        #expect(result.iconContent == .folder)
        #expect(result.files.count == 1)
        #expect(result.files.first?.name == "Folder.mkvx/Movie.mkv")
    }

    @Test("v2 uses the file tree instead of the advisory torrent name")
    func versionTwo() throws {
        #expect(try preview("9:file treed9:Movie.MKVd0:d6:lengthi123eeee12:meta versioni2e4:name5:Label").iconContent == .file(name: "Movie.MKV"))
        #expect(try preview("9:file treed6:Folderd9:Movie.MKVd0:d6:lengthi123eeeee12:meta versioni2e4:name5:Label").iconContent == .folder)
    }

    @Test("Binary v2 piece-layer keys do not discard valid icon metadata")
    func binaryKeys() throws {
        var data = Data("d4:infod6:lengthi123e4:name9:Movie.MKVe12:piece layersd32:".utf8)
        data.append(Data(repeating: 255, count: 32))
        data.append(Data("0:ee".utf8))
        #expect(try #require(TorrentMetainfoPreview(data: data)).iconContent == .file(name: "Movie.MKV"))
    }

    @Test("Unknown payloads and invalid input do not pretend to be a media file")
    func invalid() throws {
        #expect(try preview("4:name9:Movie.MKV").iconContent == .unknown)
        #expect(TorrentMetainfoPreview(data: Data("d4:infod".utf8)) == nil)
        #expect(TorrentMetainfoPreview(data: Data(repeating: 0, count: 8 * 1_024 * 1_024 + 1)) == nil)
    }
}
