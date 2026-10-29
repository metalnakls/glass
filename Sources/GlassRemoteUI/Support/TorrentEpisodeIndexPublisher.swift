import Foundation
import GlassRemoteCore
import GlassRemoteServices
import Observation

enum DemandActionOutcome: Sendable, Equatable {
    case accepted
    case failed(YinaDemandReceipt.FailureReason)
    case interrupted
}

/// Keeps shared YINA transfer inventories current without depending on the Inspector.
@MainActor
@Observable
final class TorrentEpisodeIndexPublisher {
    static let shared = TorrentEpisodeIndexPublisher()

    private static let activeInterval: TimeInterval = 15
    private static let inactiveInterval: TimeInterval = 30
    private static let completedInterval: TimeInterval = 5 * 60
    private static let maximumBatchSize = 32

    private struct Candidate: Sendable {
        let summary: TorrentSummary
        let sourceID: UUID
        let title: String
        let isActive: Bool
        let isLocal: Bool
        let folderLink: TorrentThumbnailFolderLink?
    }

    private struct SourceWork {
        var candidates: [String: Candidate] = [:]
        var lastPublishedAt: [String: Date] = [:]
        var knownShows: [String: KnownShow] = [:]
        var demandCursor = 0
        var cursor = 0
        var task: Task<Void, Never>?
    }

    private struct KnownShow: Sendable {
        let showID: UUID
        let rootURL: URL
        let remotePath: String
        let isLocal: Bool
        let folderLink: TorrentThumbnailFolderLink?
    }

    struct ScheduleEntry {
        let hash: String
        let isActive: Bool
        let lastPublishedAt: Date?
    }

    nonisolated static func scheduledBatch(
        entries: [ScheduleEntry],
        now: Date,
        activeCadence: TimeInterval,
        inactiveCadence: TimeInterval,
        completedCadence: TimeInterval,
        cursor: Int,
        limit: Int
    ) -> (hashes: [String], nextCursor: Int) {
        guard !entries.isEmpty, limit > 0 else { return ([], 0) }
        let ordered = entries.sorted { $0.hash < $1.hash }
        let eligible = Set(ordered.filter { entry in
            let cadence = entry.isActive ? (activeCadence > 0 ? activeCadence : inactiveCadence) : completedCadence
            return now.timeIntervalSince(entry.lastPublishedAt ?? .distantPast) >= cadence
        }.map(\.hash))
        guard !eligible.isEmpty else { return ([], cursor % ordered.count) }
        let start = ((cursor % ordered.count) + ordered.count) % ordered.count
        let rotated = (0..<ordered.count).map { ordered[(start + $0) % ordered.count] }
        let batch = Array(rotated.filter { eligible.contains($0.hash) }.prefix(limit))
        guard let last = batch.last,
              let index = ordered.firstIndex(where: { $0.hash == last.hash }) else { return ([], start) }
        return (batch.map(\.hash), (index + 1) % ordered.count)
    }

    @ObservationIgnored private weak var model: RemoteAppModel?
    @ObservationIgnored private var sources: [UUID: SourceWork] = [:]
    @ObservationIgnored private var appIsActive = true
    @ObservationIgnored private let writerID = UUID()

    private init() {}

    func attach(model: RemoteAppModel?) {
        if self.model === model { return }
        cancelAll()
        self.model = model
        guard let model else { return }
        for source in model.sources {
            sourceDidRefresh(sourceID: source.id, records: source.records, isLocal: source.id == model.localSourceID)
        }
    }

    func setApplicationActive(_ active: Bool) {
        appIsActive = active
    }

    func sourceDidRefresh(sourceID: UUID, records: [TorrentRecord], isLocal: Bool, forceHash: String? = nil) {
        guard model != nil else { return }
        var work = sources[sourceID] ?? SourceWork()
        var candidates: [String: Candidate] = [:]
        for record in records where !record.isAdding && !record.hashString.isEmpty {
            let naming = TorrentNameCleaner.seasonDescriptor(for: .init(rootName: record.name, files: []))
            guard record.season != nil || naming != nil,
                  let title = record.season?.title ?? naming?.title ?? record.displayName,
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let link = isLocal ? nil : TorrentThumbnailService.shared.link(for: sourceID)
            guard isLocal || link != nil else { continue }
            let candidate = Candidate(
                summary: record.summary,
                sourceID: record.sourceID,
                title: title,
                isActive: record.summary.isActive,
                isLocal: isLocal,
                folderLink: link
            )
            if let previous = work.candidates[record.hashString],
               previous.summary.downloadDir != candidate.summary.downloadDir || previous.title != candidate.title {
                work.lastPublishedAt[record.hashString] = .distantPast
                work.knownShows[record.hashString] = nil
            }
            candidates[record.hashString] = candidate
        }
        if let forceHash { work.lastPublishedAt[forceHash] = .distantPast }
        work.candidates = candidates
        work.lastPublishedAt = work.lastPublishedAt.filter { candidates[$0.key] != nil }
        work.knownShows = work.knownShows.filter { candidates[$0.key] != nil }
        sources[sourceID] = work
        schedule(sourceID: sourceID)
    }

