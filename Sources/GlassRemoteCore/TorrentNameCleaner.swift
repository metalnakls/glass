import Foundation

public struct TorrentBatchNamingInput: Sendable, Hashable {
    public let rootName: String
    public let files: [TorrentFile]

    public init(rootName: String, files: [TorrentFile]) {
        self.rootName = rootName
        self.files = files
    }
}

public struct TorrentSeasonDescriptor: Sendable, Hashable, Codable {
    public let title: String
    public let season: Int

    public init(title: String, season: Int) {
        self.title = title
        self.season = season
    }
}

public struct TorrentBatchGroup: Sendable, Hashable, Identifiable {
    public let displayName: String
    public let itemIndices: [Int]
    public let seasons: [Int]

    public init(displayName: String, itemIndices: [Int], seasons: [Int] = []) {
        self.displayName = displayName
        self.itemIndices = itemIndices
        self.seasons = seasons
    }

    public var id: String { itemIndices.map(String.init).joined(separator: ":") }
    public var isSeasonGroup: Bool { itemIndices.count > 1 && itemIndices.count == seasons.count }
}

public enum TorrentNameCleaner {
    public static func seasonDescriptor(for input: TorrentBatchNamingInput) -> TorrentSeasonDescriptor? {
        if let descriptor = seasonDescriptor(in: input.rootName) {
            return descriptor
        }

        let rootTitle = cleanRootName(input.rootName)
        let descriptors = input.files.filter { isMediaFile($0.name) }.compactMap { file in
            if let descriptor = seasonDescriptor(in: file.name) { return descriptor }
            let name = URL(fileURLWithPath: file.name).lastPathComponent
            let range = NSRange(name.startIndex..<name.endIndex, in: name)
            guard let match = episodeRegex.firstMatch(in: name, range: range),
                  let seasonText = capture(1, in: match, text: name) ?? capture(3, in: match, text: name),
                  let season = Int(seasonText), (1...99).contains(season), rootTitle.count >= 2 else {
                return nil
            }
            // A draft already called “Fargo 5” must not become “Fargo 5 5”.
            let title = rootTitle.replacingOccurrences(
                of: #"[\s._-]+0?"# + String(season) + "$", with: "", options: .regularExpression
            )
            return TorrentSeasonDescriptor(title: title, season: season)
        }
        guard let first = descriptors.first else { return nil }
        let key = normalizedSeriesKey(first.title)
        guard descriptors.allSatisfy({ $0.season == first.season && normalizedSeriesKey($0.title) == key }) else {
            return nil
        }
        return first
    }

    public static func batchGroups(for inputs: [TorrentBatchNamingInput]) -> [TorrentBatchGroup] {
        let descriptors = inputs.map(seasonDescriptor(for:))
        var candidatesByKey: [String: [(index: Int, descriptor: TorrentSeasonDescriptor)]] = [:]
        for (index, descriptor) in descriptors.enumerated() {
            guard let descriptor else { continue }
            candidatesByKey[normalizedSeriesKey(descriptor.title), default: []].append((index, descriptor))
        }

        let qualifying = candidatesByKey.filter { _, values in
            values.count >= 2 && Set(values.map(\.descriptor.season)).count == values.count
        }
        var groupByIndex: [Int: TorrentBatchGroup] = [:]
        for values in qualifying.values {
            let sorted = values.sorted {
                $0.descriptor.season == $1.descriptor.season
                    ? $0.index < $1.index
                    : $0.descriptor.season < $1.descriptor.season
            }
            guard let first = sorted.first else { continue }
            let group = TorrentBatchGroup(
                displayName: first.descriptor.title,
                itemIndices: sorted.map(\.index),
                seasons: sorted.map(\.descriptor.season)
            )
            for value in sorted {
                groupByIndex[value.index] = group
            }
        }

        var emittedGroupIDs = Set<String>()
        var result: [TorrentBatchGroup] = []
        for index in inputs.indices {
            if let group = groupByIndex[index] {
                guard emittedGroupIDs.insert(group.id).inserted else { continue }
                result.append(group)
            } else {
                result.append(TorrentBatchGroup(
                    displayName: seasonDescriptor(for: inputs[index])?.title ?? smartRootName(inputs[index].rootName, files: inputs[index].files),
                    itemIndices: [index]
                ))
            }
        }
        return result
    }

