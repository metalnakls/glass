import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// Internal ordering has its own payload, so rows never claim Finder files or magnet text.
struct TorrentReorderItem: Codable, Transferable, Sendable, Equatable {
    let id: String
    static let contentType = UTType(exportedAs: "com.glass.torrent-reorder", conformingTo: .data)

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: contentType)
    }
}