    func sourceWasRemoved(_ sourceID: UUID) {
        sources[sourceID]?.task?.cancel()
        sources[sourceID] = nil
    }

    private func schedule(sourceID: UUID) {
        guard var work = sources[sourceID], work.task == nil, !work.candidates.isEmpty else { return }
        work.task = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.publishDue(sourceID: sourceID)
                do { try await Task.sleep(for: .seconds(self.appIsActive ? Self.activeInterval : Self.inactiveInterval)) }
                catch { break }
            }
            self?.finish(sourceID: sourceID)
        }
        sources[sourceID] = work
    }

    private func finish(sourceID: UUID) {
        sources[sourceID]?.task = nil
        if sources[sourceID]?.candidates.isEmpty == true { sources[sourceID] = nil }
    }

    private func publishDue(sourceID: UUID) async {
        guard let model, sources[sourceID]?.candidates.isEmpty == false else { return }
        await processKnownDemands(sourceID: sourceID)
        guard let current = sources[sourceID] else { return }
        let plan = Self.scheduledBatch(entries: current.candidates.values.map {
            ScheduleEntry(hash: $0.summary.hashString, isActive: $0.isActive,
                          lastPublishedAt: current.lastPublishedAt[$0.summary.hashString])
        }, now: Date.now, activeCadence: appIsActive ? Self.activeInterval : 0,
           inactiveCadence: Self.inactiveInterval, completedCadence: Self.completedInterval,
           cursor: current.cursor, limit: Self.maximumBatchSize)
        let batch = plan.hashes.compactMap { current.candidates[$0] }
        guard !batch.isEmpty else { return }

        var reserved = sources[sourceID] ?? current
        reserved.cursor = plan.nextCursor
        // Reserve before awaiting so overlapping refresh callbacks cannot start another fetch.
        let reservation = Date.now
        for candidate in batch { reserved.lastPublishedAt[candidate.summary.hashString] = reservation }
        sources[sourceID] = reserved

        do {
            let details = try await model.fetchDetails(for: batch.map(\.summary), including: [.files], sourceID: sourceID)
            for detail in details {
                guard !Task.isCancelled, sources[sourceID] != nil,
                      let candidate = batch.first(where: { $0.summary.hashString == detail.hashString }),
                      let target = await resolveShowRoot(candidate: candidate, details: detail) else { continue }
                do {
                    defer { target.scope?.stopAccessingSecurityScopedResource() }
                    let index = try ShowEpisodeIndex(details: target.details, relativePathPrefix: "", capturedAt: Date.now)
                    guard !index.episodes.isEmpty else { continue }
                    guard !Task.isCancelled, sources[sourceID] != nil else { continue }
                    let store = YinaShowStore(rootURL: target.root)
                    let descriptor = try await store.createDescriptorIfAbsent()
                    guard !Task.isCancelled, sources[sourceID] != nil else { continue }
                    try await store.publishTransferSnapshot(index, showID: descriptor.showID, writerID: writerID)
                    sources[sourceID]?.knownShows[detail.hashString] = KnownShow(
                        showID: descriptor.showID, rootURL: target.root, remotePath: target.remotePath,
                        isLocal: candidate.isLocal, folderLink: candidate.folderLink
                    )
                    sources[sourceID]?.lastPublishedAt[detail.hashString] = Date.now
                } catch {
                    // A malformed or unavailable sidecar is retried on the normal bounded cadence.
                }
            }
        } catch {
            // Refresh and sidecar failures stay quiet; a later cadence retries.
            for candidate in batch { sources[sourceID]?.lastPublishedAt[candidate.summary.hashString] = .distantPast }
        }
    }

    private func resolveShowRoot(
        candidate: Candidate,
        details: TorrentDetails
    ) async -> (root: URL, details: TorrentDetails, remotePath: String, scope: URL?)? {
        guard let downloadDir = details.downloadDir, downloadDir.hasPrefix("/"),
              details.files.contains(where: { TorrentNameCleaner.isPreviewableVideo($0.name) }) else { return nil }

        let remoteRoot = candidate.isLocal ? "/" : candidate.folderLink?.remoteRoot
        guard let remoteRoot else { return nil }
        let localRoot: URL
        var scopedRoot: URL?
        if candidate.isLocal {
            localRoot = URL(fileURLWithPath: "/", isDirectory: true)
        } else {
            guard let link = candidate.folderLink,
                  !TorrentThumbnailService.shared.isShareUnavailable(sourceID: candidate.sourceID, directory: nil, isLocal: false),
                  let resolved = await Self.resolveBookmark(link.bookmark) else { return nil }
            localRoot = resolved.url
            scopedRoot = resolved.scoped ? resolved.url : nil
        }
        let selected = await Task.detached(priority: .utility) {
            Self.selectShowRoot(expectedTitle: candidate.title, remoteRoot: remoteRoot,
                downloadDirectory: downloadDir, files: details.files, localRoot: localRoot)
        }.value
        guard let selected else {
            scopedRoot?.stopAccessingSecurityScopedResource()
            return nil
        }
        let rebasedDetails = Self.details(details, relativeTo: selected.remotePath)
        guard let rebasedDetails else {
            scopedRoot?.stopAccessingSecurityScopedResource()
            return nil
        }
        return (selected.localURL, rebasedDetails, selected.remotePath, scopedRoot)
    }

    private func processKnownDemands(sourceID: UUID) async {
        guard let model, let work = sources[sourceID] else { return }
        let candidates = work.candidates
        var handled = 0
        let shows = work.knownShows.sorted(by: { $0.key < $1.key })
        guard !shows.isEmpty else { return }
        let start = work.demandCursor % shows.count
        let batch = (0..<min(8, shows.count)).map { shows[(start + $0) % shows.count] }
        sources[sourceID]?.demandCursor = (start + batch.count) % shows.count
        for (hash, show) in batch {
            guard !Task.isCancelled, sources[sourceID] != nil, handled < 4,
                  let candidate = candidates[hash] else { continue }
            var scopedURL: URL?
            if !show.isLocal {
                guard let link = show.folderLink,
                      !TorrentThumbnailService.shared.isShareUnavailable(sourceID: sourceID, directory: nil, isLocal: false),
                      let resolved = await Self.resolveBookmark(link.bookmark) else { continue }
                guard !Task.isCancelled, sources[sourceID] != nil else {
                    if resolved.scoped { resolved.url.stopAccessingSecurityScopedResource() }
                    return
                }
                scopedURL = resolved.scoped ? resolved.url : nil
                guard resolved.url.standardizedFileURL == URL(fileURLWithPath: link.localPath, isDirectory: true).standardizedFileURL else {
                    scopedURL?.stopAccessingSecurityScopedResource()
                    continue
                }
            }
            defer { scopedURL?.stopAccessingSecurityScopedResource() }
            let store = YinaShowStore(rootURL: show.rootURL)
            guard let demands = try? await store.readDemand(showID: show.showID) else { continue }
            guard !Task.isCancelled, sources[sourceID] != nil else { return }
            let inventories = (try? await store.readTransferSnapshots(showID: show.showID)) ?? []
            guard !Task.isCancelled, sources[sourceID] != nil else { return }
            for demand in demands {
                guard handled < 4, demand.revision > 0,
                      processedDemandRevision[demand.requestID].map({ $0 < demand.revision }) ?? true else { continue }
                if let pending = unsavedReceipts[demand.requestID] {
                    if pending.requestRevision == demand.revision {
                        if (try? await store.publishReceipt(pending)) != nil {
                            unsavedReceipts[demand.requestID] = nil
                            rememberProcessedDemand(demand.requestID, revision: demand.revision)
                        }
                        continue
                    }
                    unsavedReceipts[demand.requestID] = nil
                }
                // If receipt discovery fails, never replay an RPC whose result may already be durable.
                guard let receipts = try? await store.readReceipts(showID: show.showID, requestID: demand.requestID),
                      !Task.isCancelled, sources[sourceID] != nil else { continue }
                let current = receipts.filter {
                    $0.requestWriterID == demand.writerID && $0.requestRevision == demand.revision
                }
                if demand.cancelled {
                    if current.contains(where: { $0.outcome == .cancelled }) {
                        rememberProcessedDemand(demand.requestID, revision: demand.revision)
                        continue
                    }
                    let own = receipts.first(where: { $0.receiptWriterID == writerID })
                    guard own?.revision != UInt64.max,
                          let receipt = try? YinaDemandReceipt(
                            showID: show.showID, requestID: demand.requestID,
                            requestWriterID: demand.writerID, receiptWriterID: writerID,
                            revision: (own?.revision ?? 0) + 1, requestRevision: demand.revision,
                            outcome: .cancelled
                          ) else { continue }
                    unsavedReceipts[demand.requestID] = receipt
                    guard (try? await store.publishReceipt(receipt)) != nil else { continue }
                    unsavedReceipts[demand.requestID] = nil
                    handled += 1
                    rememberProcessedDemand(demand.requestID, revision: demand.revision)
                    continue
                }
                if !Self.shouldDispatch(demand, receipts: current) {
                    rememberProcessedDemand(demand.requestID, revision: demand.revision)
                    continue
                }
                guard let identity = Self.targetIdentity(for: demand, inventories: inventories),
                      identity.hashString == hash else { continue }
                handled += 1
                guard let refreshed = try? await model.fetchDetails(for: [candidate.summary], including: [.files], sourceID: sourceID).first,
                      !Task.isCancelled, sources[sourceID] != nil,
                      let target = await resolveShowRoot(candidate: candidate, details: refreshed),
                      target.remotePath == show.remotePath,
                      target.root.standardizedFileURL == show.rootURL.standardizedFileURL else {
                    continue
                }
                defer { target.scope?.stopAccessingSecurityScopedResource() }
                guard let fresh = Self.details(refreshed, relativeTo: show.remotePath),
                      let index = try? ShowEpisodeIndex(details: fresh, relativePathPrefix: "", capturedAt: Date.now),
                      let episode = index.episodes.first(where: { $0.id == identity }),
                      episode.relativePath == demand.relativePath,
                      !Task.isCancelled, sources[sourceID] != nil else { continue }
                let result = await Self.dispatchDemandActionResult(
                    model: model, torrent: candidate.summary, identity: identity, sourceID: sourceID
                )
                guard !Task.isCancelled, sources[sourceID] != nil, result != .interrupted else { continue }
                let own = receipts.first(where: { $0.receiptWriterID == writerID })
                guard own?.revision != UInt64.max else { continue }
                let outcome: YinaDemandReceipt.Outcome
                let reason: YinaDemandReceipt.FailureReason?
                switch result {
                case .accepted: outcome = .accepted; reason = nil
                case .failed(let failure): outcome = .failed; reason = failure
                case .interrupted: continue
                }
                guard let receipt = try? YinaDemandReceipt(
                    showID: show.showID, requestID: demand.requestID,
                    requestWriterID: demand.writerID, receiptWriterID: writerID,
                    revision: (own?.revision ?? 0) + 1, requestRevision: demand.revision,
                    outcome: outcome, reason: reason
                ) else { continue }
                unsavedReceipts[demand.requestID] = receipt
                guard (try? await store.publishReceipt(receipt)) != nil else { continue }
                unsavedReceipts[demand.requestID] = nil
                rememberProcessedDemand(demand.requestID, revision: demand.revision)
                guard result == .accepted,
                      let afterAction = try? await model.fetchDetails(for: [candidate.summary], including: [.files], sourceID: sourceID).first,
                      !Task.isCancelled, sources[sourceID] != nil,
                      let updatedDetails = Self.details(afterAction, relativeTo: show.remotePath),
                      let updatedIndex = try? ShowEpisodeIndex(details: updatedDetails, relativePathPrefix: "", capturedAt: Date.now) else { continue }
                try? await store.publishTransferSnapshot(updatedIndex, showID: show.showID, writerID: writerID)
            }
        }
    }

    nonisolated static func dispatchDemandActions(
        model: RemoteAppModel,
        torrent: TorrentSummary,
        identity: ShowEpisodeIndex.Episode.TransferIdentity,
        sourceID: UUID
    ) async -> Bool {
        await dispatchDemandActionResult(model: model, torrent: torrent, identity: identity, sourceID: sourceID) == .accepted
    }

    nonisolated static func dispatchDemandActionResult(
        model: RemoteAppModel,
        torrent: TorrentSummary,
        identity: ShowEpisodeIndex.Episode.TransferIdentity,
        sourceID: UUID
    ) async -> DemandActionOutcome {
        guard identity.hashString == torrent.hashString, identity.fileIndex >= 0, !Task.isCancelled else {
            return .interrupted
        }
        guard await model.setFileWanted(torrent, fileIndices: [identity.fileIndex], wanted: true, sourceID: sourceID) else {
            return .failed(.selectionFailed)
        }
        guard !Task.isCancelled else { return .interrupted }
        guard await model.setFilePriority(torrent, fileIndices: [identity.fileIndex], priority: 1, sourceID: sourceID) else {
            return .failed(.priorityFailed)
        }
        guard !Task.isCancelled else { return .interrupted }
        guard await model.start(torrent, sourceID: sourceID) else { return .failed(.startFailed) }
        return Task.isCancelled ? .interrupted : .accepted
    }

    /// Only a newer request revision permits another attempt after any writer's outcome.
    nonisolated static func shouldDispatch(_ demand: YinaDownloadDemand,
                                           receipts: [YinaDemandReceipt]) -> Bool {
        guard !demand.cancelled else { return false }
        return !receipts.contains {
            $0.showID == demand.showID && $0.requestID == demand.requestID &&
                $0.requestWriterID == demand.writerID && $0.requestRevision == demand.revision
        }
    }

    nonisolated static func targetIdentity(
        for demand: YinaDownloadDemand,
        inventories: [YinaTransferFragment]
    ) -> ShowEpisodeIndex.Episode.TransferIdentity? {
        guard !demand.cancelled else { return nil }
        let matches = inventories.filter { $0.showID == demand.showID }.flatMap(\.index.episodes).filter { episode in
            episode.relativePath == demand.relativePath &&
                (demand.hashString == nil || episode.id.hashString == demand.hashString) &&
                (demand.fileIndex == nil || episode.id.fileIndex == demand.fileIndex)
        }
        let identities = Set(matches.map(\.id))
        guard identities.count == 1 else { return nil }
        return identities.first
    }

    @ObservationIgnored private var unsavedReceipts: [UUID: YinaDemandReceipt] = [:]
    @ObservationIgnored private var processedDemandRevision: [UUID: UInt64] = [:]
    @ObservationIgnored private var processedDemandOrder: [UUID] = []

    private func rememberProcessedDemand(_ id: UUID, revision: UInt64) {
        if processedDemandRevision[id] == nil { processedDemandOrder.append(id) }
        processedDemandRevision[id] = max(revision, processedDemandRevision[id] ?? 0)
        if processedDemandOrder.count > 1024 {
            processedDemandRevision.removeValue(forKey: processedDemandOrder.removeFirst())
        }
    }

    private static func resolveBookmark(_ bookmark: Data) async -> (url: URL, scoped: Bool)? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var stale = false
                guard let url = try? URL(resolvingBookmarkData: bookmark,
                    options: [.withSecurityScope, .withoutUI, .withoutMounting], relativeTo: nil,
                    bookmarkDataIsStale: &stale) else {
                    continuation.resume(returning: nil)
                    return
                }
                guard !stale, url.startAccessingSecurityScopedResource() else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: (url, true))
            }
        }
    }

    struct SelectedRoot: Sendable, Equatable {
        let remotePath: String
        let localURL: URL
    }

    nonisolated static func selectShowRoot(
        expectedTitle: String,
        remoteRoot: String,
        downloadDirectory: String,
        files: [TorrentFile],
        localRoot: URL
    ) -> SelectedRoot? {
        guard remoteRoot.hasPrefix("/"), downloadDirectory.hasPrefix("/"),
              let expectedKey = normalizedTitle(expectedTitle) else { return nil }
        let base = URL(fileURLWithPath: remoteRoot, isDirectory: true).standardizedFileURL
        let download = URL(fileURLWithPath: downloadDirectory, isDirectory: true).standardizedFileURL
        guard isWithin(download.path, root: base.path) else { return nil }
        let videos = files.filter { TorrentNameCleaner.isPreviewableVideo($0.name) }
        guard !videos.isEmpty, videos.allSatisfy({ isSafeRelativePath($0.name) }) else { return nil }

        var proposed = Set<String>([download.path])
        var parent = download.deletingLastPathComponent()
        for _ in 0..<4 where isWithin(parent.path, root: base.path) {
            proposed.insert(parent.path)
            let next = parent.deletingLastPathComponent()
            if next == parent { break }
            parent = next
        }
        for video in videos where video.name.contains("/") {
            let parts = video.name.split(separator: "/").map(String.init)
            for count in 1...min(parts.count - 1, 3) {
                proposed.insert(download.appendingPathComponent(parts.prefix(count).joined(separator: "/"), isDirectory: true).standardizedFileURL.path)
            }
        }

        let matches = proposed.compactMap { path -> SelectedRoot? in
            guard normalizedTitle(URL(fileURLWithPath: path).lastPathComponent) == expectedKey,
                  isWithin(path, root: base.path),
                  videos.allSatisfy({ video in
                      let absolute = download.appendingPathComponent(video.name).standardizedFileURL.path
                      return isWithin(absolute, root: path)
                  }),
                  let localURL = TorrentThumbnailFolderLink.directoryURL(remoteRoot: remoteRoot,
                    localRoot: localRoot, directory: path) else { return nil }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: localURL.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
            let resolvedRoot = localURL.resolvingSymlinksInPath().standardizedFileURL.path
            let resolvedShare = localRoot.resolvingSymlinksInPath().standardizedFileURL.path
            guard isWithin(resolvedRoot, root: resolvedShare) else { return nil }
            let safeFiles = videos.allSatisfy { video in
                guard let fileURL = TorrentThumbnailFolderLink.fileURL(
                    remoteRoot: remoteRoot, localRoot: localRoot,
                    directory: downloadDirectory, filePath: video.name
                ), isWithin(fileURL.path, root: localURL.path) else { return false }
                var current = fileURL
                while isWithin(current.path, root: localURL.path) {
                    if FileManager.default.fileExists(atPath: current.path) {
                        let resolved = current.resolvingSymlinksInPath().standardizedFileURL.path
                        if !isWithin(resolved, root: resolvedRoot) { return false }
                    }
                    if current.standardizedFileURL.path == localURL.standardizedFileURL.path { break }
                    current.deleteLastPathComponent()
                }
                return true
            }
            guard safeFiles else { return nil }
            return SelectedRoot(remotePath: path, localURL: localURL)
        }
        // A single precise existing title folder is required; ambiguity is skipped.
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    nonisolated static func details(_ details: TorrentDetails, relativeTo showRoot: String) -> TorrentDetails? {
        guard let directory = details.downloadDir else { return nil }
        let download = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL.path
        guard showRoot.hasPrefix("/"), isSafeAbsolutePath(download), isSafeAbsolutePath(showRoot) else { return nil }
        var rebasedFiles: [TorrentFile] = []
        for (index, file) in details.files.enumerated() {
            guard isSafeRelativePath(file.name) else { return nil }
            let absolute = URL(fileURLWithPath: download, isDirectory: true)
                .appendingPathComponent(file.name).standardizedFileURL.path
            guard isWithin(absolute, root: showRoot) else {
                if TorrentNameCleaner.isPreviewableVideo(file.name) { return nil }
                rebasedFiles.append(TorrentFile(name: "__yina_ignored__/file-\(index).bin", length: file.length, bytesCompleted: file.bytesCompleted))
                continue
            }
            let relative = String(absolute.dropFirst(showRoot == "/" ? 1 : showRoot.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !relative.isEmpty else { return nil }
            rebasedFiles.append(TorrentFile(name: relative, length: file.length, bytesCompleted: file.bytesCompleted))
        }
        return TorrentDetails(id: details.id, hashString: details.hashString, name: details.name,
            downloadDir: showRoot, files: rebasedFiles, fileStats: details.fileStats)
    }

    nonisolated private static func normalizedTitle(_ title: String) -> String? {
        let value = TorrentSeriesIdentity.key(for: title)
        return value.isEmpty ? nil : value
    }

    nonisolated private static func isWithin(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }

    nonisolated private static func isSafeRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") && !path.contains("\0") &&
            !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    }

    nonisolated private static func isSafeAbsolutePath(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.contains("\\") && !path.contains("\0") &&
            !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == "." || $0 == ".." })
    }

    private func cancelAll() {
        for work in sources.values { work.task?.cancel() }
        sources.removeAll()
    }
}