    public static func plan(
        rootName: String,
        files: [TorrentFile],
        selectedFileIndices: Set<Int>,
        removingTokens: [String] = []
    ) -> TorrentAddNamingPlan? {
        let season = isMediaFile(rootName) ? nil : seasonDescriptor(for: TorrentBatchNamingInput(rootName: rootName, files: files))
        let cleanedRoot = season == nil ? smartRootName(rootName, files: files, removingTokens: removingTokens) : rootName
        var renames: [TorrentPathRename] = []

        if files.count > 1 {
            let existingPaths = Set(files.map(\.name))
            var proposedPaths = Set<String>()

            for (index, file) in files.enumerated() {
                guard selectedFileIndices.contains(index), isMediaFile(file.name) else { continue }
                let oldName = URL(fileURLWithPath: file.name).lastPathComponent
                let newName = cleanMediaFileName(oldName, removingTokens: removingTokens)
                guard newName != oldName else { continue }

                let parent = (file.name as NSString).deletingLastPathComponent
                let proposedPath = parent.isEmpty ? newName : (parent as NSString).appendingPathComponent(newName)
                guard
                    !proposedPaths.contains(proposedPath),
                    !existingPaths.contains(proposedPath)
                else {
                    continue
                }

                proposedPaths.insert(proposedPath)
                renames.append(TorrentPathRename(path: file.name, name: newName))
            }
        }

        renames.sort { pathDepth($0.path) > pathDepth($1.path) }
        guard season != nil || cleanedRoot != rootName || !renames.isEmpty else { return nil }
        return TorrentAddNamingPlan(rootName: cleanedRoot, pathRenames: renames, displayName: season?.title, season: season)
    }

    public static func cleanMediaFileName(
        _ fileName: String,
        removingTokens: [String] = []
    ) -> String {
        let url = URL(fileURLWithPath: fileName)
        let fileExtension = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        let cleanedStem: String

        if let episode = episodeDescription(in: stem, removingTokens: removingTokens) {
            cleanedStem = episode
        } else {
            cleanedStem = releaseTitle(from: stem, removingTokens: removingTokens)
        }

        guard !fileExtension.isEmpty else { return cleanedStem }
        return "\(cleanedStem).\(fileExtension)"
    }

    private static func cleanRootName(_ rootName: String, removingTokens: [String] = []) -> String {
        let url = URL(fileURLWithPath: rootName)
        if isMediaFile(rootName) {
            return cleanMediaFileName(rootName, removingTokens: removingTokens)
        }

        let cleaned = releaseTitle(from: url.lastPathComponent, removingTokens: removingTokens)
        return cleaned.isEmpty ? rootName : cleaned
    }

    private static func smartRootName(
        _ rootName: String,
        files: [TorrentFile],
        removingTokens: [String] = []
    ) -> String {
        guard !isMediaFile(rootName),
              let descriptor = seasonDescriptor(for: TorrentBatchNamingInput(rootName: rootName, files: files)) else {
            return cleanRootName(rootName, removingTokens: removingTokens)
        }
        let title = cleanRootName(descriptor.title, removingTokens: removingTokens)
        return "\(title) \(descriptor.season)"
    }

    private static func seasonDescriptor(in value: String) -> TorrentSeasonDescriptor? {
        let name = URL(fileURLWithPath: value).lastPathComponent
        let range = NSRange(name.startIndex..<name.endIndex, in: name)
        guard let match = seasonIdentityRegex.firstMatch(in: name, range: range) else { return nil }
        guard
            let titleText = capture(1, in: match, text: name),
            let seasonText = capture(2, in: match, text: name),
            let season = Int(seasonText),
            (1...99).contains(season)
        else {
            return nil
        }
        // Bilingual releases conventionally place the original Latin title after the translation.
        let latinTitle = titleText.range(of: #"[A-Za-z][A-Za-z0-9 ._’'&!–—-]*$"#, options: .regularExpression)
            .map { String(titleText[$0]) } ?? titleText
        let title = releaseTitle(from: latinTitle)
        guard title.count >= 2 else { return nil }
        return TorrentSeasonDescriptor(title: title, season: season)
    }

    private static func normalizedSeriesKey(_ title: String) -> String {
        title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "", options: .regularExpression)
    }

