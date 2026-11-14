import Foundation

public enum TorrentRequeueSource: Sendable {
    case metainfo(Data)
    case magnet(String)
}

/// Durable deletion checkpoint. An uncertain delete is never sent a second time.
public struct TorrentDataRequeue: Codable, Sendable {
    public enum RemovalStage: String, Codable, Sendable { case prepared, removing, removed }
    public let hashString: String
    public let originalID: Int
    public let files: [TorrentFile]
    public let bandwidthPriority: Int?
    public let queuePosition: Int?
    public var removalStage: RemovalStage = .prepared

    public init(details: TorrentDetails) {
        hashString = details.hashString
        originalID = details.id
        files = details.files
        bandwidthPriority = details.bandwidthPriority
        queuePosition = details.queuePosition
    }

    public static func selection(from details: TorrentDetails) throws -> TorrentAddFileSelection {
        guard !details.files.isEmpty, details.fileStats.count == details.files.count else {
            throw RequeueError("The torrent’s file choices could not be saved. No data was deleted.")
        }
        var selection = TorrentAddFileSelection()
        for i in details.files.indices {
            guard let wanted = details.fileStats[i].wanted, let priority = details.fileStats[i].priority else {
                throw RequeueError("The torrent’s file choices could not be saved. No data was deleted.")
            }
            if wanted { selection.filesWanted.append(i) } else { selection.filesUnwanted.append(i) }
            switch priority {
            case -1: selection.priorityLow.append(i)
            case 0: selection.priorityNormal.append(i)
            case 1: selection.priorityHigh.append(i)
            default: throw RequeueError("The torrent has an unsupported file priority. No data was deleted.")
            }
        }
        return selection
    }

    /// Rename every changed directory/leaf via a temporary metadata name, so
    /// swapped names cannot merge file identities. No payload is created here.
    public static func renames(original: [TorrentFile], desired: [TorrentFile]) throws -> [TorrentPathRename] {
        guard original.count == desired.count, !original.isEmpty,
              zip(original, desired).allSatisfy({ $0.length == $1.length }) else {
            throw RequeueError("The saved torrent metadata doesn’t match its files. No data was deleted.")
        }
        func components(_ path: String) throws -> [String] {
            let parts = path.components(separatedBy: "/")
            guard !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.contains("\0") }) else {
                throw RequeueError("The torrent has an unsafe file path. No data was deleted.")
            }
            return parts
        }
        var current = try original.map { try components($0.name) }
        let target = try desired.map { try components($0.name) }
        guard zip(current, target).allSatisfy({ $0.count == $1.count }),
              Set(desired.map(\.name)).count == desired.count else {
            throw RequeueError("The torrent’s renamed paths cannot be restored safely. No data was deleted.")
        }
        var result: [TorrentPathRename] = []
        func replacing(_ prefix: [String], with component: String) {
            result.append(.init(path: prefix.joined(separator: "/"), name: component))
            for i in current.indices where current[i].starts(with: prefix) { current[i][prefix.count - 1] = component }
        }
        let token = UUID().uuidString
        for depth in 0..<(current.map(\.count).max() ?? 0) {
            var groups: [[String]: String] = [:]
            for i in current.indices where current[i].count > depth {
                let prefix = Array(current[i].prefix(depth + 1))
                if let previous = groups[prefix], previous != target[i][depth] {
                    throw RequeueError("The torrent’s directory layout cannot be restored safely. No data was deleted.")
                }
                groups[prefix] = target[i][depth]
            }
            var staged: [([String], String)] = []
            for (prefix, name) in groups.sorted(by: { $0.key.lexicographicallyPrecedes($1.key) }) where prefix.last != name {
                let temporary = ".glass-requeue-\(token)-\(depth)-\(staged.count)"
                replacing(prefix, with: temporary)
                staged.append((Array(prefix.dropLast()) + [temporary], name))
            }
            for (prefix, name) in staged { replacing(prefix, with: name) }
        }
        return result
    }
}

public struct RequeueError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
