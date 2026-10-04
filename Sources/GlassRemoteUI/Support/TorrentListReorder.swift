import Foundation
import GlassRemoteServices
import SwiftUI

/// Translate native view moves to source-scoped queue moves. A group is one
/// queue block; changing its position never changes membership or download state.
@MainActor
struct TorrentListReorderPlan {
    let sourceID: UUID
    let hashes: [String]
    let beforeHashes: [String]
    let orderedRows: [TorrentListRowPresentation]

    enum Destination { case before(String), after(String), end }

    init?(sources: [String], destination: Destination, rows: [TorrentListRowPresentation]) {
        guard !sources.isEmpty else { return nil }
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        let sourceRows = sources.compactMap { byID[$0] }
        guard sourceRows.count == sources.count, let first = sourceRows.first,
              sourceRows.allSatisfy({ $0.sourceID == first.sourceID }) else { return nil }
        let parents = Dictionary(rows.flatMap { row in
            (row.groupMemberIDs ?? []).map { ($0, row.id) }
        }, uniquingKeysWith: { first, _ in first })
        let sectionIDs = Dictionary(TorrentListSection.sections(for: rows).flatMap { section in
            section.rows.map { ($0.id, section.id) }
        }, uniquingKeysWith: { first, _ in first })
        let parent = parents[first.id]
        guard sourceRows.allSatisfy({ parents[$0.id] == parent && sectionIDs[$0.id] == sectionIDs[first.id] }) else { return nil }
        func records(_ row: TorrentListRowPresentation) -> [TorrentRecord] {
            switch row.kind {
            case let .torrent(record, _): [record]
            case let .group(records, _, _): records
            }
        }
        let sourceRecords = sourceRows.flatMap(records)
        guard !sourceRecords.contains(where: { $0.isAdding }) else { return nil }
        var movingIDs = Set(sources)
        for row in sourceRows where row.groupIsExpanded == true { movingIDs.formUnion(row.groupMemberIDs ?? []) }
        let moving = rows.filter { movingIDs.contains($0.id) }
        var remaining = rows.filter { !movingIDs.contains($0.id) }
        var insertion = remaining.count
        switch destination {
        case .end: break
        case let .before(id), let .after(id):
            // Dropping before a section title means the end of the source section.
            if id.hasPrefix("section:") {
                let destinationSection = String(id.dropFirst("section:".count))
                if destinationSection == sectionIDs[first.id] {
                    insertion = remaining.firstIndex(where: {
                        $0.sourceID == first.sourceID && sectionIDs[$0.id] == destinationSection && parents[$0.id] == parent
                    }) ?? remaining.count
                } else if destinationSection != "finished" || sectionIDs[first.id] != "unfinished" {
                    return nil
                }
            } else {
                let normalizedID = parent == nil ? (parents[id] ?? id) : id
                guard let target = byID[normalizedID], !movingIDs.contains(normalizedID),
                      target.sourceID == first.sourceID,
                      sectionIDs[target.id] == sectionIDs[first.id], parents[target.id] == parent,
                      !records(target).contains(where: { $0.isAdding }),
                      let index = remaining.firstIndex(where: { $0.id == target.id }) else { return nil }
                insertion = index
                if case .after = destination {
                    let children = target.groupIsExpanded == true ? Set(target.groupMemberIDs ?? []) : []
                    insertion += 1
                    while insertion < remaining.count && children.contains(remaining[insertion].id) { insertion += 1 }
                }
            }
        }
        // An end move remains inside its section and parent in the presentation.
        if insertion == remaining.count,
           let last = remaining.lastIndex(where: {
               $0.sourceID == first.sourceID && sectionIDs[$0.id] == sectionIDs[first.id] && parents[$0.id] == parent
           }) {
            insertion = last + 1
            let children = remaining[last].groupIsExpanded == true ? Set(remaining[last].groupMemberIDs ?? []) : []
            while insertion < remaining.count && children.contains(remaining[insertion].id) { insertion += 1 }
        }
        let next = remaining.dropFirst(insertion).first { $0.sourceID == first.sourceID }
        sourceID = first.sourceID
        var seen = Set<String>()
        hashes = sourceRecords.map(\.hashString).filter { seen.insert($0).inserted }
        beforeHashes = next.map { records($0).map(\.hashString) } ?? []
        remaining.insert(contentsOf: moving, at: insertion)
        guard remaining.map(\.id) != rows.map(\.id) else { return nil }
        orderedRows = remaining
    }
}
