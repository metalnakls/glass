import Foundation

public enum TorrentNameCleaner {
    public static func plan(
        rootName: String,
        files: [TorrentFile],
        selectedFileIndices: Set<Int>
    ) -> TorrentAddNamingPlan? {
        let cleanedRoot = cleanRootName(rootName)
        var renames: [TorrentPathRename] = []

        if files.count > 1 {
            let existingPaths = Set(files.map(\.name))
            var proposedPaths = Set<String>()

            for (index, file) in files.enumerated() {
                guard selectedFileIndices.contains(index), isMediaFile(file.name) else { continue }
                let oldName = URL(fileURLWithPath: file.name).lastPathComponent
                let newName = cleanMediaFileName(oldName)
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
        guard cleanedRoot != rootName || !renames.isEmpty else { return nil }
        return TorrentAddNamingPlan(rootName: cleanedRoot, pathRenames: renames)
    }

    public static func cleanMediaFileName(_ fileName: String) -> String {
        let url = URL(fileURLWithPath: fileName)
        let fileExtension = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        let cleanedStem: String

        if let episode = episodeDescription(in: stem) {
            cleanedStem = episode
        } else {
            cleanedStem = releaseTitle(from: stem)
        }

        guard !fileExtension.isEmpty else { return cleanedStem }
        return "\(cleanedStem).\(fileExtension)"
    }

    private static func cleanRootName(_ rootName: String) -> String {
        let url = URL(fileURLWithPath: rootName)
        if isMediaFile(rootName) {
            return cleanMediaFileName(rootName)
        }

        let cleaned = releaseTitle(from: url.lastPathComponent)
        return cleaned.isEmpty ? rootName : cleaned
    }

    private static func episodeDescription(in stem: String) -> String? {
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
        let title = releaseTitle(from: suffix)
        return title.isEmpty ? code : "\(code) — \(title)"
    }

    private static func releaseTitle(from value: String) -> String {
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
            if isReleaseNoise(trimmed) {
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

    private static func isReleaseNoise(_ token: String) -> Bool {
        let normalized = token.lowercased().replacingOccurrences(of: "-", with: "")
        if normalized.range(of: #"^(19|20)\d{2}$"#, options: .regularExpression) != nil { return true }
        if normalized.range(of: #"^\d{3,4}p$"#, options: .regularExpression) != nil { return true }
        if normalized.range(of: #"^s\d{1,2}$"#, options: .regularExpression) != nil { return true }
        return releaseNoiseTokens.contains(normalized)
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

    private static let mediaExtensions: Set<String> = [
        "avi", "m2ts", "m4v", "mkv", "mov", "mp4", "mpeg", "mpg", "ts", "webm"
    ]

    private static let releaseNoiseTokens: Set<String> = [
        "aac", "amzn", "atmos", "av1", "bdrip", "bluray", "brip", "cam", "dd", "dts", "dv",
        "dvdrip", "hdr", "hdr10", "hevc", "hdtv", "imax", "multi", "nf", "proper", "repack",
        "remux", "uhd", "web", "webdl", "webrip", "yify"
    ]
}
