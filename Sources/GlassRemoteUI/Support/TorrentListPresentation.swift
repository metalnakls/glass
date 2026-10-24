import Foundation
import GlassRemoteCore
import GlassRemoteServices
import Observation
import SwiftUI

struct TorrentListStructureInput: Equatable {
    let revision: Int
    let recordIDs: [String]
    let pendingRenameNames: [String: String]
    var unfinishedIDs: [String] = []
    var sorting = TorrentListSorting.transmission
    var sortInputs: [TorrentListSorting.Input] = []
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
                ? members.contains { $0.isUnfinished }
                : members.allSatisfy { !$0.isUnfinished }
            if matches || members.contains(where: { $0.isAdding }) { included.formUnion(members.map(\.id)) }
        }
        return records.filter { $0.isAdding || included.contains($0.id) }
    }
}

@MainActor
struct TorrentListSection: Identifiable {
    let id: String
    let title: String
    let rows: [TorrentListRowPresentation]
    /// Unfinished Adds sit above the loading rows, as if already added.
    var drafts: [TorrentAddDraft] = []

    /// Pin only when the section displays more than two rows, including expanded seasons.
    var allowsStickyHeader: Bool {
        rows.count > 2
    }

    static func sections(for rows: [TorrentListRowPresentation], lowercase: Bool = false) -> [Self] {
        let unfinishedMembers = Set(rows.flatMap { row -> [String] in
            guard case let .group(members, _, _) = row.kind,
                  members.contains(where: { $0.isUnfinished }) else { return [] }
            return members.map(\.id)
        })
        var unfinished: [TorrentListRowPresentation] = []
        var finished: [TorrentListRowPresentation] = []
        for row in rows {
            let isUnfinished: Bool
            switch row.kind {
            case let .torrent(record, _):
                isUnfinished = record.isUnfinished || unfinishedMembers.contains(record.id)
            case let .group(members, _, _):
                isUnfinished = members.contains { $0.isUnfinished }
            }
            if isUnfinished { unfinished.append(row) } else { finished.append(row) }
        }
        return [Self(id: "unfinished", title: lowercase ? "loading" : "Loading", rows: unfinished),
                Self(id: "finished", title: lowercase ? "completed" : "Completed", rows: finished)].filter { !$0.rows.isEmpty }
    }
}

/// One identity domain lets native List move torrents across section boundaries.
@MainActor enum TorrentListEntry: Identifiable {
    case header(TorrentListSection)
    case draft(TorrentAddDraft)
    case torrent(TorrentListRowPresentation)
    nonisolated var id: String {
        switch self {
        case let .header(section): "section:" + section.id
        case let .draft(draft): draft.listID
        case let .torrent(row): row.id
        }
    }
    var selectionTag: String? { id }
    static func entries(for rows: [TorrentListRowPresentation], lowercase: Bool) -> [Self] {
        TorrentListLayout(rows: rows).entries(lowercase: lowercase)
    }
}

/// The native List and its adornments consume the same structural snapshot.
/// Telemetry updates individual records; only a structural change rebuilds it.
@MainActor
struct TorrentListLayout {
    let rows: [TorrentListRowPresentation]
    let sections: [TorrentListSection]
    private let orderedEntries: [TorrentListEntry]
    let nativeRowIDs: [String?]
    let rowIndices: [String: Int]
    let headerIndices: [String: Int]
    let nextRowIDs: [String: String]
    let iconPositions: [String: Int]
    let movingFolderIDs: Set<String>

    init(rows: [TorrentListRowPresentation], sorting: TorrentListSorting = .transmission, drafts: [TorrentAddDraft] = []) {
        var sections = TorrentListSection.sections(for: rows).map { section in
            TorrentListSection(id: section.id, title: section.title, rows: sorting.sort(section.rows, section: section.id))
        }
        if !drafts.isEmpty {
            if let position = sections.firstIndex(where: { $0.id == "unfinished" }) {
                sections[position].drafts = drafts
            } else {
                sections.insert(TorrentListSection(id: "unfinished", title: "Loading", rows: [], drafts: drafts), at: 0)
            }
        }
        self.sections = sections
        self.rows = sections.flatMap(\.rows)
        orderedEntries = sections.flatMap { section in
            [TorrentListEntry.header(section)]
                + section.drafts.map(TorrentListEntry.draft)
                + section.rows.map(TorrentListEntry.torrent)
        }
        var ids: [String?] = []
        var indices: [String: Int] = [:]
        var headers: [String: Int] = [:]
        var neighbors: [String: String] = [:]
        for section in sections {
            headers[section.id] = ids.count
            ids.append(nil)
            let sectionIDs = section.drafts.map(\.listID) + section.rows.map(\.id)
            for (offset, id) in sectionIDs.enumerated() {
                indices[id] = ids.count
                ids.append(id)
                if offset + 1 < sectionIDs.count { neighbors[id] = sectionIDs[offset + 1] }
            }
        }
        nativeRowIDs = ids
        rowIndices = indices
        headerIndices = headers
        nextRowIDs = neighbors
        iconPositions = Dictionary(uniqueKeysWithValues: self.rows.enumerated().map { ($0.element.id, $0.offset) })
        movingFolderIDs = Set(self.rows.flatMap { $0.groupMemberIDs ?? [] })
    }

