import AppKit
import Foundation
import GlassRemoteCore
import GlassRemoteServices
import Observation
import SwiftUI

/// One unfinished Add modal: an intake still resolving, or parsed torrents with
/// the user's names, file choices, destination and folder. A quit, force quit or
/// a window close leaves the record on disk; Cancel deletes it.
struct TorrentAddDraft: Codable, Sendable, Identifiable, Equatable {
    var id: UUID
    var updatedAt = Date()
    var sourceID: UUID?
    var downloadDirectory: String?
    /// A magnet whose metainfo had not arrived yet. Restored by resolving it again.
    var magnet: String?
    /// Files the import queue accepted but had not parsed yet.
    var pendingURLs: [URL] = []
    /// The card in front when the modal went away.
    var frontItemID: UUID?
    var items: [TorrentAddDraftItem] = []

    var listID: String { "draft:" + id.uuidString }

    var isEmpty: Bool {
        items.isEmpty && pendingURLs.isEmpty && (magnet?.isEmpty ?? true)
    }

    /// The most concrete name the record has: an edited torrent name, a pending
    /// file's name, or the magnet's display name.
    var displayName: String? {
        let front = items.first { $0.id == frontItemID } ?? items.first
        if let name = front?.name, !name.isEmpty { return name }
        if let url = pendingURLs.first {
            let name = url.deletingPathExtension().lastPathComponent
            return name.isEmpty ? url.lastPathComponent : name
        }
        return magnet.flatMap(TorrentAddDraft.magnetDisplayName)
    }

    static func magnetDisplayName(_ magnet: String) -> String? {
        let value = URLComponents(string: magnet)?.queryItems?.first { $0.name == "dn" }?.value
        return value?.isEmpty == false ? value : nil
    }
}

/// A parsed torrent plus the edits the Add card carried for it.
struct TorrentAddDraftItem: Codable, Sendable, Identifiable, Equatable {
    var id: UUID
    var data: Data
    var sourceURL: URL?
    var name: String
    /// nil keeps the card's default of every file wanted.
    var selectedFileIndices: [Int]?
    var filePriorities: [Int: Int]?
    /// Group-level edits, carried by every member of their naming group.
    var groupName: String?
    var smartNamesEnabled: Bool?
}

/// The Add sheet's live session. The id survives restoration, drafts accumulate
/// as imports parse, and the restore record seeds the first presentation.
struct TorrentAddSession: Identifiable {
    let id: UUID
    var drafts: [TorrentFileAddDraft]
    var pendingURLs: [URL]
    var restore: TorrentAddDraft?
}

/// Drafts are a recovery net, never the owner of an add: a write failure is not
/// allowed to block the modal. One JSON file mirrors the add-queue pattern.
@MainActor
@Observable
final class TorrentAddDraftStore {
    private(set) var drafts: [TorrentAddDraft] = []

    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var needsSave = false
    @ObservationIgnored private var terminationObserver: NSObjectProtocol?

    init(fileURL: URL? = TorrentAddDraftStore.defaultFileURL()) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let stored = try? JSONDecoder().decode([TorrentAddDraft].self, from: data) {
            drafts = stored
        }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    var mostRecentFirst: [TorrentAddDraft] {
        drafts.sorted { $0.updatedAt > $1.updatedAt }
    }

    func draft(selectionID: String?) -> TorrentAddDraft? {
        guard let selectionID else { return nil }
        return drafts.first { $0.listID == selectionID }
    }

    func draft(id: UUID) -> TorrentAddDraft? {
        drafts.first { $0.id == id }
    }

    /// The views autosave the whole record on every edit; the store owns its timestamp.
    func capture(_ draft: TorrentAddDraft) {
        var incoming = draft
        incoming.updatedAt = .now
        if let index = drafts.firstIndex(where: { $0.id == incoming.id }) {
            var existing = drafts[index]
            existing.updatedAt = incoming.updatedAt
            guard existing != incoming else { return }
            drafts[index] = incoming
        } else {
            drafts.append(incoming)
        }
        scheduleSave()
    }

    /// Explicit cancel: the user abandoned this add, so nothing is offered later.
    func discard(_ id: UUID) {
        guard drafts.contains(where: { $0.id == id }) else { return }
        drafts.removeAll { $0.id == id }
        needsSave = true
        saveNow()
    }

    func discardAll() {
        guard !drafts.isEmpty else { return }
        drafts.removeAll()
        needsSave = true
        saveNow()
    }

    /// Remove only file items whose model-owned Add queue has a saved receipt.
    /// Other items and still-pending imports in the same session remain recoverable.
    @discardableResult
    func completeAdditions(_ ids: Set<UUID>) -> Bool {
        if !ids.isEmpty {
            var changed = false
            drafts = drafts.compactMap { existing in
                var draft = existing
                let previousCount = draft.items.count
                draft.items.removeAll { ids.contains($0.id) }
                let removedItem = draft.items.count != previousCount
                changed = changed || removedItem
                return removedItem && draft.isEmpty ? nil : draft
            }
            if changed { needsSave = true }
        }
        return saveNow()
    }

    func flush() {
        saveNow()
    }

    private func scheduleSave() {
        needsSave = true
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            saveNow()
        }
    }

    @discardableResult
    private func saveNow() -> Bool {
        saveTask?.cancel()
        saveTask = nil
        guard needsSave, let fileURL else {
            needsSave = false
            return true
        }
        do {
            let data = try JSONEncoder().encode(drafts)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
            needsSave = false
            return true
        } catch {
            // Keep the in-memory drafts; the next edit retries the write.
            needsSave = true
            return false
        }
    }

    static func defaultFileURL() -> URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return nil }
        return base.appendingPathComponent("Glass").appendingPathComponent("add-drafts.json")
    }
}

@MainActor
enum TorrentAddDraftRestore {
    /// A destination removed since the draft was saved falls back to the current one.
    static func sourceID(_ stored: UUID?, in model: RemoteAppModel) -> UUID? {
        guard let stored else { return nil }
        return stored == model.localSourceID || model.profiles.contains { $0.id == stored } ? stored : nil
    }
}

extension TorrentFileAddDraft {
    /// Restores identity and bytes. A source file that is gone stays nil so the
    /// card never reports a trash it cannot perform.
    init?(restoring item: TorrentAddDraftItem) {
        let url = item.sourceURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        self.init(
            id: item.id,
            data: item.data,
            preview: TorrentFilePreview(data: item.data, fallbackURL: url),
            sourceURL: url
        )
    }
}
