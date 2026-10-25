import Foundation

/// A portable, point-in-time view of the video files in one torrent.
///
/// `relativePathPrefix` is supplied by the caller after it has established the
/// show root. This type deliberately does not guess a show identity from names.
public struct ShowEpisodeIndex: Sendable, Hashable, Codable {
    public static let currentSchemaVersion = 1
    public static let freshnessLimit: TimeInterval = 15 * 60
    public static let maximumEpisodeCount = 20_000

    public enum Availability: String, Sendable, Hashable, Codable {
        case complete
        case notSelected
        case selected
        case partial
        case unknown
    }

    public struct Episode: Sendable, Hashable, Codable, Identifiable {
        public struct TransferIdentity: Sendable, Hashable, Codable {
            public let hashString: String
            public let fileIndex: Int

            public init(hashString: String, fileIndex: Int) {
                self.hashString = hashString
                self.fileIndex = fileIndex
            }
        }

        public let id: TransferIdentity
        /// Path relative to the caller-established show root.
        public let relativePath: String
        public let season: Int?
        public let episode: Int?
        public let bytesCompleted: UInt64
        public let totalBytes: UInt64
        public let wanted: Bool?

        public init(
            id: TransferIdentity,
            relativePath: String,
            season: Int?,
            episode: Int?,
            bytesCompleted: UInt64,
            totalBytes: UInt64,
            wanted: Bool?
        ) {
            self.id = id
            self.relativePath = relativePath
            self.season = season
            self.episode = episode
            self.bytesCompleted = bytesCompleted
            self.totalBytes = totalBytes
            self.wanted = wanted
        }

        public var availability: Availability {
            guard totalBytes > 0 else { return .unknown }
            if bytesCompleted >= totalBytes { return .complete }
            guard let wanted else { return .unknown }
            guard wanted else { return .notSelected }
            return bytesCompleted > 0 ? .partial : .selected
        }

        private enum CodingKeys: String, CodingKey {
            case id, relativePath, season, episode, bytesCompleted, totalBytes, wanted
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(TransferIdentity.self, forKey: .id)
            relativePath = try container.decode(String.self, forKey: .relativePath)
            season = try container.decodeIfPresent(Int.self, forKey: .season)
            episode = try container.decodeIfPresent(Int.self, forKey: .episode)
            bytesCompleted = try container.decode(UInt64.self, forKey: .bytesCompleted)
            totalBytes = try container.decode(UInt64.self, forKey: .totalBytes)
            wanted = try container.decodeIfPresent(Bool.self, forKey: .wanted)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(relativePath, forKey: .relativePath)
            try container.encode(season, forKey: .season)
            try container.encode(episode, forKey: .episode)
            try container.encode(bytesCompleted, forKey: .bytesCompleted)
            try container.encode(totalBytes, forKey: .totalBytes)
            try container.encode(wanted, forKey: .wanted)
        }
    }

    public let schemaVersion: Int
    public let hashString: String
    public let capturedAt: Date
    public let episodes: [Episode]

    public init(details: TorrentDetails, relativePathPrefix: String, capturedAt: Date = .now) throws {
        guard !details.hashString.isEmpty else { throw ValidationError.emptyHash }
        guard details.files.count == details.fileStats.count else {
            throw ValidationError.fileStatsCountMismatch(files: details.files.count, stats: details.fileStats.count)
        }
        guard relativePathPrefix.isEmpty || Self.isSafeRelativePath(relativePathPrefix) else {
            throw ValidationError.unsafePrefix(relativePathPrefix)
        }

        var entries: [Episode] = []
        var seenPaths = Set<String>()
        for (index, pair) in zip(details.files, details.fileStats).enumerated() {
            let (file, stats) = pair
            guard file.bytesCompleted <= file.length else {
                throw ValidationError.bytesExceedLength(index: index)
            }
            let statsBytes = stats.bytesCompleted ?? file.bytesCompleted
            guard statsBytes <= file.length else { throw ValidationError.bytesExceedLength(index: index) }
            guard Self.isSafeRelativePath(file.name) else { throw ValidationError.unsafePath(file.name) }
            guard TorrentNameCleaner.isPreviewableVideo(file.name) else { continue }
            guard let relativePath = Self.path(file.name, removing: relativePathPrefix) else {
                throw ValidationError.pathOutsidePrefix(path: file.name, prefix: relativePathPrefix)
            }
            guard seenPaths.insert(relativePath).inserted else { throw ValidationError.duplicatePath(relativePath) }
            let numbering = Self.episodeNumbering(in: relativePath)
            entries.append(Episode(
                id: .init(hashString: details.hashString, fileIndex: index),
                relativePath: relativePath,
                season: numbering?.season,
                episode: numbering?.episode,
                bytesCompleted: min(file.bytesCompleted, statsBytes),
                totalBytes: file.length,
                wanted: stats.wanted
            ))
            guard entries.count <= Self.maximumEpisodeCount else { throw ValidationError.tooManyEpisodes }
        }
        self.schemaVersion = Self.currentSchemaVersion
        self.hashString = details.hashString
        self.capturedAt = capturedAt
        self.episodes = entries
    }

