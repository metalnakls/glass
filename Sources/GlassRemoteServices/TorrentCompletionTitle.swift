import Foundation
import GlassRemoteCore

/// Notification context is source-scoped by the caller. Disk paths and payload
/// names remain separate from this presentation-only title.
public struct TorrentCompletionTitle: Sendable {
    private let displayName: String
    private let season: TorrentSeasonDescriptor?

    public init(name: String, storedName: TorrentStoredDisplayName?, downloadDirectory: String?, files: [TorrentFile] = []) {
        let stored = storedName.flatMap { $0.rootName == name ? $0 : nil }
        displayName = stored?.displayName ?? name
        let inferred = TorrentNameCleaner.seasonDescriptor(for: .init(rootName: name, files: files))
        if let season = stored?.season ?? inferred {
            self.season = season
        } else if name.range(of: #"(?i)^season[\s._-]+[1-9]\d?$"#, options: .regularExpression) != nil,
                  let downloadDirectory {
            let series = URL(fileURLWithPath: downloadDirectory).lastPathComponent
            season = TorrentNameCleaner.seasonDescriptor(for: .init(rootName: series + " " + name, files: []))
        } else {
            season = nil
        }
    }

    public func resolved(among siblings: [Self]) -> String {
        guard let season else { return displayName }
        let seriesKey = Self.key(season.title)
        let hasOtherSeason = siblings.contains { sibling in
            if let other = sibling.season {
                return Self.key(other.title) == seriesKey && other.season != season.season
            }
            // Older imports may have only their full numbered display title.
            let name = sibling.displayName
            guard let suffix = name.range(of: #"[\s._-]+([1-9]\d?)$"#, options: .regularExpression),
                  let number = Int(name[suffix].trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "._-")))) else { return false }
            return Self.key(String(name[..<suffix.lowerBound])) == seriesKey && number != season.season
        }
        return hasOtherSeason ? season.numberedTitle : displayName
    }

    private static func key(_ title: String) -> String {
        title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: #"[\s._-]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
