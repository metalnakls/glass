import Foundation
import GlassRemoteCore

enum TorrentListItem: Identifiable {
    case torrent(TorrentSummary)
    case group(TorrentNameSequenceGroup)

    var id: String {
        switch self {
        case let .torrent(torrent):
            return "torrent:\(torrent.hashString)"
        case let .group(group):
            return group.id
        }
    }
}

struct TorrentNameSequenceGroup: Identifiable {
    let id: String
    let displayName: String
    let torrents: [TorrentSummary]

    var summary: TorrentSummary {
        let size = torrents.reduce(UInt64(0)) { $0 + $1.sizeWhenDone }
        let left = torrents.reduce(UInt64(0)) { $0 + $1.leftUntilDone }
        let downloaded = size >= left ? size - left : 0
        let percentDone = size > 0
            ? min(1, max(0, Double(downloaded) / Double(size)))
            : (torrents.isEmpty ? 0 : torrents.reduce(0) { $0 + $1.percentDone } / Double(torrents.count))
        let activeTorrents = torrents.filter(\.isActive)
        let eta = activeTorrents.map(\.eta).filter { $0 > 0 }.max() ?? -1

        return TorrentSummary(
            id: Int.min,
            hashString: id,
            name: displayName,
            status: activeTorrents.first?.status ?? TransmissionTorrentStatus.stopped.rawValue,
            percentDone: percentDone,
            metadataPercentComplete: 1,
            rateDownload: torrents.reduce(0) { $0 + $1.rateDownload },
            rateUpload: torrents.reduce(0) { $0 + $1.rateUpload },
            sizeWhenDone: size,
            leftUntilDone: left,
            eta: eta,
            uploadRatio: torrents.isEmpty ? 0 : torrents.reduce(0) { $0 + $1.uploadRatio } / Double(torrents.count),
            peersConnected: torrents.reduce(0) { $0 + ($1.peersConnected ?? 0) },
            downloadDir: nil,
            bandwidthPriority: nil,
            queuePosition: nil
        )
    }
}

enum TorrentNameSequenceGrouper {
    private struct ParsedTorrent {
        let key: String
        let displayName: String
        let number: Int
        let torrent: TorrentSummary
        let originalIndex: Int
    }

    static func items(for torrents: [TorrentSummary]) -> [TorrentListItem] {
        var parsedByHash: [String: ParsedTorrent] = [:]
        var grouped: [String: [ParsedTorrent]] = [:]

        for (index, torrent) in torrents.enumerated() {
            guard let parsed = parsedTorrent(torrent, originalIndex: index) else { continue }
            parsedByHash[torrent.hashString] = parsed
            grouped[parsed.key, default: []].append(parsed)
        }

        let qualifyingKeys = Set(grouped.compactMap { key, candidates -> String? in
            let numbers = Set(candidates.map(\.number))
            return candidates.count >= 2 && numbers.count >= 2 ? key : nil
        })

        var emittedGroupKeys = Set<String>()
        var items: [TorrentListItem] = []

        for torrent in torrents {
            guard let parsed = parsedByHash[torrent.hashString], qualifyingKeys.contains(parsed.key) else {
                items.append(.torrent(torrent))
                continue
            }

            guard !emittedGroupKeys.contains(parsed.key) else { continue }
            emittedGroupKeys.insert(parsed.key)

            let members = (grouped[parsed.key] ?? []).sorted {
                if $0.number != $1.number {
                    return $0.number < $1.number
                }
                return $0.originalIndex < $1.originalIndex
            }

            items.append(.group(TorrentNameSequenceGroup(
                id: "auto-group:\(parsed.key)",
                displayName: members.first?.displayName ?? parsed.displayName,
                torrents: members.map(\.torrent)
            )))
        }

        return items
    }

    private static func parsedTorrent(_ torrent: TorrentSummary, originalIndex: Int) -> ParsedTorrent? {
        let trimmedName = torrent.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let suffixRange = trimmedName.range(of: #"(?<!\d)[1-9]\d?$"#, options: .regularExpression),
            suffixRange.upperBound == trimmedName.endIndex,
            let number = Int(trimmedName[suffixRange]),
            number <= 99
        else {
            return nil
        }

        let prefix = trimmedName[..<suffixRange.lowerBound]
        guard let separator = prefix.unicodeScalars.last, suffixSeparators.contains(separator) else {
            return nil
        }

        let displayName = String(prefix)
            .trimmingCharacters(in: suffixSeparators)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard displayName.count >= 2 else { return nil }

        let key = displayName
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }

        return ParsedTorrent(
            key: key,
            displayName: displayName,
            number: number,
            torrent: torrent,
            originalIndex: originalIndex
        )
    }

    private static let suffixSeparators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "._-(["))
}
