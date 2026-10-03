import Foundation
import GlassRemoteCore
import GlassRemoteServices
import Observation
import SwiftUI

struct TorrentListStructureInput: Equatable {
    let revision: Int
    let recordIDs: [String]
    let pendingRenameNames: [String: String]
}

@MainActor
enum TorrentLibraryFilter {
    static func records(_ records: [TorrentRecord], group: TorrentGroup, pendingRenameNames: [String: String] = [:]) -> [TorrentRecord] {
        guard group != .all else { return records }
        // Build complete logical groups before filtering, so a season never loses its siblings.
        let rows = TorrentListRowPresentation.rows(records: records, pendingRenameNames: pendingRenameNames, expandedGroupIDs: [])
        var included = Set<String>()
        for row in rows {
            let members: [TorrentRecord]
            switch row.kind {
            case let .torrent(record, _): members = [record]
            case let .group(records, _, _): members = records
            }
            let matches = group == .downloading
                ? members.contains { $0.summary.isUnfinished }
                : members.allSatisfy { !$0.summary.isUnfinished }
            if matches { included.formUnion(members.map(\.id)) }
        }
        return records.filter { included.contains($0.id) }
    }
}

@MainActor
struct TorrentListSection: Identifiable {
    let id: String
    let title: String
    let rows: [TorrentListRowPresentation]

    static func sections(for rows: [TorrentListRowPresentation]) -> [Self] {
        let unfinishedMembers = Set(rows.flatMap { row -> [String] in
            guard case let .group(members, _, _) = row.kind,
                  members.contains(where: { $0.summary.isUnfinished }) else { return [] }
            return members.map(\.id)
        })
        var unfinished: [TorrentListRowPresentation] = []
        var finished: [TorrentListRowPresentation] = []
        for row in rows {
            let isUnfinished: Bool
            switch row.kind {
            case let .torrent(record, _):
                isUnfinished = record.summary.isUnfinished || unfinishedMembers.contains(record.id)
            case let .group(members, _, _):
                isUnfinished = members.contains { $0.summary.isUnfinished }
            }
            if isUnfinished { unfinished.append(row) } else { finished.append(row) }
        }
        return [Self(id: "unfinished", title: "loading", rows: unfinished),
                Self(id: "finished", title: "completed", rows: finished)].filter { !$0.rows.isEmpty }
    }
}

@MainActor
@Observable
final class TorrentListPresentationModel {
    private(set) var rows: [TorrentListRowPresentation] = []

    @ObservationIgnored private var expandedGroupIDs = TorrentGroupExpansionStore.expandedGroupIDs()

    @discardableResult
    func synchronize(
        records: [TorrentRecord],
        pendingRenameNames: [String: String],
        animated: Bool,
        reduceMotion: Bool
    ) -> [TorrentListRowPresentation] {
        let updatedRows = TorrentListRowPresentation.rows(
            records: records,
            pendingRenameNames: pendingRenameNames,
            expandedGroupIDs: expandedGroupIDs
        )
        setRows(updatedRows, animated: animated, reduceMotion: reduceMotion)
        return updatedRows
    }

    @discardableResult
    func toggleGroup(
        _ groupID: String,
        records: [TorrentRecord],
        pendingRenameNames: [String: String],
        reduceMotion: Bool
    ) -> [TorrentListRowPresentation] {
        if expandedGroupIDs.contains(groupID) {
            expandedGroupIDs.remove(groupID)
        } else {
            expandedGroupIDs.insert(groupID)
        }
        TorrentGroupExpansionStore.save(expandedGroupIDs)

        let updatedRows = TorrentListRowPresentation.rows(
            records: records,
            pendingRenameNames: pendingRenameNames,
            expandedGroupIDs: expandedGroupIDs
        )
        setRows(updatedRows, animated: true, reduceMotion: reduceMotion)
        return updatedRows
    }

    @discardableResult
    func revealTorrent(
        _ torrentID: String,
        records: [TorrentRecord],
        pendingRenameNames: [String: String],
        reduceMotion: Bool
    ) -> [TorrentListRowPresentation] {
        _ = synchronize(
            records: records,
            pendingRenameNames: pendingRenameNames,
            animated: false,
            reduceMotion: reduceMotion
        )
        guard let groupID = rows.first(where: { row in
            row.groupMemberIDs?.contains(torrentID) == true
        })?.id, expandedGroupIDs.insert(groupID).inserted else {
            return rows
        }

        TorrentGroupExpansionStore.save(expandedGroupIDs)
        let updatedRows = TorrentListRowPresentation.rows(
            records: records,
            pendingRenameNames: pendingRenameNames,
            expandedGroupIDs: expandedGroupIDs
        )
        setRows(updatedRows, animated: true, reduceMotion: reduceMotion)
        return updatedRows
    }

    private func setRows(
        _ updatedRows: [TorrentListRowPresentation],
        animated: Bool,
        reduceMotion: Bool
    ) {
        if animated, !reduceMotion {
            withAnimation(.smooth(duration: 0.26, extraBounce: 0)) {
                rows = updatedRows
            }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                rows = updatedRows
            }
        }
    }
}

