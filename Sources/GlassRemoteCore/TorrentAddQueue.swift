import Foundation
import CryptoKit

public enum TorrentAdditionPhase: String, Codable, Sendable {
    case queued, adding, failed, confirming
}

/// The original submission survives failed replies, interrupted batches, and relaunches.
public struct TorrentAddQueueEntry: Codable, Sendable {
    public var id: UUID
    public var sourceID: UUID
    public var name: String
    public var size: UInt64
    public var fileCount: Int
    public var data: Data?
    public var magnet: String?
    public var downloadDirectory: String?
    public var fileSelection: TorrentAddFileSelection?
    public var namingPlan: TorrentAddNamingPlan?
    public var sourceURL: URL?
    public var trashSourceOnSuccess: Bool
    public var phase: TorrentAdditionPhase = .queued
    public var error: String?
    public var attempts = 0
    public var receipt: TorrentAddResult?
    public var completedRenames: [TorrentPathRename] = []
    public var namingComplete = false
    public var renameDuplicateRoot = false
    public var existedBeforeSubmission = false
    public var startPaused: Bool?

    public init(id: UUID, sourceID: UUID, name: String, size: UInt64, fileCount: Int,
                data: Data? = nil, magnet: String? = nil, downloadDirectory: String?,
                fileSelection: TorrentAddFileSelection? = nil, namingPlan: TorrentAddNamingPlan?,
                sourceURL: URL? = nil, trashSourceOnSuccess: Bool = false) {
        self.id = id; self.sourceID = sourceID; self.name = name; self.size = size
        self.fileCount = fileCount; self.data = data; self.magnet = magnet
        self.downloadDirectory = downloadDirectory; self.fileSelection = fileSelection
        self.namingPlan = namingPlan; self.sourceURL = sourceURL
        self.trashSourceOnSuccess = trashSourceOnSuccess
    }

    public var expectedHashes: Set<String> {
        if let data { return TorrentMetainfoIdentity.hashes(in: data) }
        return magnet.map(TorrentMetainfoIdentity.hashes(inMagnet:)) ?? []
    }
}

/// Hash the exact encoded info bytes; decoding and re-encoding would change identity.
public enum TorrentMetainfoIdentity {
    public static func hashes(in data: Data) -> Set<String> {
        var reader = BencodeReader(bytes: Array(data))
        guard let range = reader.infoRange() else { return [] }
        let info = data.subdata(in: range)
        let v1 = Insecure.SHA1.hash(data: info).map { String(format: "%02x", $0) }.joined()
        let v2 = SHA256.hash(data: info).map { String(format: "%02x", $0) }.joined()
        return [v1, v2, String(v2.prefix(40))]
    }

    public static func hashes(inMagnet magnet: String) -> Set<String> {
        let topics = URLComponents(string: magnet)?.queryItems?.filter { $0.name == "xt" }.compactMap(\.value) ?? []
        var result = Set<String>()
        for topic in topics {
            let lower = topic.lowercased()
            if lower.hasPrefix("urn:btih:") {
                let value = String(topic.dropFirst(9))
                if value.count == 40, value.allSatisfy({ $0.isHexDigit }) {
                    result.insert(value.lowercased())
                } else if value.count == 32, let decoded = base32(value) {
                    result.insert(decoded.map { String(format: "%02x", $0) }.joined())
                }
            } else if lower.hasPrefix("urn:btmh:1220") {
                let value = String(lower.dropFirst(13))
                if value.count == 64, value.allSatisfy({ $0.isHexDigit }) {
                    result.insert(value); result.insert(String(value.prefix(40)))
                }
            }
        }
        return result
    }

    private static func base32(_ value: String) -> [UInt8]? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8)
        var bits: UInt32 = 0, count = 0, output: [UInt8] = []
        for byte in value.uppercased().utf8 {
            guard let index = alphabet.firstIndex(of: byte) else { return nil }
            bits = (bits << 5) | UInt32(index); count += 5
            if count >= 8 { count -= 8; output.append(UInt8((bits >> count) & 255)) }
        }
        return output
    }
}

private struct BencodeReader {
    let bytes: [UInt8]
    var position = 0

    mutating func infoRange() -> Range<Int>? {
        guard take(100) else { return nil }
        var info: Range<Int>?
        while position < bytes.count, bytes[position] != 101 {
            guard let key = string() else { return nil }
            let start = position
            guard skip(depth: 0) else { return nil }
            if key == Array("info".utf8) {
                guard info == nil, bytes[start] == 100 else { return nil }
                info = start..<position
            }
        }
        guard take(101), position == bytes.count else { return nil }
        return info
    }

    mutating func take(_ byte: UInt8) -> Bool {
        guard position < bytes.count, bytes[position] == byte else { return false }
        position += 1; return true
    }

    mutating func string() -> [UInt8]? {
        var length = 0, digits = 0
        while position < bytes.count, (48...57).contains(bytes[position]) {
            let digit = Int(bytes[position] - 48)
            guard length <= (Int.max - digit) / 10 else { return nil }
            length = length * 10 + digit; digits += 1; position += 1
        }
        guard digits > 0, take(58), length <= bytes.count - position else { return nil }
        let start = position; position += length
        return Array(bytes[start..<position])
    }

    mutating func skip(depth: Int) -> Bool {
        guard depth < 128, position < bytes.count else { return false }
        if take(105) {
            _ = take(45)
            let start = position
            while position < bytes.count, (48...57).contains(bytes[position]) { position += 1 }
            return position > start && take(101)
        }
        if bytes[position] == 100 || bytes[position] == 108 {
            let dictionary = bytes[position] == 100; position += 1
            while position < bytes.count, bytes[position] != 101 {
                if dictionary, string() == nil { return false }
                guard skip(depth: depth + 1) else { return false }
            }
            return take(101)
        }
        return string() != nil
    }
}
