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
            withAnimation(.easeInOut(duration: 0.22)) {
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
            pendingRenameNames[record.id].map { record.summary.renamedForPresentation(to: $0) }
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
                    kind: .torrent(record: record, displayName: pendingRenameNames[record.id])
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
                        let displayName: String?
                        if record.summary.name.range(
                            of: #"(?i)^season[\s._-]+[1-9]\d?$"#,
                            options: .regularExpression
                        ) != nil {
                            let season = record.summary.name.replacingOccurrences(
                                of: #"(?i)^season[\s._-]+"#,
                                with: "",
                                options: .regularExpression
                            )
                            displayName = "\(group.displayName) \(season)"
                        } else {
                            displayName = pendingRenameNames[record.id]
                        }
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