@MainActor
struct TorrentListRowPresentation: Identifiable {
    enum Kind {
        case torrent(record: TorrentRecord, displayName: String?)
        case group(records: [TorrentRecord], displayName: String, isExpanded: Bool)
    }

    let id: String
    let kind: Kind

    var sourceID: UUID {
        switch kind {
        case let .torrent(record, _): return record.sourceID
        case let .group(records, _, _): return records[0].sourceID
        }
    }

    var selectedGroup: TorrentNameSequenceGroup? {
        guard case let .group(records, displayName, _) = kind else { return nil }
        return TorrentNameSequenceGroup(id: id, displayName: displayName, torrents: records.map(\.summary))
    }

    var isTorrent: Bool {
        if case .torrent = kind { return true }
        return false
    }

    var torrentRecord: TorrentRecord? {
        guard case let .torrent(record, _) = kind else { return nil }
        return record
    }

    var groupIsExpanded: Bool? {
        guard case let .group(_, _, isExpanded) = kind else { return nil }
        return isExpanded
    }

    var groupMemberIDs: [String]? {
        guard case let .group(records, _, _) = kind else { return nil }
        return records.map(\.id)
    }

    var groupCount: Int {
        guard let groupMemberIDs else { return 0 }
        return min(groupMemberIDs.count, 3)
    }

    static func rows(
        records: [TorrentRecord],
        pendingRenameNames: [String: String],
        expandedGroupIDs: Set<String>
    ) -> [TorrentListRowPresentation] {
        let recordsBySource = Dictionary(grouping: records, by: \.sourceID)
        var seenSources = Set<UUID>()
        return records.map(\.sourceID).filter { seenSources.insert($0).inserted }.flatMap { sourceID in
            rowsForSource(
                records: recordsBySource[sourceID] ?? [],
                pendingRenameNames: pendingRenameNames,
                expandedGroupIDs: expandedGroupIDs
            )
        }
    }

    private static func rowsForSource(
        records: [TorrentRecord],
        pendingRenameNames: [String: String],
        expandedGroupIDs: Set<String>
    ) -> [TorrentListRowPresentation] {
        let summaries = records.map { record in
            (pendingRenameNames[record.id] ?? record.displayName).map { record.summary.renamedForPresentation(to: $0) }
                ?? record.summary
        }
        let topology = TorrentNameSequenceGrouper.items(for: summaries)
        let recordsByHash = Dictionary(
            records.map { ($0.summary.hashString, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var rows: [TorrentListRowPresentation] = []
        rows.reserveCapacity(records.count + topology.count)

        for item in topology {
            switch item {
            case let .torrent(torrent):
                guard let record = recordsByHash[torrent.hashString] else { continue }
                rows.append(TorrentListRowPresentation(
                    id: record.id,
                    kind: .torrent(record: record, displayName: pendingRenameNames[record.id] ?? record.displayName ?? seasonDisplayName(record.summary))
                ))
            case let .group(group):
                let memberRecords = group.torrents.compactMap { recordsByHash[$0.hashString] }
                guard !memberRecords.isEmpty else { continue }
                let groupID = "\(memberRecords[0].sourceID.uuidString):\(group.id)"
                let isExpanded = expandedGroupIDs.contains(groupID)
                rows.append(TorrentListRowPresentation(
                    id: groupID,
                    kind: .group(records: memberRecords, displayName: group.displayName, isExpanded: isExpanded)
                ))
                if isExpanded {
                    rows.append(contentsOf: memberRecords.map { record in
                        let displayName = pendingRenameNames[record.id] ?? groupMemberDisplayName(record, groupName: group.displayName)
                        return TorrentListRowPresentation(
                            id: record.id,
                            kind: .torrent(record: record, displayName: displayName)
                        )
                    })
                }
            }
        }
        return rows
    }

    static func groupMemberDisplayName(_ record: TorrentRecord, groupName: String) -> String {
        let name = record.displayName ?? record.summary.name
        let suffix = name.hasPrefix(groupName) ? String(name.dropFirst(groupName.count)) : name
        let cleaned = suffix.replacingOccurrences(of: #"(?i)^\s*(?:season|s)[\s._-]*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let season = Int(cleaned), season > 0 { return "Season \(season)" }
        return name
    }

    private static func seasonDisplayName(_ torrent: TorrentSummary) -> String? {
        guard let directory = torrent.downloadDir,
              torrent.name.range(of: #"(?i)^season[\s._-]+[1-9]\d?$"#, options: .regularExpression) != nil else {
            return nil
        }
        let title = URL(fileURLWithPath: directory).lastPathComponent
        guard title.count >= 2 else { return nil }
        let season = torrent.name.replacingOccurrences(of: #"(?i)^season[\s._-]+"#, with: "", options: .regularExpression)
        return "\(title) \(season)"
    }
}

private enum TorrentGroupExpansionStore {
    private static let defaultsKey = "TorrentList.expandedLibraryGroups"

    static func expandedGroupIDs() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: defaultsKey) ?? [])
    }

    static func save(_ expandedGroupIDs: Set<String>) {
        UserDefaults.standard.set(expandedGroupIDs.sorted(), forKey: defaultsKey)
    }
}