    func titledSections(lowercase: Bool) -> [TorrentListSection] {
        guard lowercase else { return sections }
        return sections.map {
            TorrentListSection(id: $0.id, title: $0.title.lowercased(), rows: $0.rows, drafts: $0.drafts)
        }
    }

    func entries(lowercase: Bool) -> [TorrentListEntry] {
        guard lowercase else { return orderedEntries }
        return orderedEntries.map { entry in
            guard case let .header(section) = entry else { return entry }
            return .header(TorrentListSection(id: section.id, title: section.title.lowercased(), rows: section.rows, drafts: section.drafts))
        }
    }

    func showsSeparator(after id: String, selection: String?) -> Bool {
        guard let next = nextRowIDs[id] else { return false }
        return id != selection && next != selection
    }
}

@MainActor
@Observable
final class TorrentListPresentationModel {
    private(set) var layout = TorrentListLayout(rows: [])
    private(set) var drafts: [TorrentAddDraft] = []
    var rows: [TorrentListRowPresentation] { layout.rows }
    var iconPositions: [String: Int] { layout.iconPositions }
    var movingFolderIDs: Set<String> { layout.movingFolderIDs }

    @ObservationIgnored private var sorting = TorrentListSorting.transmission
    @ObservationIgnored private var expandedGroupIDs = TorrentGroupExpansionStore.expandedGroupIDs()
    /// A group collapses once when it becomes fully downloaded; later expands
    /// are the user's choice and survive while the app stays open.
    @ObservationIgnored private var completedGroupIDs: Set<String> = []

    /// Drafts live outside the torrent records but share the native list identity
    /// space, so adding or removing one never changes a real row's position.
    func setDrafts(_ drafts: [TorrentAddDraft], animated: Bool, reduceMotion: Bool) {
        guard self.drafts != drafts else { return }
        self.drafts = drafts
        setRows(rows, animated: animated, reduceMotion: reduceMotion)
    }

    @discardableResult
    func synchronize(
        records: [TorrentRecord],
        pendingRenameNames: [String: String],
        animated: Bool,
        reduceMotion: Bool,
        sorting: TorrentListSorting? = nil
    ) -> [TorrentListRowPresentation] {
        if let sorting { self.sorting = sorting }
        var updatedRows = TorrentListRowPresentation.rows(
            records: records,
            pendingRenameNames: pendingRenameNames,
            expandedGroupIDs: expandedGroupIDs
        )
        let completedNow = Self.completedGroupIDs(in: updatedRows)
        let newlyCompleted = completedNow.subtracting(completedGroupIDs)
        if !newlyCompleted.isEmpty {
            expandedGroupIDs.subtract(newlyCompleted)
            TorrentGroupExpansionStore.save(expandedGroupIDs)
            updatedRows = TorrentListRowPresentation.rows(
                records: records,
                pendingRenameNames: pendingRenameNames,
                expandedGroupIDs: expandedGroupIDs
            )
        }
        completedGroupIDs = completedNow
        setRows(updatedRows, animated: animated, reduceMotion: reduceMotion)
        return updatedRows
    }

    /// Fully downloaded seasons return to their compact row even if they were
    /// left expanded while downloading. No member changes on later refreshes,
    /// so an expansion the user makes afterwards is preserved.
    private static func completedGroupIDs(in rows: [TorrentListRowPresentation]) -> Set<String> {
        Set(rows.compactMap { row in
            guard case let .group(records, _, _) = row.kind,
                  !records.isEmpty,
                  records.allSatisfy({ $0.summary.isCompleted }) else { return nil }
            return row.id
        })
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

    func applyNativeMove(_ updatedRows: [TorrentListRowPresentation]) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { layout = TorrentListLayout(rows: updatedRows, drafts: drafts) }
    }

    private func setRows(
        _ updatedRows: [TorrentListRowPresentation],
        animated: Bool,
        reduceMotion: Bool
    ) {
        if animated, !reduceMotion {
            withAnimation(GlassMotion.structure) {
                layout = TorrentListLayout(rows: updatedRows, sorting: sorting, drafts: drafts)
            }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                layout = TorrentListLayout(rows: updatedRows, sorting: sorting, drafts: drafts)
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
        let live = records.filter { !$0.isAdding }
        guard !live.isEmpty else { return nil }
        return TorrentNameSequenceGroup(id: id, displayName: displayName, torrents: live.map(\.summary))
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
        return min(groupMemberIDs.count, 4)
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
        records allRecords: [TorrentRecord],
        pendingRenameNames: [String: String],
        expandedGroupIDs: Set<String>
    ) -> [TorrentListRowPresentation] {
        let records = allRecords
        let summaries = records.map { record in
            if pendingRenameNames[record.id] == nil, let season = record.season {
                return record.summary.renamedForPresentation(to: season.numberedTitle)
            }
            return (pendingRenameNames[record.id] ?? record.displayName).map { record.summary.renamedForPresentation(to: $0) }
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
        if let season = record.season { return "Season \(season.season)" }
        let name = record.displayName ?? record.summary.name
        if let number = TorrentNameSequenceGrouper.memberNumber(for: record.summary.renamedForPresentation(to: name)) {
            return "Season \(number)"
        }
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
