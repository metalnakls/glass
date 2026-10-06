import Foundation
import GlassRemoteCore
import GlassRemoteServices

/// Section sorting moves a group together with its expanded children.
struct TorrentListSorting: Equatable {
    enum Rule: String, CaseIterable, Identifiable {
        case priority, lastDownloaded, oldestAdded, newestAdded, name, transmission
        var id: Self { self }
        var title: String {
            switch self {
            case .priority: "Priority"
            case .lastDownloaded: "Last downloaded"
            case .oldestAdded: "Oldest added first"
            case .newestAdded: "Newest added first"
            case .name: "Name"
            case .transmission: "Transmission order"
            }
        }
    }
    let loading: Rule
    let completed: Rule
    static let transmission = Self(loading: .transmission, completed: .transmission)

    struct Input: Equatable {
        let id: String
        let priority: Int
        let added: Int
        let downloaded: Int
        let name: String
    }

    @MainActor func input(for record: TorrentRecord) -> Input {
        let torrent = record.summary
        let rules: Set<Rule> = [loading, completed]
        return Input(id: record.id,
            priority: rules.contains(.priority) ? torrent.bandwidthPriority ?? 0 : 0,
            added: !rules.isDisjoint(with: [.priority, .oldestAdded, .newestAdded, .lastDownloaded]) ? torrent.addedDate ?? 0 : 0,
            downloaded: rules.contains(.lastDownloaded) ? torrent.doneDate ?? 0 : 0,
            name: rules.contains(.name) ? record.displayName ?? torrent.name : "")
    }

    @MainActor func sort(_ rows: [TorrentListRowPresentation], section: String) -> [TorrentListRowPresentation] {
        let rule = section == "unfinished" ? loading : completed
        guard rule != .transmission else { return rows }
        let childIDs = Set(rows.flatMap { $0.groupMemberIDs ?? [] })
        let children = Dictionary(uniqueKeysWithValues: rows.filter { childIDs.contains($0.id) }.map { ($0.id, $0) })
        let parents = rows.filter { !childIDs.contains($0.id) }
        let ordered = parents.enumerated().sorted { lhs, rhs in
            let a = key(lhs.element), b = key(rhs.element)
            switch rule {
            case .priority:
                if a.priority != b.priority { return a.priority > b.priority }
                if a.oldest != b.oldest { return a.oldest < b.oldest }
            case .lastDownloaded:
                if a.downloaded != b.downloaded { return a.downloaded > b.downloaded }
            case .oldestAdded:
                if a.oldest != b.oldest { return a.oldest < b.oldest }
            case .newestAdded:
                if a.newest != b.newest { return a.newest > b.newest }
            case .name:
                let order = a.name.localizedStandardCompare(b.name)
                if order != .orderedSame { return order == .orderedAscending }
            case .transmission: break
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
        return ordered.flatMap { row in [row] + (row.groupMemberIDs ?? []).compactMap { children[$0] } }
    }

    @MainActor private func key(_ row: TorrentListRowPresentation) -> (priority: Int, oldest: Int, newest: Int, downloaded: Int, name: String) {
        let torrents: [TorrentSummary]
        let name: String
        switch row.kind {
        case let .torrent(record, displayName):
            torrents = [record.summary]; name = displayName ?? record.summary.name
        case let .group(records, displayName, _):
            torrents = records.map(\.summary); name = displayName
        }
        let unfinished = torrents.filter { $0.isUnfinished && !$0.hasStorageError }
        let prioritized = unfinished.isEmpty ? torrents : unfinished
        let added = torrents.compactMap(\.addedDate).filter { $0 > 0 }
        let downloaded = torrents.compactMap(\.doneDate).filter { $0 > 0 }
        return (prioritized.map { $0.bandwidthPriority ?? 0 }.max() ?? 0,
                added.min() ?? .max, added.max() ?? 0,
                downloaded.max() ?? added.max() ?? 0, name)
    }
}