    private static func episodeDescription(in stem: String, removingTokens: [String] = []) -> String? {
        let range = NSRange(stem.startIndex..<stem.endIndex, in: stem)
        guard let match = episodeRegex.firstMatch(in: stem, range: range) else { return nil }

        let seasonText = capture(1, in: match, text: stem) ?? capture(3, in: match, text: stem)
        let episodeText = capture(2, in: match, text: stem) ?? capture(4, in: match, text: stem)
        guard let seasonText, let episodeText, let season = Int(seasonText), let episode = Int(episodeText) else {
            return nil
        }

        let code = String(format: "S%02dE%02d", season, episode)
        guard let matchRange = Range(match.range, in: stem) else { return code }
        let suffix = String(stem[matchRange.upperBound...])
        let title = releaseTitle(from: suffix, removingTokens: removingTokens)
        return title.isEmpty ? code : "\(code) — \(title)"
    }

    private static func releaseTitle(from value: String, removingTokens: [String] = []) -> String {
        let withoutBrackets = value.replacingOccurrences(
            of: #"[\[\(\{].*?[\]\)\}]"#,
            with: " ",
            options: .regularExpression
        )
        let tokens = withoutBrackets
            .replacingOccurrences(of: #"[._]+"#, with: " ", options: .regularExpression)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)

        var kept: [String] = []
        for token in tokens {
            let trimmed = token.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            guard !trimmed.isEmpty else { continue }
            if isReleaseNoise(trimmed, removingTokens: removingTokens) {
                break
            }
            kept.append(trimmed)
        }

        let title = kept.joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "-–—")))
        guard !title.isEmpty else { return "" }
        if title == title.lowercased() || title == title.uppercased() {
            return title.localizedCapitalized
        }
        return title
    }

    private static func isReleaseNoise(_ token: String, removingTokens: [String]) -> Bool {
        let normalized = token.lowercased().replacingOccurrences(of: "-", with: "")
        let customTokens = Set(removingTokens.map {
            $0.lowercased().replacingOccurrences(of: "-", with: "")
        })
        if normalized.range(of: #"^(19|20)\d{2}$"#, options: .regularExpression) != nil { return true }
        if normalized.range(of: #"^\d{3,4}p$"#, options: .regularExpression) != nil { return true }
        if normalized.range(of: #"^s\d{1,2}$"#, options: .regularExpression) != nil { return true }
        return customTokens.contains(normalized)
            || releaseNoiseTokens.contains(normalized)
            || normalized.range(of: #"^(x|h)26[45]$"#, options: .regularExpression) != nil
            || normalized.range(of: #"^ddp?\d"#, options: .regularExpression) != nil
    }

    private static func isMediaFile(_ path: String) -> Bool {
        mediaExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    private static func pathDepth(_ path: String) -> Int {
        path.reduce(into: 0) { count, character in
            if character == "/" { count += 1 }
        }
    }

    private static func capture(_ index: Int, in match: NSTextCheckingResult, text: String) -> String? {
        guard match.range(at: index).location != NSNotFound, let range = Range(match.range(at: index), in: text) else {
            return nil
        }
        return String(text[range])
    }

    private static let episodeRegex = try! NSRegularExpression(
        pattern: #"(?i)(?:s(\d{1,2})[\s._-]*e(\d{1,3})|(\d{1,2})x(\d{1,3}))"#
    )

    private static let seasonIdentityRegex = try! NSRegularExpression(
        pattern: #"(?i)^(.+?)[\s._\-\[(]+(?:s(?:eason)?|season|series|сезон)[\s._-]*0?(\d{1,2})(?:\D|$)"#
    )

    private static let mediaExtensions: Set<String> = [
        "avi", "m2ts", "m4v", "mkv", "mov", "mp4", "mpeg", "mpg", "ts", "webm"
    ]

    private static let releaseNoiseTokens: Set<String> = [
        "aac", "amzn", "atmos", "av1", "bdrip", "bluray", "brip", "cam", "dd", "dsnp", "dts", "dv",
        "dvdrip", "hdr", "hdr10", "hevc", "hdtv", "imax", "multi", "nf", "proper", "repack",
        "remux", "uhd", "web", "webdl", "webrip", "yify"
    ]
}