    public func availability(of episode: Episode, at date: Date = .now) -> Availability {
        guard isFresh(at: date), episodes.contains(episode) else { return .unknown }
        return episode.availability
    }

    public func isFresh(at date: Date = .now) -> Bool {
        let age = date.timeIntervalSince(capturedAt)
        return age >= 0 && age <= Self.freshnessLimit
    }

    public enum ValidationError: Error, Equatable {
        case emptyHash
        case unsupportedSchema(Int)
        case fileStatsCountMismatch(files: Int, stats: Int)
        case unsafePrefix(String)
        case unsafePath(String)
        case duplicatePath(String)
        case pathOutsidePrefix(path: String, prefix: String)
        case bytesExceedLength(index: Int)
        case tooManyEpisodes
        case invalidDecodedSnapshot
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, hashString, capturedAt, episodes }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        guard version == Self.currentSchemaVersion else { throw ValidationError.unsupportedSchema(version) }
        let hash = try container.decode(String.self, forKey: .hashString)
        let timestamp = try container.decode(String.self, forKey: .capturedAt)
        let date = Self.parseTimestamp(timestamp)
        guard let date else {
            throw ValidationError.invalidDecodedSnapshot
        }
        let episodes = try container.decode([Episode].self, forKey: .episodes)
        guard !hash.isEmpty, episodes.count <= Self.maximumEpisodeCount,
              episodes.allSatisfy({
                  $0.id.hashString == hash && $0.id.fileIndex >= 0 &&
                  Self.isSafeRelativePath($0.relativePath) &&
                  (($0.season == nil && $0.episode == nil) || ($0.season != nil && $0.episode != nil && $0.season! >= 0 && $0.episode! > 0)) &&
                  $0.bytesCompleted <= $0.totalBytes
              }), Set(episodes.map(\.id)).count == episodes.count,
              Set(episodes.map(\.relativePath)).count == episodes.count else {
            throw ValidationError.invalidDecodedSnapshot
        }
        self.schemaVersion = version
        self.hashString = hash
        self.capturedAt = date
        self.episodes = episodes
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(hashString, forKey: .hashString)
        try container.encode(Self.formatTimestamp(capturedAt), forKey: .capturedAt)
        try container.encode(episodes, forKey: .episodes)
    }

    private static func path(_ original: String, removing prefix: String) -> String? {
        guard isSafeRelativePath(original) else { return nil }
        let result: String
        if prefix.isEmpty { result = original }
        else if original == prefix { return nil }
        else if original.hasPrefix(prefix + "/") { result = String(original.dropFirst(prefix.count + 1)) }
        else { return nil }
        return isSafeRelativePath(result) ? result : nil
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") && !path.contains("\0") &&
            !path.contains("~") && path.utf8.count <= 4096 &&
            !path.split(separator: "/", omittingEmptySubsequences: false)
                .contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func formatTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func episodeNumbering(in path: String) -> (season: Int, episode: Int)? {
        let filename = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let range = NSRange(filename.startIndex..<filename.endIndex, in: filename)
        let expression = try! NSRegularExpression(pattern: #"(?i)(?:s(\d{1,2})[\s._-]*e(\d{1,3})|(\d{1,2})x(\d{1,3}))"#)
        guard let match = expression.firstMatch(in: filename, range: range) else { return nil }
        guard let suffixRange = Range(match.range, in: filename).map({ $0.upperBound..<filename.endIndex }) else { return nil }
        let suffix = String(filename[suffixRange])
        let continuation = try! NSRegularExpression(pattern: #"(?i)^(?:e\d{1,3}|-e?\d{1,3}(?:[-_.]|$))"#)
        let suffixRangeValue = NSRange(suffix.startIndex..<suffix.endIndex, in: suffix)
        guard continuation.firstMatch(in: suffix, range: suffixRangeValue) == nil else { return nil }
        func capture(_ index: Int) -> Int? {
            guard match.range(at: index).location != NSNotFound,
                  let range = Range(match.range(at: index), in: filename) else { return nil }
            return Int(filename[range])
        }
        guard let season = capture(1) ?? capture(3), let episode = capture(2) ?? capture(4),
              season >= 0, episode > 0 else { return nil }
        return (season, episode)
    }
}
