import GlassRemoteCore
import GlassRemoteServices
import SwiftUI

/// One action identity domain for menu commands, keyboard, swipe and context menus.
/// Groups only collect members; they never change a member's available actions.
@MainActor enum TorrentItemActions {
    enum Removal {
        case draft(TorrentAddDraft)
        case addition(UUID)
        case transfer(TorrentSummary, UUID)
    }

    static func removals(for records: [TorrentRecord]) -> [Removal] {
        var seen = Set<String>()
        return records.filter { seen.insert($0.id).inserted }.compactMap { record in
            if let id = record.additionID { return .addition(id) }
            guard !record.isAdding else { return nil }
            return .transfer(record.summary, record.sourceID)
        }
    }

    static func removals(selection: String?, records: [TorrentRecord],
                         rows: [TorrentListRowPresentation], drafts: [TorrentAddDraft]) -> [Removal] {
        guard let selection else { return [] }
        if let draft = drafts.first(where: { $0.listID == selection }) { return [.draft(draft)] }
        if let record = records.first(where: { $0.id == selection }) { return removals(for: [record]) }
        guard let row = rows.first(where: { $0.id == selection }),
              case let .group(members, _, _) = row.kind else { return [] }
        return removals(for: members)
    }
}

struct TorrentRemovalActions: View {
    var kind: TorrentSwipeRowKind = .torrent
    let remove: (Bool) -> Void
    var body: some View {
        Button(role: .destructive) { remove(false) } label: {
            Label(glassText(kind.removalLabel(deleteData: false)), systemImage: TorrentRemovalStyle.symbol(deleteData: false))
        }
        if kind == .torrent {
            Button(role: .destructive) { remove(true) } label: {
                Label(glassText(kind.removalLabel(deleteData: true)), systemImage: TorrentRemovalStyle.symbol(deleteData: true))
            }
        }
    }
}
