import Foundation

/// Finder may deliver one batch as several open events while metainfo is loading.
/// One session owns every draft until the user dismisses its sheet.
@MainActor
final class TorrentImportQueue {
    private var pending: [URL] = []
    private var seen = Set<URL>()
    private var drafts: [TorrentFileAddDraft] = []
    private var generation = UUID()
    private var task: Task<Void, Never>?

    func enqueue(_ urls: [URL],
                 load: @escaping @MainActor (URL) async -> TorrentFileAddDraft?,
                 update: @escaping @MainActor ([TorrentFileAddDraft], Bool) -> Void) {
        pending.append(contentsOf: urls.filter { seen.insert($0.standardizedFileURL).inserted })
        guard task == nil, !pending.isEmpty else { return }
        let current = generation
        task = Task {
            while !pending.isEmpty {
                let url = pending.removeFirst()
                let draft = await load(url)
                guard !Task.isCancelled, generation == current else { return }
                if let draft { drafts.append(draft) }
                update(drafts, pending.isEmpty)
            }
            task = nil
        }
    }

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        pending.removeAll()
        seen.removeAll()
        drafts.removeAll()
    }
}
