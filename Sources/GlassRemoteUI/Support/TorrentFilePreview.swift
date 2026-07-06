import Foundation
import GlassRemoteCore

struct TorrentFilePreview: Sendable {
    let name: String
    let size: UInt64
    let files: [TorrentFile]

    init(data: Data, fallbackURL: URL?) {
        if let parsed = BencodeTorrentPreview(data: data) {
            self.name = parsed.name
            self.size = parsed.size
            self.files = parsed.files
            return
        }

        let fallbackName = fallbackURL?.deletingPathExtension().lastPathComponent
        self.name = fallbackName?.isEmpty == false ? fallbackName! : "Torrent File"
        self.size = UInt64(data.count)
        self.files = [TorrentFile(name: self.name, length: self.size, bytesCompleted: 0)]
    }
}

private struct BencodeTorrentPreview {
    let name: String
    let size: UInt64
    let files: [TorrentFile]

    init?(data: Data) {
        var parser = BencodeParser(data: data)
        guard
            let root = parser.parse(),
            case let .dictionary(dictionary) = root,
            case let .dictionary(info)? = dictionary["info"],
            case let .string(nameData)? = info["name"],
            let name = String(data: nameData, encoding: .utf8),
            !name.isEmpty
        else {
            return nil
        }

        self.name = name
        if case let .integer(length)? = info["length"], length > 0 {
            self.size = UInt64(length)
            self.files = [TorrentFile(name: name, length: UInt64(length), bytesCompleted: 0)]
        } else if case let .list(files)? = info["files"] {
            let parsedFiles = files.compactMap { value -> TorrentFile? in
                guard
                    case let .dictionary(file) = value,
                    case let .integer(length)? = file["length"],
                    length > 0
                else {
                    return nil
                }
                return TorrentFile(
                    name: Self.fileName(rootName: name, file: file),
                    length: UInt64(length),
                    bytesCompleted: 0
                )
            }
            self.files = parsedFiles
            self.size = parsedFiles.reduce(0) { $0 + $1.length }
        } else {
            self.size = UInt64(data.count)
            self.files = [TorrentFile(name: name, length: UInt64(data.count), bytesCompleted: 0)]
        }
    }

    private static func fileName(rootName: String, file: [String: BencodeValue]) -> String {
        guard case let .list(pathValues)? = file["path"] else {
            return rootName
        }
        let components = pathValues.compactMap { value -> String? in
            guard case let .string(data) = value else { return nil }
            return String(data: data, encoding: .utf8)
        }
        guard !components.isEmpty else { return rootName }
        return ([rootName] + components).joined(separator: "/")
    }
}

private enum BencodeValue {
    case integer(Int64)
    case string(Data)
    case list([BencodeValue])
    case dictionary([String: BencodeValue])
}

private struct BencodeParser {
    private let data: Data
    private var index = 0

    init(data: Data) {
        self.data = data
    }

    mutating func parse() -> BencodeValue? {
        parseValue()
    }

    private mutating func parseValue() -> BencodeValue? {
        guard index < data.count else { return nil }
        switch data[index] {
        case UInt8(ascii: "i"):
            return parseInteger()
        case UInt8(ascii: "l"):
            return parseList()
        case UInt8(ascii: "d"):
            return parseDictionary()
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            return parseString()
        default:
            return nil
        }
    }

    private mutating func parseInteger() -> BencodeValue? {
        index += 1
        let start = index
        while index < data.count, data[index] != UInt8(ascii: "e") {
            index += 1
        }
        guard index < data.count else { return nil }
        let numberData = data[start..<index]
        index += 1
        guard let text = String(data: numberData, encoding: .ascii), let value = Int64(text) else {
            return nil
        }
        return .integer(value)
    }

    private mutating func parseString() -> BencodeValue? {
        let lengthStart = index
        while index < data.count, data[index] != UInt8(ascii: ":") {
            guard data[index] >= UInt8(ascii: "0"), data[index] <= UInt8(ascii: "9") else { return nil }
            index += 1
        }
        guard index < data.count else { return nil }
        let lengthData = data[lengthStart..<index]
        index += 1
        guard
            let lengthText = String(data: lengthData, encoding: .ascii),
            let length = Int(lengthText),
            index + length <= data.count
        else {
            return nil
        }
        let value = data[index..<(index + length)]
        index += length
        return .string(Data(value))
    }

    private mutating func parseList() -> BencodeValue? {
        index += 1
        var values: [BencodeValue] = []
        while index < data.count, data[index] != UInt8(ascii: "e") {
            guard let value = parseValue() else { return nil }
            values.append(value)
        }
        guard index < data.count else { return nil }
        index += 1
        return .list(values)
    }

    private mutating func parseDictionary() -> BencodeValue? {
        index += 1
        var values: [String: BencodeValue] = [:]
        while index < data.count, data[index] != UInt8(ascii: "e") {
            guard
                case let .string(keyData)? = parseString(),
                let key = String(data: keyData, encoding: .utf8),
                let value = parseValue()
            else {
                return nil
            }
            values[key] = value
        }
        guard index < data.count else { return nil }
        index += 1
        return .dictionary(values)
    }
}
