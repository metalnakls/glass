import Foundation
import GlassRemoteCore
import Observation
#if os(macOS)
import Darwin
#elseif os(iOS)
import UIKit
#endif

public protocol TorrentSourceFileDisposing: Sendable {
    func trashTorrentFileIfNeeded(_ url: URL?)
}

public struct SystemTorrentSourceFileDisposer: TorrentSourceFileDisposing {
    public init() {}

    public func trashTorrentFileIfNeeded(_ url: URL?) {
        guard let url, url.isFileURL, url.pathExtension.lowercased() == "torrent" else { return }
        #if os(macOS)
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        #endif
    }
}

@MainActor
@Observable
public final class TorrentRecord: Identifiable {
    public let id: String
    public let hashString: String
    public let sourceID: UUID
    public var isAdding: Bool { additionPhase != nil }
    public let additionID: UUID?
    public private(set) var additionPhase: TorrentAdditionPhase?
    public private(set) var additionError: String?
    public private(set) var additionAccepted = false
    public private(set) var summary: TorrentSummary
    public private(set) var status: Int
    public private(set) var name: String
    public private(set) var season: TorrentSeasonDescriptor?
    public private(set) var displayName: String?
    public private(set) var isDownloading: Bool
    public private(set) var isCompleted: Bool
    public private(set) var isUnfinished: Bool

    init(_ summary: TorrentSummary, sourceID: UUID, displayName: String? = nil, season: TorrentSeasonDescriptor? = nil, isAdding: Bool = false, additionID: UUID? = nil) {
        self.additionID = additionID
        self.additionPhase = isAdding ? .queued : nil
        self.sourceID = sourceID
        id = Self.identity(sourceID: sourceID, hashString: summary.hashString, torrentID: summary.id)
        hashString = summary.hashString
        self.summary = summary
        status = summary.status
        name = summary.name
        self.displayName = displayName
        self.season = season
        isDownloading = summary.isDownloading
        isCompleted = summary.isCompleted
        isUnfinished = summary.isUnfinished
    }

    func updateAddition(phase: TorrentAdditionPhase, error: String?, accepted: Bool = false) {
        additionPhase = phase
        additionError = error
        additionAccepted = accepted
    }

    public static func identity(sourceID: UUID, hashString: String, torrentID: Int = 0) -> String {
        let torrentKey = hashString.isEmpty ? "transmission-id:\(torrentID)" : hashString
        return "\(sourceID.uuidString):\(torrentKey)"
    }

    @discardableResult
    func apply(_ updatedSummary: TorrentSummary, displayName: String? = nil, season: TorrentSeasonDescriptor? = nil) -> Bool {
        guard summary != updatedSummary || self.displayName != displayName || self.season != season else { return false }
        let structureChanged = name != updatedSummary.name || self.displayName != displayName || self.season != season
        self.displayName = displayName
        self.season = season
        if status != updatedSummary.status {
            status = updatedSummary.status
        }
        if name != updatedSummary.name {
            name = updatedSummary.name
        }
        if isDownloading != updatedSummary.isDownloading {
            isDownloading = updatedSummary.isDownloading
        }
        if isCompleted != updatedSummary.isCompleted {
            isCompleted = updatedSummary.isCompleted
        }
        if isUnfinished != updatedSummary.isUnfinished {
            isUnfinished = updatedSummary.isUnfinished
        }
        summary = updatedSummary
        return structureChanged
    }
}

@MainActor
@Observable
public final class RemoteAppModel {
    public static let activeAutoRefreshInterval: Duration = .seconds(2)
    public static let quietAutoRefreshInterval: Duration = .seconds(10)
    private static let torrentCachePersistenceDelay: Duration = .seconds(30)
    private static let commandRefreshDebounce: Duration = .milliseconds(200)
    public static let completionWatchInterval: Duration = .seconds(10)

    private struct WatchedTorrent: Hashable {
        let sourceID: UUID
        let hashString: String
    }

    public private(set) var profiles: [RemoteProfile] = []
    public var selectedProfileID: UUID?
    public private(set) var sources: [TorrentSourceState] = []
    private struct PendingAddition {
        var entry: TorrentAddQueueEntry
        let record: TorrentRecord
        let expectedHashes: Set<String>
        var id: UUID { entry.id }
    }
    private var pendingAdditions: [PendingAddition] = []
    private var pendingAdditionRevision = 0
    @ObservationIgnored private var additionTasks: [UUID: Task<Bool, Never>] = [:]
    @ObservationIgnored private var additionTail: Task<Bool, Never>?
    @ObservationIgnored private var additionResults: [UUID: TorrentAddResult] = [:]
    @ObservationIgnored private var addQueueLoadError: String?

    public var allTorrentRecords: [TorrentRecord] {
        // A confirmed submission and its server record are one visible item while
        // the rename plan finishes. Never show a second, untracked download row.
        let owned = Set(pendingAdditions.compactMap { pending -> String? in
            guard let receipt = pending.entry.receipt else { return nil }
            return TorrentRecord.identity(sourceID: pending.entry.sourceID, hashString: receipt.hashString)
        })
        return pendingAdditions.map(\.record) + sources.flatMap(\.records).filter { !owned.contains($0.id) }
    }

    /// Persist every batch member, including its bytes and options, before any RPC.
    @discardableResult
    public func prepareTorrentAddition(id: UUID, sourceID: UUID, name: String,
                                      size: UInt64, fileCount: Int, downloadDirectory: String?,
                                      namingPlan: TorrentAddNamingPlan?, data: Data? = nil,
                                      fileSelection: TorrentAddFileSelection? = nil,
                                      sourceURL: URL? = nil, trashSourceOnSuccess: Bool = false,
                                      renameDuplicateRoot: Bool = false, startPaused: Bool = false) -> Bool {
        guard !pendingAdditions.contains(where: { $0.id == id }) else { return true }
        var entry = TorrentAddQueueEntry(id: id, sourceID: sourceID, name: name, size: size,
            fileCount: fileCount, data: data, downloadDirectory: downloadDirectory,
            fileSelection: fileSelection, namingPlan: namingPlan, sourceURL: sourceURL,
            trashSourceOnSuccess: trashSourceOnSuccess)
        entry.renameDuplicateRoot = renameDuplicateRoot
        entry.startPaused = startPaused
        let expectedHashes = entry.expectedHashes
        entry.existedBeforeSubmission = sourceState(for: sourceID).records.contains {
            expectedHashes.contains($0.hashString.lowercased())
        }
        appendAddition(entry)
        do { try persistAddQueue(); return true }
        catch { failAddition(id, error: error); return false }
    }

    private func appendAddition(_ entry: TorrentAddQueueEntry) {
        let summary = TorrentSummary(id: -1, hashString: "adding:\(entry.id.uuidString)",
            name: entry.namingPlan?.rootName ?? entry.name, status: 0, percentDone: 0,
            metadataPercentComplete: 1, rateDownload: 0, rateUpload: 0,
            sizeWhenDone: entry.size, leftUntilDone: max(1, entry.size), eta: -1, uploadRatio: 0,
            peersConnected: nil, downloadDir: entry.downloadDirectory, fileCount: entry.fileCount)
        let record = TorrentRecord(summary, sourceID: entry.sourceID,
            displayName: entry.namingPlan?.displayName, season: entry.namingPlan?.season,
            isAdding: true, additionID: entry.id)
        record.updateAddition(phase: entry.phase, error: entry.error, accepted: entry.receipt != nil)
        pendingAdditions.append(PendingAddition(entry: entry, record: record, expectedHashes: entry.expectedHashes))
        pendingAdditionRevision &+= 1
    }

    private func restoreAddQueue() {
        do {
            for var entry in try profileStore.loadTorrentAddQueue() {
                guard !pendingAdditions.contains(where: { $0.id == entry.id }) else { continue }
                if entry.phase != .failed {
                    entry.phase = .failed
                    entry.error = "The previous add was interrupted. Retry to finish it."
                }
                appendAddition(entry)
            }
        } catch {
            addQueueLoadError = "The saved add queue couldn’t be read: \(error.localizedDescription)"
            errorMessage = addQueueLoadError
        }
    }

    private func persistAddQueue() throws {
        // Do not overwrite an unreadable queue with an empty/new one.
        if let addQueueLoadError { throw AdditionError.message(addQueueLoadError) }
        try profileStore.saveTorrentAddQueue(pendingAdditions.map(\.entry))
    }

    private func updateAddition(_ id: UUID, _ change: (inout TorrentAddQueueEntry) -> Void) {
        guard let index = pendingAdditions.firstIndex(where: { $0.id == id }) else { return }
        change(&pendingAdditions[index].entry)
        let entry = pendingAdditions[index].entry
        pendingAdditions[index].record.updateAddition(phase: entry.phase, error: entry.error, accepted: entry.receipt != nil)
    }

    private func failAddition(_ id: UUID, error: any Error, reportError: Bool = true) {
        let accepted = pendingAdditions.first { $0.id == id }?.entry.receipt != nil
        let message = accepted
            ? "Transmission accepted this torrent, but Glass couldn’t finish setting it up.\n\n" + error.localizedDescription
            : error.localizedDescription
        updateAddition(id) { $0.phase = .failed; $0.error = message }
        if reportError { errorMessage = message }
        try? persistAddQueue()
    }

    private func reconcilePendingAdditions() {
        for pending in pendingAdditions {
            let entry = pending.entry
            guard let record = sourceState(for: entry.sourceID).records.first(where: {
                $0.hashString.lowercased() == entry.receipt?.hashString.lowercased()
                    || (entry.attempts > 0 && pending.expectedHashes.contains($0.hashString.lowercased()))
            }) else { continue }
            if entry.receipt != nil, entry.namingComplete {
                do { try retireAddition(entry.id) }
                catch { failAddition(entry.id, error: error) }
            } else if entry.receipt == nil, entry.attempts > 0, additionTasks[entry.id] == nil {
                updateAddition(entry.id) {
                    $0.receipt = TorrentAddResult(hashString: record.hashString, name: record.name,
                        wasDuplicate: $0.existedBeforeSubmission)
                }
                // Recover an accepted request whose reply never reached Glass.
                Task { await retryTorrentAddition(entry.id) }
            }
        }
    }

    private func retireAddition(_ id: UUID) throws {
        guard let index = pendingAdditions.firstIndex(where: { $0.id == id }) else { return }
        let pending = pendingAdditions.remove(at: index)
        do { try persistAddQueue() }
        catch { pendingAdditions.insert(pending, at: index); throw error }
        pendingAdditionRevision &+= 1
        if pending.entry.trashSourceOnSuccess {
            torrentSourceFileDisposer.trashTorrentFileIfNeeded(pending.entry.sourceURL)
        }
    }

    public func cancelTorrentAddition(_ id: UUID) {
        guard additionTasks[id] == nil else { return }
        do { try retireAdditionWithoutDisposal(id) }
        catch { failAddition(id, error: error) }
    }

    private func retireAdditionWithoutDisposal(_ id: UUID) throws {
        updateAddition(id) { $0.trashSourceOnSuccess = false }
        try retireAddition(id)
    }

    private enum AdditionError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case let .message(message) = self { return message }; return nil }
    }
    public private(set) var fileMutationRevision = 0
    public var libraryStructureRevision: Int { sources.reduce(pendingAdditionRevision) { $0 &+ $1.structureRevision } }
    public private(set) var torrentRecords: [TorrentRecord] {
        get { sourceState(for: selectedSourceID).records }
        set { sourceState(for: selectedSourceID).records = newValue }
    }
    public private(set) var torrentStructureRevision: Int {
        get { sourceState(for: selectedSourceID).structureRevision }
        set { sourceState(for: selectedSourceID).structureRevision = newValue }
    }
    public private(set) var stats: SessionStats? {
        get { sourceState(for: selectedSourceID).stats }
        set { sourceState(for: selectedSourceID).stats = newValue }
    }
    public private(set) var selectedTorrentDetails: TorrentDetails?
    public private(set) var isLoadingTorrentDetails = false
    public private(set) var torrentDetailsError: String?
    public private(set) var loadingTorrentDetailSections: Set<TorrentDetailSection> = []
    public private(set) var torrentDetailSectionErrors: [TorrentDetailSection: String] = [:]
    public private(set) var isLoading: Bool {
        get { sourceState(for: selectedSourceID).isLoading }
        set { sourceState(for: selectedSourceID).isLoading = newValue }
    }
    public private(set) var loadingProfileID: UUID?
    public private(set) var isShowingCachedTorrents: Bool {
        get { sourceState(for: selectedSourceID).isShowingCachedTorrents }
        set { sourceState(for: selectedSourceID).isShowingCachedTorrents = newValue }
    }
    public private(set) var isSessionStale: Bool {
        get { sourceState(for: selectedSourceID).isSessionStale }
        set { sourceState(for: selectedSourceID).isSessionStale = newValue }
    }
    public private(set) var refreshErrorMessage: String? {
        get { sourceState(for: selectedSourceID).refreshErrorMessage }
        set { sourceState(for: selectedSourceID).refreshErrorMessage = newValue }
    }
    public var selectedTorrentGroup: TorrentGroup = .all
    public private(set) var preferences = GlassRemotePreferences()
    public private(set) var downloadDirectoryHistory: [UUID: [String]] = [:]
    public private(set) var favoriteDownloadDirectories: [UUID: [String]] = [:]
    public private(set) var serverFreeSpace: [UUID: ServerFreeSpace] = [:]
    public var errorMessage: String?

    private let profileStore: ProfileStore
    private let credentialStore: CredentialStore
    private let torrentSourceFileDisposer: TorrentSourceFileDisposing
    private let rpcClientFactory: @Sendable (TransmissionRPCConfig) -> any TransmissionRPCServicing
    private let localSessionFactory: @Sendable () -> any LocalTransmissionServicing
    private let completionNotifier: (any TorrentCompletionNotifying)?
    private let completionPollingInterval: Duration
    @ObservationIgnored private var torrentCache: [UUID: CachedTorrentList] = [:]
    @ObservationIgnored private var torrentDisplayNames: [String: TorrentStoredDisplayName] = [:]
    @ObservationIgnored private var providersBySourceID: [UUID: any TorrentProvider] = [:]
    @ObservationIgnored private var refreshTasksBySourceID: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var refreshRequestedWhileInProgress: Set<UUID> = []
    @ObservationIgnored private var torrentCachePersistenceTask: Task<Void, Never>?
    @ObservationIgnored private var commandRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var pendingCommandRefreshSourceID: UUID?
    @ObservationIgnored private var pendingCommandDetailHash: String?
    @ObservationIgnored private var pendingCommandCoreDetailRefresh = false
    @ObservationIgnored private var pendingCommandDetailSections: Set<TorrentDetailSection> = []
    @ObservationIgnored private var selectedDetailsTorrentHash: String?
    @ObservationIgnored private var selectedDetailsSourceID: UUID?
    @ObservationIgnored private var pendingCommandRefreshSourceIDs: Set<UUID> = []
    @ObservationIgnored private var detailsRequestID: UUID?
    @ObservationIgnored private var detailsLoadTask: Task<TorrentDetails, Error>?
    @ObservationIgnored private var detailSectionTasks: [TorrentDetailSection: Task<TorrentDetails, Error>] = [:]
    @ObservationIgnored private var loadedTorrentDetailSections: Set<TorrentDetailSection> = []
    @ObservationIgnored private var visibleTorrentDetailSections: Set<TorrentDetailSection> = []
    public private(set) var isApplicationActive = true
    @ObservationIgnored private var watchedTorrents: [WatchedTorrent: String] = [:]
    @ObservationIgnored private var completionWatcherTask: Task<Void, Never>?

    public init(
        profileStore: ProfileStore,
        credentialStore: CredentialStore,
        torrentSourceFileDisposer: TorrentSourceFileDisposing = SystemTorrentSourceFileDisposer(),
        initialSourceID: UUID? = nil,
        rpcClientFactory: @escaping @Sendable (TransmissionRPCConfig) -> any TransmissionRPCServicing = {
            TransmissionRPCClient(config: $0)
        },
        localSessionFactory: @escaping @Sendable () -> any LocalTransmissionServicing = {
            UnavailableLocalTransmissionSession()
        },
        completionNotifier: (any TorrentCompletionNotifying)? = nil,
        completionPollingInterval: Duration = RemoteAppModel.completionWatchInterval
    ) {
        self.profileStore = profileStore
        self.credentialStore = credentialStore
        self.torrentSourceFileDisposer = torrentSourceFileDisposer
        self.rpcClientFactory = rpcClientFactory
        self.localSessionFactory = localSessionFactory
        self.completionNotifier = completionNotifier
        self.completionPollingInterval = completionPollingInterval
        loadProfiles(initialSourceID: initialSourceID)
        synchronizeSources()
        restoreAddQueue()
    }

    public var localSourceName: String {
        Host.current().localizedName ?? "This Mac"
    }

    public var localSourceSystemImage: String {
        Self.localDeviceSystemImage()
    }

    public var localSourceID: UUID {
        Self.localProfileID
    }

    public var selectedProfile: RemoteProfile? {
        get {
            guard let selectedProfileID else { return nil }
            return profiles.first { $0.id == selectedProfileID }
        }
        set {
            selectedProfileID = newValue?.id
        }
    }

    public var selectedSourceProfile: RemoteProfile? {
        if selectedProfileID == Self.localProfileID || selectedProfileID == nil {
            return nil
        }
        return selectedProfile
    }

    public var selectedSourceID: UUID {
        selectedSourceProfile?.id ?? Self.localProfileID
    }

    public var selectedSourceName: String {
        selectedSourceProfile?.name ?? localSourceName
    }

    public var selectedSourceRPCURL: URL {
        selectedSourceProfile?.rpcURL ?? URL(string: "glass-local://this-mac")!
    }

    public var selectedSourceUsername: String {
        selectedSourceProfile?.username ?? ""
    }

    public var isLocalSourceSelected: Bool {
        selectedProfileID == Self.localProfileID || selectedProfileID == nil
    }

    public var canAddToSelectedSource: Bool {
        true
    }

    public func canAddToRemote(using destination: TorrentAddDestination) -> Bool {
        switch destination {
        case .selectedSource:
            return canAddToSelectedSource
        }
    }

    public var filteredTorrents: [TorrentSummary] {
        switch selectedTorrentGroup {
        case .all:
            return torrents
        case .downloading:
            return torrents.filter(\.isUnfinished)
        case .completed:
            return torrents.filter { !$0.isUnfinished }
        }
    }

    public var torrents: [TorrentSummary] {
        torrentRecords.map(\.summary)
    }

    public func password(for profile: RemoteProfile) -> String {
        (try? credentialStore.password(for: profile.id)) ?? ""
    }

    public func saveProfile(_ profile: RemoteProfile, password: String) {
        invalidateProvider(for: profile.id)
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        synchronizeSources()
        selectedProfileID = profile.id
        persistProfiles()

        do {
            try credentialStore.savePassword(password, for: profile.id)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func deleteProfile(_ profile: RemoteProfile) {
        invalidateProvider(for: profile.id)
        cancelRefresh(for: profile.id)
        stopWatching(sourceID: profile.id)
        profiles.removeAll { $0.id == profile.id }
        try? credentialStore.deletePassword(for: profile.id)
        if selectedProfileID == profile.id {
            selectedProfileID = Self.defaultSelectedProfileID(from: profiles)
            loadingProfileID = nil
        }
        if selectedDetailsSourceID == profile.id { clearTorrentDetails() }
        sources.removeAll { $0.id == profile.id }
        torrentCache[profile.id] = nil
        downloadDirectoryHistory[profile.id] = nil
        favoriteDownloadDirectories[profile.id] = nil
        serverFreeSpace[profile.id] = nil
        pruneTorrentDisplayNames(sourceID: profile.id, keeping: [])
        persistProfiles()
        persistTorrentCache()
        persistDownloadDirectoryHistory()
    }

    public func sourceName(for sourceID: UUID) -> String {
        sourceID == localSourceID ? localSourceName : profiles.first { $0.id == sourceID }?.name ?? "Server"
    }

    private func sourceState(for sourceID: UUID) -> TorrentSourceState {
        if let state = sources.first(where: { $0.id == sourceID }) { return state }
        let state = TorrentSourceState(id: sourceID)
        sources.append(state)
        return state
    }

    private func synchronizeSources() {
        let sourceIDs = [localSourceID] + profiles.map(\.id)
        sources.removeAll { !sourceIDs.contains($0.id) }
        for id in sourceIDs { _ = sourceState(for: id) }
    }

    public func refresh() async {
        await refresh(sourceID: selectedSourceID)
    }

    public func refreshAllSources() async {
        let sourceIDs = sources.map(\.id)
        await withTaskGroup(of: Void.self) { group in
            for sourceID in sourceIDs {
                group.addTask { await self.refresh(sourceID: sourceID) }
            }
        }
    }

    public func refresh(sourceID: UUID) async {
        guard sources.contains(where: { $0.id == sourceID }) else { return }
        let state = sourceState(for: sourceID)
        let provider: any TorrentProvider
        do {
            provider = try self.provider(for: sourceID)
        } catch {
            state.refreshErrorMessage = error.localizedDescription
            state.isSessionStale = !state.records.isEmpty
            return
        }

        if let existingTask = refreshTasksBySourceID[sourceID] {
            refreshRequestedWhileInProgress.insert(sourceID)
            await existingTask.value
            return
        }
        let task = Task { @MainActor in
            while !Task.isCancelled {
                await self.performRefresh(sourceID: sourceID, provider: provider)
                guard self.refreshRequestedWhileInProgress.remove(sourceID) != nil else { break }
            }
        }
        refreshTasksBySourceID[sourceID] = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        refreshTasksBySourceID[sourceID] = nil
    }

    private func performRefresh(sourceID: UUID, provider: any TorrentProvider) async {
        guard sources.contains(where: { $0.id == sourceID }), !Task.isCancelled else { return }
        let state = sourceState(for: sourceID)
        prepareVisibleTorrentsForRefresh(of: sourceID)
        state.isLoading = !state.hasRefreshed
        defer { state.isLoading = false }
        do {
            let snapshot = try await provider.fetchSnapshot()
            guard !Task.isCancelled, sources.contains(where: { $0 === state }) else { return }
            let mergedTorrents: [TorrentSummary]
            switch snapshot.torrentUpdate {
            case let .full(incoming):
                pruneTorrentDisplayNames(sourceID: sourceID, keeping: Set(incoming.map { Self.recordIdentity(for: $0, sourceID: sourceID) }))
                mergedTorrents = TorrentListMerger.merge(existing: state.records.map(\.summary), incoming: incoming)
                replaceTorrentRecords(with: mergedTorrents, sourceID: sourceID)
            case let .delta(changed, removedIDs):
                mergedTorrents = applyTorrentDelta(changed: changed, removedIDs: removedIDs, sourceID: sourceID)
            }
            if state.stats != snapshot.stats { state.stats = snapshot.stats }
            if serverFreeSpace[sourceID] != snapshot.freeSpace { serverFreeSpace[sourceID] = snapshot.freeSpace }
            state.hasRefreshed = true
            if state.isShowingCachedTorrents { state.isShowingCachedTorrents = false }
            if state.isSessionStale { state.isSessionStale = false }
            if state.refreshErrorMessage != nil { state.refreshErrorMessage = nil }
            updateTorrentCache(mergedTorrents, for: sourceID)
            await refreshVisibleTorrentDetailsAfterListRefresh(sourceID: sourceID, provider: provider)
        } catch {
            guard !(error is CancellationError), sources.contains(where: { $0 === state }) else { return }
            let stale = !state.records.isEmpty
            if state.isSessionStale != stale { state.isSessionStale = stale }
            let message = error.localizedDescription
            if state.refreshErrorMessage != message { state.refreshErrorMessage = message }
        }
    }

    public func runAutoRefresh() async {
        guard isApplicationActive else { return }
        await withTaskGroup(of: Void.self) { group in
            for sourceID in sources.map(\.id) {
                group.addTask { await self.runAutoRefresh(sourceID: sourceID) }
            }
        }
    }

    private func runAutoRefresh(sourceID: UUID) async {
        while isApplicationActive && !Task.isCancelled {
            await refresh(sourceID: sourceID)
            guard isApplicationActive, !Task.isCancelled, sources.contains(where: { $0.id == sourceID }) else { return }
            do {
                let state = sourceState(for: sourceID)
                let interval = state.records.contains { $0.summary.isActive }
                    ? Self.activeAutoRefreshInterval : Self.quietAutoRefreshInterval
                try await Task.sleep(for: interval)
            } catch { break }
        }
    }

    public var currentAutoRefreshInterval: Duration {
        isApplicationActive && allTorrentRecords.contains(where: { $0.summary.isActive })
            ? Self.activeAutoRefreshInterval
            : Self.quietAutoRefreshInterval
    }

    public func setApplicationActive(_ isActive: Bool) {
        isApplicationActive = isActive
        if isActive {
            completionNotifier?.clearBadge()
        }
    }

    public func updatePreferences(_ preferences: GlassRemotePreferences) {
        self.preferences = GlassRemotePreferences(isTorrentCachingEnabled: true, cachedServerLimit: preferences.cachedServerLimit)
        trimTorrentCache()
        persistPreferences()
        persistTorrentCache()
        if !preferences.isTorrentCachingEnabled {
            isShowingCachedTorrents = false
        }
    }

    public func testConnection(profile: RemoteProfile, password: String) async -> Bool {
        do {
            let client = rpcClientFactory(TransmissionRPCConfig(profile: profile, password: password))
            try await client.testConnection()
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    public func addMagnet(_ magnet: String, downloadDirectory: String?, sourceID requestedSourceID: UUID? = nil) async -> Bool {
        let sourceID = requestedSourceID ?? selectedSourceID
        let name = URLComponents(string: magnet)?.queryItems?.first { $0.name == "dn" }?.value ?? "Magnet download"
        let id = UUID()
        var entry = TorrentAddQueueEntry(id: id, sourceID: sourceID, name: name, size: 0, fileCount: 1,
            magnet: magnet, downloadDirectory: downloadDirectory, namingPlan: nil)
        let expectedHashes = entry.expectedHashes
        entry.existedBeforeSubmission = sourceState(for: sourceID).records.contains {
            expectedHashes.contains($0.hashString.lowercased())
        }
        appendAddition(entry)
        let succeeded = await retryTorrentAddition(id)
        if !succeeded { errorMessage = pendingAdditions.first { $0.id == id }?.entry.error }
        additionResults[id] = nil
        return succeeded
    }

    @discardableResult
    public func addTorrentFile(
        _ data: Data, torrentName: String? = nil, downloadDirectory: String?,
        fileSelection: TorrentAddFileSelection? = nil, namingPlan: TorrentAddNamingPlan? = nil,
        sourceID: UUID? = nil, sourceURL: URL? = nil, trashSourceOnSuccess: Bool = false,
        pendingAdditionID: UUID? = nil, onSuccess: ((TorrentAddResult?) -> Void)? = nil
    ) async -> Bool {
        let id = pendingAdditionID ?? UUID()
        let sourceID = sourceID ?? selectedSourceID
        let plan = namingPlan ?? torrentName.map { TorrentAddNamingPlan(rootName: $0, pathRenames: []) }
        if !pendingAdditions.contains(where: { $0.id == id }) {
            guard prepareTorrentAddition(id: id, sourceID: sourceID,
                name: plan?.suggestedName ?? sourceURL?.deletingPathExtension().lastPathComponent ?? "Torrent download",
                size: 0, fileCount: 1, downloadDirectory: downloadDirectory, namingPlan: plan,
                data: data, fileSelection: fileSelection, sourceURL: sourceURL,
                trashSourceOnSuccess: trashSourceOnSuccess,
                renameDuplicateRoot: namingPlan == nil && torrentName != nil) else { return false }
        } else if let index = pendingAdditions.firstIndex(where: { $0.id == id }), pendingAdditions[index].entry.data == nil {
            // Compatibility for callers that prepared the visual row first.
            var entry = pendingAdditions[index].entry
            entry.data = data; entry.fileSelection = fileSelection; entry.namingPlan = plan
            entry.sourceURL = sourceURL; entry.trashSourceOnSuccess = trashSourceOnSuccess
            entry.renameDuplicateRoot = namingPlan == nil && torrentName != nil
            pendingAdditions[index] = PendingAddition(entry: entry, record: pendingAdditions[index].record,
                                                      expectedHashes: entry.expectedHashes)
        }
        let succeeded = await retryTorrentAddition(id)
        if succeeded { onSuccess?(additionResults.removeValue(forKey: id)) }
        else { errorMessage = pendingAdditions.first { $0.id == id }?.entry.error }
        return succeeded
    }

    /// Model-owned, serialized work survives modal dismissal and duplicate clicks.
    @discardableResult
    public func retryTorrentAddition(_ id: UUID) async -> Bool {
        if let running = additionTasks[id] { return await running.value }
        guard pendingAdditions.contains(where: { $0.id == id }) else { return true }
        updateAddition(id) { $0.phase = .queued; $0.error = nil }
        do { try persistAddQueue() }
        catch { failAddition(id, error: error, reportError: false); return false }
        let previous = additionTail
        let task = Task { [self] in
            _ = await previous?.value
            let result = await performQueuedAddition(id)
            additionTasks[id] = nil
            return result
        }
        additionTasks[id] = task
        additionTail = task
        return await task.value
    }

    @discardableResult
    public func downloadTorrentAdditionLocally(_ id: UUID) async -> Bool {
        guard additionTasks[id] == nil,
              let index = pendingAdditions.firstIndex(where: { $0.id == id }) else { return false }
        // Change only the destination. The original file choices and rename plan travel with it.
        var entry = pendingAdditions[index].entry
        entry.sourceID = localSourceID
        entry.downloadDirectory = nil
        entry.receipt = nil; entry.completedRenames = []; entry.namingComplete = false
        entry.attempts = 0; entry.existedBeforeSubmission = false
        entry.phase = .queued; entry.error = nil
        pendingAdditions.remove(at: index)
        appendAddition(entry)
        do { try persistAddQueue() }
        catch { failAddition(id, error: error, reportError: false); return false }
        selectedProfileID = localSourceID
        selectedTorrentGroup = .all
        let directory = await defaultDownloadDirectory(for: localSourceID)
        updateAddition(id) { $0.downloadDirectory = directory }
        return await retryTorrentAddition(id)
    }

    private func performQueuedAddition(_ id: UUID) async -> Bool {
        guard let pending = pendingAdditions.first(where: { $0.id == id }) else { return true }
        let sourceID = pending.entry.sourceID
        do {
            updateAddition(id) { $0.phase = .adding; $0.error = nil }
            try persistAddQueue()
            let provider = try self.provider(for: sourceID)
            var entry = pending.entry
            // A retry checks the server first: a timeout is not proof that an add failed.
            if entry.receipt == nil, entry.attempts > 0, !pending.expectedHashes.isEmpty {
                await refresh(sourceID: sourceID)
                if let error = sourceState(for: sourceID).refreshErrorMessage { throw AdditionError.message(error) }
                let existing = sourceState(for: sourceID).records.map(\.summary)
                if let torrent = existing.first(where: { pending.expectedHashes.contains($0.hashString.lowercased()) }) {
                    entry.receipt = TorrentAddResult(hashString: torrent.hashString, name: torrent.name,
                                                    wasDuplicate: entry.existedBeforeSubmission)
                }
            }
            if entry.receipt == nil {
                entry.attempts += 1
                updateAddition(id) { $0.attempts = entry.attempts }
                try persistAddQueue()
                let result: TorrentAddResult?
                if let data = entry.data {
                    result = try await provider.addTorrentFile(data: data, torrentName: nil,
                        downloadDirectory: entry.downloadDirectory, fileSelection: entry.fileSelection, startPaused: entry.startPaused ?? false)
                } else if let magnet = entry.magnet {
                    result = try await provider.addMagnet(magnet, downloadDirectory: entry.downloadDirectory)
                } else {
                    throw AdditionError.message("The original torrent is missing from this queued add.")
                }
                guard let result, !result.hashString.isEmpty else {
                    throw AdditionError.message("Transmission didn’t confirm the add. Retry to check it.")
                }
                entry.receipt = TorrentAddResult(hashString: result.hashString, name: result.name,
                    wasDuplicate: result.wasDuplicate && (entry.attempts == 1 || entry.existedBeforeSubmission))
            }
            guard let receipt = entry.receipt else { return false }
            updateAddition(id) { $0.receipt = receipt }
            try persistAddQueue() // Save the receipt before any rename can fail.
            if let plan = entry.namingPlan, (!receipt.wasDuplicate || entry.renameDuplicateRoot), !entry.namingComplete {
                for rename in plan.pathRenames where !entry.completedRenames.contains(rename) {
                    try await completeQueuedRename(rename, hash: receipt.hashString, provider: provider)
                    entry.completedRenames.append(rename)
                    updateAddition(id) { $0.completedRenames = entry.completedRenames }
                    try persistAddQueue()
                }
                if plan.rootName != receipt.name {
                    let root = TorrentPathRename(path: receipt.name, name: plan.rootName)
                    if !entry.completedRenames.contains(root) {
                        try await completeQueuedRename(root, hash: receipt.hashString, provider: provider)
                        entry.completedRenames.append(root)
                        updateAddition(id) { $0.completedRenames = entry.completedRenames }
                        try persistAddQueue()
                    }
                }
                if let displayName = plan.displayName {
                    let key = TorrentRecord.identity(sourceID: sourceID, hashString: receipt.hashString)
                    torrentDisplayNames[key] = TorrentStoredDisplayName(rootName: plan.rootName,
                        displayName: displayName, season: plan.season)
                    try profileStore.saveTorrentDisplayNames(torrentDisplayNames)
                }
            }
            updateAddition(id) { $0.namingComplete = true; $0.phase = .confirming; $0.error = nil }
            try persistAddQueue()
            additionResults[id] = receipt
            rememberDownloadDirectory(entry.downloadDirectory, for: sourceID)
            watchAddedTorrent(receipt, sourceID: sourceID)
            await refresh(sourceID: sourceID)
            reconcilePendingAdditions()
            return true
        } catch {
            failAddition(id, error: error, reportError: false)
            return false
        }
    }

    private func completeQueuedRename(_ rename: TorrentPathRename, hash: String, provider: any TorrentProvider) async throws {
        do { try await provider.renamePath(id: hash, path: rename.path, name: rename.name) }
        catch {
            // A rename can also succeed before its reply is lost.
            if let details = try? await provider.fetchTorrentFiles(hashString: hash) {
                let parent = (rename.path as NSString).deletingLastPathComponent
                let destination = parent.isEmpty ? rename.name : parent + "/" + rename.name
                if details.name == destination || details.files.contains(where: {
                    $0.name == destination || $0.name.hasPrefix(destination + "/")
                }) { return }
            }
            throw error
        }
    }

    public func downloadDirectoriesForSelectedProfile() -> [String] {
        downloadDirectories(for: selectedSourceID)
    }

    public func downloadDirectories(for sourceID: UUID) -> [String] {
        downloadDirectoryHistory[sourceID] ?? []
    }

    public func favoriteDownloadDirectories(for sourceID: UUID) -> [String] {
        favoriteDownloadDirectories[sourceID] ?? []
    }

    public func setDownloadDirectory(_ directory: String, isFavorite: Bool, for sourceID: UUID) {
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var favorites = favoriteDownloadDirectories[sourceID] ?? []
        favorites.removeAll { $0 == trimmed }
        if isFavorite {
            favorites.insert(trimmed, at: 0)
        }
        favoriteDownloadDirectories[sourceID] = favorites
        persistDownloadDirectoryHistory()
    }

    public func defaultDownloadDirectoryForSelectedProfile() async -> String? {
        await defaultDownloadDirectory(for: selectedSourceID)
    }

    public func defaultDownloadDirectory(for sourceID: UUID) async -> String? {
        do {
            let provider = try self.provider(for: sourceID)
            return try await provider.fetchDefaultDownloadDirectory()
        } catch {
            return nil
        }
    }

    public func fetchSessionSettingsForSelectedProfile() async -> TransmissionSessionSettings? {
        do {
            let provider = try providerForSelectedSource()
            let settings = try await provider.fetchSessionSettings()
            errorMessage = nil
            return settings
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    public func setSessionSettingsForSelectedProfile(_ patch: TransmissionSessionSettingsPatch) async -> Bool {
        let sourceID = selectedSourceID
        return await performProviderAction(sourceID: sourceID) { provider in
            try await provider.setSessionSettings(patch)
        }
    }

    public func loadDetails(for torrent: TorrentSummary?, sourceID requestedSourceID: UUID? = nil, force: Bool = false) async {
        guard let torrent else {
            clearTorrentDetails()
            return
        }
        let sourceID = requestedSourceID ?? selectedSourceID
        let requestID = UUID()

        if !force, selectedDetailsSourceID == sourceID, selectedDetailsTorrentHash == torrent.hashString, selectedTorrentDetails != nil {
            return
        }

        cancelTorrentDetailRequests()
        selectedDetailsSourceID = sourceID
        selectedDetailsTorrentHash = torrent.hashString
        detailsRequestID = requestID
        isLoadingTorrentDetails = true
        torrentDetailsError = nil
        defer {
            if detailsRequestID == requestID {
                isLoadingTorrentDetails = false
            }
        }

        do {
            let provider = try self.provider(for: sourceID)
            let task = Task {
                try await provider.fetchTorrentDetails(hashString: torrent.hashString)
            }
            detailsLoadTask = task
            let details = try await task.value
            guard
                selectedDetailsSourceID == sourceID,
                selectedDetailsTorrentHash == torrent.hashString,
                detailsRequestID == requestID
            else { return }
            selectedTorrentDetails = details
            detailsLoadTask = nil
        } catch {
            guard !(error is CancellationError) else { return }
            guard
                selectedDetailsSourceID == sourceID,
                selectedDetailsTorrentHash == torrent.hashString,
                detailsRequestID == requestID
            else { return }
            torrentDetailsError = error.localizedDescription
        }
    }

    /// Returns one selection only after the requested sections have arrived (or failed).
    /// Views can retain their previous presentation while this returns nil.
    public func readyTorrentDetails(
        forHashString hashString: String,
        sourceID: UUID,
        including sections: Set<TorrentDetailSection>
    ) -> TorrentDetails? {
        guard selectedDetailsSourceID == sourceID,
              selectedDetailsTorrentHash == hashString,
              !isLoadingTorrentDetails,
              let details = selectedTorrentDetails,
              details.hashString == hashString,
              sections.isDisjoint(with: loadingTorrentDetailSections),
              sections.allSatisfy({ loadedTorrentDetailSections.contains($0) || torrentDetailSectionErrors[$0] != nil })
        else { return nil }
        return details
    }

    /// Files for one torrent, independent of the inspector selection.
    ///
    /// Artwork resolution reads this off the viewport path, so it must never populate or clear
    /// `selectedTorrentDetails`; a dedicated `torrent-get` keeps the selection cache untouched.
    public func fetchFilesOnly(hashString: String, sourceID requestedSourceID: UUID? = nil) async throws -> [TorrentFile] {
        let sourceID = requestedSourceID ?? selectedSourceID
        let provider = try self.provider(for: sourceID)
        return try await provider.fetchTorrentFiles(hashString: hashString).files
    }

    public func fetchDetails(
        for torrents: [TorrentSummary],
        including sections: Set<TorrentDetailSection>,
        sourceID requestedSourceID: UUID? = nil
    ) async throws -> [TorrentDetails] {
        guard !torrents.isEmpty else { return [] }
        let sourceID = requestedSourceID ?? selectedSourceID
        let provider = try self.provider(for: sourceID)
        return try await provider.fetchTorrentDetails(hashStrings: torrents.map(\.hashString), including: sections)
    }

    public func setVisibleTorrentDetailSections(
        _ sections: Set<TorrentDetailSection>,
        forHashString hashString: String,
        sourceID requestedSourceID: UUID? = nil
    ) {
        guard requestedSourceID == nil || requestedSourceID == selectedDetailsSourceID else { return }
        guard selectedDetailsTorrentHash == hashString else { return }
        visibleTorrentDetailSections = sections
        let hiddenSections = detailSectionTasks.keys.filter { !sections.contains($0) }
        for section in hiddenSections {
            detailSectionTasks[section]?.cancel()
            detailSectionTasks[section] = nil
            loadingTorrentDetailSections.remove(section)
        }
    }

    public func loadDetailSection(
        _ section: TorrentDetailSection,
        forHashString hashString: String,
        sourceID requestedSourceID: UUID? = nil,
        force: Bool = false,
        showsLoadingIndicator: Bool = true
    ) async {
        guard requestedSourceID == nil || requestedSourceID == selectedDetailsSourceID else { return }
        guard
            selectedDetailsTorrentHash == hashString,
            selectedTorrentDetails != nil,
            visibleTorrentDetailSections.contains(section) || force
        else { return }

        if !force, loadedTorrentDetailSections.contains(section) { return }
        if let existingTask = detailSectionTasks[section], !force {
            _ = try? await existingTask.value
            return
        }

        detailSectionTasks[section]?.cancel()
        if showsLoadingIndicator {
            loadingTorrentDetailSections.insert(section)
        }
        torrentDetailSectionErrors[section] = nil

        let sourceID = selectedDetailsSourceID ?? selectedSourceID
        do {
            let provider = try self.provider(for: sourceID)
            let task = Task {
                switch section {
                case .files:
                    try await provider.fetchTorrentFiles(hashString: hashString)
                case .peers:
                    try await provider.fetchTorrentPeers(hashString: hashString)
                case .trackers:
                    try await provider.fetchTorrentTrackers(hashString: hashString)
                case .pieces:
                    try await provider.fetchTorrentPieces(hashString: hashString)
                }
            }
            detailSectionTasks[section] = task
            let update = try await task.value
            guard
                selectedDetailsSourceID == sourceID,
                selectedDetailsTorrentHash == hashString,
                let details = selectedTorrentDetails
            else { return }
            selectedTorrentDetails = details.merging(update, section: section)
            loadedTorrentDetailSections.insert(section)
            detailSectionTasks[section] = nil
            if showsLoadingIndicator {
                loadingTorrentDetailSections.remove(section)
            }
        } catch {
            guard selectedDetailsSourceID == sourceID, selectedDetailsTorrentHash == hashString else { return }
            detailSectionTasks[section] = nil
            if showsLoadingIndicator { loadingTorrentDetailSections.remove(section) }
            guard !(error is CancellationError) else { return }
            torrentDetailSectionErrors[section] = error.localizedDescription
        }
    }

    @discardableResult
    public func setFileWanted(_ torrent: TorrentSummary, fileIndices: [Int], wanted: Bool, sourceID requestedSourceID: UUID? = nil) async -> Bool {
        let sourceID = requestedSourceID ?? selectedSourceID
        guard !fileIndices.isEmpty else { return true }
        let succeeded = await performProviderAction(
            sourceID: sourceID,
            detailHash: torrent.hashString,
            detailSections: [.files],
            showsActivity: false
        ) { provider in
            try await provider.setFileWanted(ids: [torrent.hashString], fileIndices: fileIndices, wanted: wanted)
        }
        fileMutationRevision &+= 1
        return succeeded
    }

    @discardableResult
    public func setFilePriority(_ torrent: TorrentSummary, fileIndices: [Int], priority: Int, sourceID requestedSourceID: UUID? = nil) async -> Bool {
        let sourceID = requestedSourceID ?? selectedSourceID
        guard !fileIndices.isEmpty else { return true }
        let previous = selectedDetailsSourceID == sourceID && selectedDetailsTorrentHash == torrent.hashString
            ? selectedTorrentDetails?.fileStats : nil
        updateDisplayedFilePriorities(fileIndices, priority: priority, sourceID: sourceID, hash: torrent.hashString)
        let succeeded = await performProviderAction(
            sourceID: sourceID,
            detailHash: torrent.hashString,
            detailSections: [.files],
            showsActivity: false
        ) { provider in
            try await provider.setFilePriority(ids: [torrent.hashString], fileIndices: fileIndices, priority: priority)
        }
        if !succeeded, let previous {
            updateDisplayedFilePriorities(fileIndices, priority: priority, sourceID: sourceID,
                hash: torrent.hashString, restoring: previous)
        }
        fileMutationRevision &+= 1
        return succeeded
    }

    private func updateDisplayedFilePriorities(_ indices: [Int], priority: Int, sourceID: UUID,
        hash: String, restoring previous: [TorrentFileStats]? = nil) {
        guard selectedDetailsSourceID == sourceID, selectedDetailsTorrentHash == hash,
              let details = selectedTorrentDetails else { return }
        let affected = Set(indices)
        let stats = details.fileStats.enumerated().map { index, stat in
            guard affected.contains(index) else { return stat }
            if let previous {
                // A rejected request must not undo a newer priority change.
                guard stat.priority == priority, previous.indices.contains(index) else { return stat }
                return TorrentFileStats(bytesCompleted: stat.bytesCompleted, wanted: stat.wanted,
                    priority: previous[index].priority)
            }
            return TorrentFileStats(bytesCompleted: stat.bytesCompleted, wanted: stat.wanted, priority: priority)
        }
        let update = TorrentDetails(id: details.id, hashString: details.hashString, name: details.name,
            files: details.files, fileStats: stats)
        selectedTorrentDetails = details.merging(update, section: .files)
    }

    public func smartRename(_ details: TorrentDetails, sourceID: UUID) async {
        guard let plan = TorrentNameCleaner.plan(rootName: details.name, files: details.files,
            selectedFileIndices: Set(details.files.indices)) else { return }
        let didRename = await performProviderAction(sourceID: sourceID, detailHash: details.hashString,
            reloadCoreDetails: true, detailSections: [.files]) { provider in
            for rename in plan.pathRenames {
                try await provider.renamePath(id: details.hashString, path: rename.path, name: rename.name)
            }
            if plan.rootName != details.name {
                try await provider.renamePath(id: details.hashString, path: details.name, name: plan.rootName)
            }
        }
        if didRename, let displayName = plan.displayName {
            let key = TorrentRecord.identity(sourceID: sourceID, hashString: details.hashString)
            torrentDisplayNames[key] = TorrentStoredDisplayName(rootName: plan.rootName, displayName: displayName, season: plan.season)
            do {
                try profileStore.saveTorrentDisplayNames(torrentDisplayNames)
                let state = sourceState(for: sourceID)
                if let record = state.records.first(where: { $0.hashString == details.hashString }) {
                    _ = record.apply(record.summary, displayName: displayName, season: plan.season)
                    state.structureRevision &+= 1
                }
            } catch { errorMessage = error.localizedDescription }
        }
        fileMutationRevision &+= 1
    }

    public func setTorrentPriority(_ torrent: TorrentSummary, priority: Int, sourceID requestedSourceID: UUID? = nil) async {
        let sourceID = requestedSourceID ?? selectedSourceID
        await performProviderAction(
            sourceID: sourceID,
            detailHash: torrent.hashString,
            reloadCoreDetails: true
        ) { provider in
            try await provider.setTorrentPriority(ids: [torrent.hashString], priority: priority)
        }
    }

    @discardableResult
    public func start(_ torrent: TorrentSummary, sourceID requestedSourceID: UUID? = nil) async -> Bool {
        await start([torrent], sourceID: requestedSourceID)
    }

    @discardableResult
    public func start(_ torrents: [TorrentSummary], sourceID requestedSourceID: UUID? = nil) async -> Bool {
        guard !torrents.isEmpty else { return true }
        let sourceID = requestedSourceID ?? selectedSourceID
        return await performProviderAction(sourceID: sourceID) { provider in
            try await provider.start(ids: torrents.map(\.hashString))
        }
    }

    @discardableResult
    public func stop(_ torrent: TorrentSummary, sourceID requestedSourceID: UUID? = nil) async -> Bool {
        await stop([torrent], sourceID: requestedSourceID)
    }

    @discardableResult
    public func stop(_ torrents: [TorrentSummary], sourceID requestedSourceID: UUID? = nil) async -> Bool {
        guard !torrents.isEmpty else { return true }
        let sourceID = requestedSourceID ?? selectedSourceID
        return await performProviderAction(sourceID: sourceID) { provider in
            try await provider.stop(ids: torrents.map(\.hashString))
        }
    }

    @discardableResult
    public func remove(_ torrent: TorrentSummary, deleteData: Bool) async -> Bool {
        await remove([torrent], deleteData: deleteData)
    }

    @discardableResult
    public func remove(_ torrents: [TorrentSummary], deleteData: Bool) async -> Bool {
        await remove(torrents, deleteData: deleteData, sourceID: selectedSourceID)
    }

    @discardableResult
    public func remove(_ torrents: [TorrentSummary], deleteData: Bool, sourceID: UUID) async -> Bool {
        let ids = torrents.map(\.hashString)
        guard !ids.isEmpty else { return true }
        let didRemove = await performProviderAction(sourceID: sourceID) { provider in
            try await provider.remove(ids: ids, deleteLocalData: deleteData)
        }
        if didRemove, selectedDetailsSourceID == sourceID, let selectedDetailsTorrentHash, ids.contains(selectedDetailsTorrentHash) {
            clearTorrentDetails()
        }
        if didRemove {
            stopWatching(sourceID: sourceID, hashStrings: Set(ids))
            let state = sourceState(for: sourceID)
            state.records.removeAll { ids.contains($0.hashString) }
            state.structureRevision &+= 1
            if var cached = torrentCache[sourceID] {
                cached.torrents.removeAll { ids.contains($0.hashString) }
                torrentCache[sourceID] = cached
                persistTorrentCache()
            }
            let remaining = Set(sourceState(for: sourceID).records.filter { !ids.contains($0.hashString) }.map(\.id))
            pruneTorrentDisplayNames(sourceID: sourceID, keeping: remaining)
        }
        return didRemove
    }

    var isCompletionWatcherRunning: Bool {
        completionWatcherTask != nil
    }

    func checkWatchedTorrentCompletions() async {
        let watches = watchedTorrents
        for (watch, fallbackName) in watches {
            guard watchedTorrents[watch] != nil else { continue }
            do {
                let details = try await provider(for: watch.sourceID)
                    .fetchTorrentDetails(hashString: watch.hashString)
                guard Self.isCompleted(details) else { continue }
                watchedTorrents[watch] = nil
                completionNotifier?.notifyTorrentCompleted(name: details.name.isEmpty ? fallbackName : details.name)
            } catch {
                // Keep watching through transient server and network failures.
            }
        }
        stopCompletionWatcherIfIdle()
    }

    private func watchAddedTorrent(_ result: TorrentAddResult?, sourceID: UUID) {
        guard let result, !result.wasDuplicate, !result.hashString.isEmpty else { return }
        let watch = WatchedTorrent(sourceID: sourceID, hashString: result.hashString)
        watchedTorrents[watch] = result.name
        completionNotifier?.requestAuthorization()
        startCompletionWatcherIfNeeded()
    }

    private func startCompletionWatcherIfNeeded() {
        guard completionWatcherTask == nil, !watchedTorrents.isEmpty else { return }
        completionWatcherTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                do {
                    try await Task.sleep(for: self.completionPollingInterval)
                } catch {
                    return
                }
                await self.checkWatchedTorrentCompletions()
            }
        }
    }

    private func stopWatching(sourceID: UUID, hashStrings: Set<String>? = nil) {
        watchedTorrents = watchedTorrents.filter { watch, _ in
            guard watch.sourceID == sourceID else { return true }
            guard let hashStrings else { return false }
            return !hashStrings.contains(watch.hashString)
        }
        stopCompletionWatcherIfIdle()
    }

    private func stopCompletionWatcherIfIdle() {
        guard watchedTorrents.isEmpty else { return }
        completionWatcherTask?.cancel()
        completionWatcherTask = nil
    }

    private static func isCompleted(_ details: TorrentDetails) -> Bool {
        if let percentDone = details.percentDone, percentDone >= 1 { return true }
        if let doneDate = details.doneDate, doneDate > 0 { return true }
        return details.leftUntilDone == 0 && (details.sizeWhenDone ?? 0) > 0
    }

    public func verify(_ torrent: TorrentSummary, sourceID requestedSourceID: UUID? = nil) async {
        let sourceID = requestedSourceID ?? selectedSourceID
        await performProviderAction(sourceID: sourceID) { provider in
            try await provider.verify(ids: [torrent.hashString])
        }
    }

    public func reannounce(_ torrent: TorrentSummary, sourceID requestedSourceID: UUID? = nil) async {
        let sourceID = requestedSourceID ?? selectedSourceID
        await performProviderAction(sourceID: sourceID) { provider in
            try await provider.reannounce(ids: [torrent.hashString])
        }
    }

    /// Moves a card (including all grouped members) before another card in the same source.
    private var reorderGenerations: [UUID: Int] = [:]

    public func reorder(_ hashes: [String], before targetHashes: [String], sourceID: UUID) async {
        let state = sourceState(for: sourceID)
        let ordered = state.records
        let moving = ordered.filter { hashes.contains($0.hashString) }
        let remaining = ordered.filter { !hashes.contains($0.hashString) }
        guard !moving.isEmpty else { return }
        let target: Int
        if targetHashes.isEmpty { target = remaining.count }
        else {
            guard let index = remaining.firstIndex(where: { targetHashes.contains($0.hashString) }) else { return }
            target = index
        }
        var optimistic = remaining
        optimistic.insert(contentsOf: moving, at: target)
        guard optimistic.map(\.id) != ordered.map(\.id) else { return }
        let generation = (reorderGenerations[sourceID] ?? 0) &+ 1
        reorderGenerations[sourceID] = generation
        state.records = optimistic
        state.structureRevision &+= 1
        let placements = moving.enumerated().map { ($0.element.hashString, target + $0.offset) }
        let movingDown = (ordered.firstIndex { hashes.contains($0.hashString) } ?? 0) < target
        let succeeded = await performProviderAction(sourceID: sourceID, showsActivity: false) { provider in
            for (hash, position) in movingDown ? Array(placements.reversed()) : placements {
                try await provider.setQueuePosition(ids: [hash], position: position)
            }
        }
        guard reorderGenerations[sourceID] == generation else { return }
        if !succeeded {
            // Preserve incoming updates/additions/removals while restoring old order.
            let current = Dictionary(uniqueKeysWithValues: state.records.map { ($0.id, $0) })
            let oldIDs = Set(ordered.map(\.id))
            state.records = ordered.compactMap { current[$0.id] } + state.records.filter { !oldIDs.contains($0.id) }
            state.structureRevision &+= 1
        } else { scheduleTorrentCachePersistence() }
    }

    public func moveInQueue(_ torrents: [TorrentSummary], direction: TorrentQueueMove, sourceID requestedSourceID: UUID? = nil) async {
        let sourceID = requestedSourceID ?? selectedSourceID
        let ids = torrents.map(\.hashString)
        guard !ids.isEmpty else { return }
        await performProviderAction(sourceID: sourceID) { provider in
            switch direction {
            case .top:
                try await provider.queueMoveTop(ids: ids)
            case .up:
                try await provider.queueMoveUp(ids: ids)
            case .down:
                try await provider.queueMoveDown(ids: ids)
            case .bottom:
                try await provider.queueMoveBottom(ids: ids)
            }
        }
    }

    @discardableResult
    public func moveLocalData(_ torrent: TorrentSummary, to downloadDirectory: String, sourceID requestedSourceID: UUID? = nil) async -> Bool {
        let trimmedDirectory = downloadDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (requestedSourceID ?? selectedSourceID) == localSourceID, !trimmedDirectory.isEmpty else { return false }
        if let currentDirectory = torrent.downloadDir,
           URL(fileURLWithPath: currentDirectory).standardizedFileURL
            == URL(fileURLWithPath: trimmedDirectory).standardizedFileURL
        {
            return true
        }
        let sourceID = requestedSourceID ?? selectedSourceID
        let didMove = await performProviderAction(sourceID: sourceID) { provider in
            try await provider.moveData(id: torrent.hashString, to: trimmedDirectory)
        }
        if didMove {
            rememberDownloadDirectory(trimmedDirectory, for: sourceID)
        }
        return didMove
    }

    @discardableResult
    public func rename(_ torrent: TorrentSummary, to name: String, sourceID requestedSourceID: UUID? = nil) async -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceID = requestedSourceID ?? selectedSourceID
        guard !trimmedName.isEmpty else { return false }
        guard trimmedName != torrent.name else { return true }

        if let record = sourceState(for: sourceID).records.first(where: { $0.hashString == torrent.hashString }),
           record.displayName != nil {
            let previous = torrentDisplayNames[record.id]
            let storedName = TorrentStoredDisplayName(rootName: record.summary.name, displayName: trimmedName)
            torrentDisplayNames[record.id] = storedName
            do {
                try profileStore.saveTorrentDisplayNames(torrentDisplayNames)
                _ = record.apply(record.summary, displayName: trimmedName)
                sourceState(for: sourceID).structureRevision &+= 1
                errorMessage = nil
                return true
            } catch {
                torrentDisplayNames[record.id] = previous
                errorMessage = error.localizedDescription
                return false
            }
        }

        let state = sourceState(for: sourceID)
        state.isLoading = true
        loadingProfileID = sourceID
        errorMessage = nil
        defer {
            state.isLoading = false
            loadingProfileID = nil
        }

        var requestError: (any Error)?
        do {
            let provider = try self.provider(for: sourceID)
            try await provider.renamePath(id: torrent.hashString, path: torrent.name, name: trimmedName)
        } catch {
            requestError = error
        }

        let confirmedTorrent = await confirmRename(
            sourceID: sourceID,
            hashString: torrent.hashString,
            newName: trimmedName
        )
        guard let confirmedTorrent else {
            errorMessage = requestError?.localizedDescription ?? "Transmission did not confirm the rename."
            return false
        }

        errorMessage = nil
        if selectedDetailsSourceID == sourceID, selectedDetailsTorrentHash == torrent.hashString {
            Task { await self.loadDetails(for: confirmedTorrent, sourceID: sourceID, force: true) }
        }
        return true
    }

    private func confirmRename(sourceID: UUID, hashString: String, newName: String) async -> TorrentSummary? {
        for attempt in 0..<4 {
            if attempt > 0 {
                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    return nil
                }
            }

            await refresh(sourceID: sourceID)
            if let renamedTorrent = sourceState(for: sourceID).records.map(\.summary).first(where: {
                $0.hashString == hashString && $0.name == newName
            }) {
                return renamedTorrent
            }
        }
        return nil
    }

    private func loadProfiles(initialSourceID: UUID?) {
        do {
            profiles = try profileStore.loadProfiles()
            selectedProfileID = Self.selectedSourceID(initialSourceID, from: profiles)
            errorMessage = nil
        } catch {
            profiles = []
            selectedProfileID = Self.selectedSourceID(initialSourceID, from: profiles)
            errorMessage = error.localizedDescription
        }

        do {
            preferences = try profileStore.loadPreferences()
            preferences.isTorrentCachingEnabled = true
        } catch {
            preferences = GlassRemotePreferences()
        }

        do {
            torrentDisplayNames = try profileStore.loadTorrentDisplayNames()
        } catch {
            errorMessage = "Glass couldn’t restore saved torrent names: \(error.localizedDescription)"
        }

        do {
            torrentCache = Dictionary(uniqueKeysWithValues: try profileStore.loadTorrentCache().map { ($0.profileID, $0) })
            let storedCount = torrentCache.count
            trimTorrentCache()
            if torrentCache.count != storedCount { persistTorrentCache() }
        } catch {
            torrentCache = [:]
        }

        do {
            let storedDirectories = try profileStore.loadDownloadDirectoryHistory()
            downloadDirectoryHistory = Dictionary(uniqueKeysWithValues: storedDirectories.map {
                ($0.profileID, $0.directories)
            })
            favoriteDownloadDirectories = Dictionary(uniqueKeysWithValues: storedDirectories.map {
                ($0.profileID, $0.favoriteDirectories)
            })
            trimDownloadDirectoryHistory()
        } catch {
            downloadDirectoryHistory = [:]
            favoriteDownloadDirectories = [:]
        }
    }

    private func persistProfiles() {
        do {
            try profileStore.saveProfiles(profiles)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func persistPreferences() {
        do {
            try profileStore.savePreferences(preferences)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func persistTorrentCache() {
        torrentCachePersistenceTask?.cancel()
        torrentCachePersistenceTask = nil
        do {
            let cache = torrentCache.values.sorted { $0.refreshedAt > $1.refreshedAt }
            try profileStore.saveTorrentCache(cache)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func persistDownloadDirectoryHistory() {
        do {
            let sourceIDs = Set(downloadDirectoryHistory.keys).union(favoriteDownloadDirectories.keys)
            let history = sourceIDs
                .map {
                    DownloadDirectoryHistory(
                        profileID: $0,
                        directories: downloadDirectoryHistory[$0] ?? [],
                        favoriteDirectories: favoriteDownloadDirectories[$0] ?? []
                    )
                }
                .sorted { $0.profileID.uuidString < $1.profileID.uuidString }
            try profileStore.saveDownloadDirectoryHistory(history)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func clearTorrentDetails() {
        cancelTorrentDetailRequests()
        detailsRequestID = nil
        selectedDetailsSourceID = nil
        selectedDetailsTorrentHash = nil
        selectedTorrentDetails = nil
        isLoadingTorrentDetails = false
        torrentDetailsError = nil
        loadingTorrentDetailSections.removeAll()
        torrentDetailSectionErrors.removeAll()
        loadedTorrentDetailSections.removeAll()
        visibleTorrentDetailSections.removeAll()
    }

    private func cancelTorrentDetailRequests() {
        detailsLoadTask?.cancel()
        detailsLoadTask = nil
        for task in detailSectionTasks.values {
            task.cancel()
        }
        detailSectionTasks.removeAll()
        loadingTorrentDetailSections.removeAll()
        loadedTorrentDetailSections.removeAll()
    }

    private func providerForSelectedSource() throws -> any TorrentProvider {
        try provider(for: selectedSourceID)
    }

    private func provider(for sourceID: UUID) throws -> any TorrentProvider {
        if sourceID == Self.localProfileID {
            return localProvider()
        }
        guard let profile = profiles.first(where: { $0.id == sourceID }) else {
            throw RemoteAppModelError.sourceUnavailable
        }
        return try provider(for: profile)
    }

    private func provider(for profile: RemoteProfile) throws -> any TorrentProvider {
        if let provider = providersBySourceID[profile.id] {
            return provider
        }
        let password = try credentialStore.password(for: profile.id)
        let provider = RemoteTorrentProvider(
            profile: profile,
            password: password,
            clientFactory: rpcClientFactory
        )
        providersBySourceID[profile.id] = provider
        return provider
    }

    private func localProvider() -> any TorrentProvider {
        if let provider = providersBySourceID[Self.localProfileID] {
            return provider
        }
        let provider = LocalTorrentProvider(
            id: Self.localProfileID,
            name: localSourceName,
            systemImage: localSourceSystemImage,
            session: localSessionFactory()
        )
        providersBySourceID[Self.localProfileID] = provider
        return provider
    }

    private func invalidateProvider(for sourceID: UUID) {
        providersBySourceID[sourceID] = nil
    }

    private func cancelRefresh(for profileID: UUID) {
        refreshTasksBySourceID[profileID]?.cancel()
        refreshTasksBySourceID[profileID] = nil
        refreshRequestedWhileInProgress.remove(profileID)
    }

    @discardableResult
    private func performProviderAction(
        sourceID: UUID,
        detailHash: String? = nil,
        reloadCoreDetails: Bool = false,
        detailSections: Set<TorrentDetailSection> = [],
        showsActivity: Bool = true,
        action: (any TorrentProvider) async throws -> Void
    ) async -> Bool {
        let state = sourceState(for: sourceID)
        if showsActivity {
            state.isLoading = true
            loadingProfileID = sourceID
        }
        errorMessage = nil
        defer {
            if showsActivity {
                state.isLoading = false
                loadingProfileID = nil
            }
        }

        do {
            let provider = try self.provider(for: sourceID)
            try await action(provider)
            scheduleCommandRefresh(
                sourceID: sourceID,
                detailHash: detailHash,
                reloadCoreDetails: reloadCoreDetails,
                detailSections: detailSections
            )
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func scheduleCommandRefresh(
        sourceID: UUID,
        detailHash: String?,
        reloadCoreDetails: Bool,
        detailSections: Set<TorrentDetailSection>
    ) {
        pendingCommandRefreshSourceIDs.insert(sourceID)
        if let detailHash, selectedDetailsSourceID == sourceID {
            pendingCommandRefreshSourceID = sourceID
            if pendingCommandDetailHash != detailHash {
                pendingCommandCoreDetailRefresh = false
                pendingCommandDetailSections.removeAll()
            }
            pendingCommandDetailHash = detailHash
            pendingCommandCoreDetailRefresh = pendingCommandCoreDetailRefresh || reloadCoreDetails
            pendingCommandDetailSections.formUnion(detailSections)
        }

        commandRefreshTask?.cancel()
        commandRefreshTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.commandRefreshDebounce)
            } catch {
                return
            }
            await self?.flushCommandRefresh()
        }
    }

    private func flushCommandRefresh() async {
        let sourceID = pendingCommandRefreshSourceID
        let detailHash = pendingCommandDetailHash
        let reloadCoreDetails = pendingCommandCoreDetailRefresh
        let detailSections = pendingCommandDetailSections
        pendingCommandRefreshSourceID = nil
        pendingCommandDetailHash = nil
        pendingCommandCoreDetailRefresh = false
        pendingCommandDetailSections.removeAll()
        commandRefreshTask = nil

        let sourceIDs = pendingCommandRefreshSourceIDs
        pendingCommandRefreshSourceIDs.removeAll()
        for id in sourceIDs { await refresh(sourceID: id) }
        guard let sourceID, selectedDetailsSourceID == sourceID else { return }
        guard let detailHash, selectedDetailsTorrentHash == detailHash else { return }
        if reloadCoreDetails, let torrent = sourceState(for: sourceID).records.map(\.summary).first(where: { $0.hashString == detailHash }) {
            await reloadCoreDetailsPreservingSections(for: torrent)
        }
        for section in detailSections where visibleTorrentDetailSections.contains(section) {
            await loadDetailSection(
                section,
                forHashString: detailHash,
                force: true,
                showsLoadingIndicator: false
            )
        }
    }

    private func refreshVisibleTorrentDetailsAfterListRefresh(
        sourceID: UUID,
        provider: any TorrentProvider
    ) async {
        guard
            selectedDetailsSourceID == sourceID,
            !isLoadingTorrentDetails,
            detailSectionTasks.isEmpty,
            let hashString = selectedDetailsTorrentHash,
            let previousDetails = selectedTorrentDetails
        else { return }

        do {
            let coreDetails = try await provider.fetchTorrentDetails(hashString: hashString)
            guard
                selectedDetailsSourceID == sourceID,
                selectedDetailsTorrentHash == hashString
            else { return }

            var mergedDetails = coreDetails
            for section in loadedTorrentDetailSections {
                mergedDetails = mergedDetails.merging(previousDetails, section: section)
            }
            selectedTorrentDetails = mergedDetails
        } catch {
            guard !(error is CancellationError) else { return }
            return
        }

        let sections = visibleTorrentDetailSections.intersection(loadedTorrentDetailSections)
        for section in sections where detailSectionTasks[section] == nil {
            await loadDetailSection(
                section,
                forHashString: hashString,
                force: true,
                showsLoadingIndicator: false
            )
        }
    }

    private func reloadCoreDetailsPreservingSections(for torrent: TorrentSummary) async {
        let previousDetails = selectedTorrentDetails
        let previousLoadedSections = loadedTorrentDetailSections
        await loadDetails(for: torrent, sourceID: selectedDetailsSourceID, force: true)
        guard var details = selectedTorrentDetails, let previousDetails else { return }
        for section in previousLoadedSections {
            details = details.merging(previousDetails, section: section)
        }
        selectedTorrentDetails = details
        loadedTorrentDetailSections = previousLoadedSections
    }

    private func prepareVisibleTorrentsForRefresh(of sourceID: UUID) {
        let state = sourceState(for: sourceID)
        guard !state.hasRefreshed, state.records.isEmpty,
              let cached = torrentCache[sourceID] else { return }
        replaceTorrentRecords(with: cached.torrents, sourceID: sourceID)
        state.isShowingCachedTorrents = true
    }

    private func updateTorrentCache(_ torrents: [TorrentSummary], for profileID: UUID) {
        torrentCache[profileID] = CachedTorrentList(profileID: profileID, torrents: torrents)
        trimTorrentCache()
        scheduleTorrentCachePersistence()
    }

    private func replaceTorrentRecords(with summaries: [TorrentSummary], sourceID requestedSourceID: UUID? = nil) {
        defer { reconcilePendingAdditions() }
        let sourceID = requestedSourceID ?? selectedSourceID
        let state = sourceState(for: sourceID)
        let existingByIdentity = Dictionary(
            state.records.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var structureChanged = Set(state.records.map(\.id)) != Set(summaries.map { Self.recordIdentity(for: $0, sourceID: sourceID) })
        var updatedRecords = summaries.map { summary in
            let identity = Self.recordIdentity(for: summary, sourceID: sourceID)
            if let record = existingByIdentity[identity] {
                structureChanged = record.apply(summary, displayName: storedDisplayName(for: summary, sourceID: sourceID), season: storedSeason(for: summary, sourceID: sourceID)) || structureChanged
                return record
            }
            structureChanged = true
            return TorrentRecord(summary, sourceID: sourceID, displayName: storedDisplayName(for: summary, sourceID: sourceID), season: storedSeason(for: summary, sourceID: sourceID))
        }

        // Server queue telemetry must not move a card under the user's pointer.
        let incoming = Dictionary(uniqueKeysWithValues: updatedRecords.map { ($0.id, $0) })
        let known = Set(state.records.map(\.id))
        updatedRecords = state.records.compactMap { incoming[$0.id] } + updatedRecords.filter { !known.contains($0.id) }
        if state.records.map(\.id) != updatedRecords.map(\.id) {
            state.records = updatedRecords
        }
        if structureChanged {
            state.structureRevision &+= 1
        }
    }

    private func applyTorrentDelta(changed: [TorrentSummary], removedIDs: [Int], sourceID: UUID) -> [TorrentSummary] {
        defer { reconcilePendingAdditions() }
        let state = sourceState(for: sourceID)
        let removedIDSet = Set(removedIDs)
        var records = state.records.filter { !removedIDSet.contains($0.summary.id) }
        var recordsByIdentity = Dictionary(
            records.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var structureChanged = records.count != state.records.count
        if structureChanged { pruneTorrentDisplayNames(sourceID: sourceID, keeping: Set(records.map(\.id))) }

        for summary in changed {
            let identity = Self.recordIdentity(for: summary, sourceID: sourceID)
            if let record = recordsByIdentity[identity] {
                structureChanged = record.apply(summary, displayName: storedDisplayName(for: summary, sourceID: sourceID), season: storedSeason(for: summary, sourceID: sourceID)) || structureChanged
            } else {
                let record = TorrentRecord(summary, sourceID: sourceID, displayName: storedDisplayName(for: summary, sourceID: sourceID), season: storedSeason(for: summary, sourceID: sourceID))
                records.append(record)
                recordsByIdentity[identity] = record
                structureChanged = true
            }
        }

        if state.records.map(\.id) != records.map(\.id) {
            state.records = records
        }
        if structureChanged {
            state.structureRevision &+= 1
        }
        return records.map(\.summary)
    }

    private static func recordIdentity(for summary: TorrentSummary, sourceID: UUID) -> String {
        TorrentRecord.identity(sourceID: sourceID, hashString: summary.hashString, torrentID: summary.id)
    }

    private func storedSeason(for summary: TorrentSummary, sourceID: UUID) -> TorrentSeasonDescriptor? {
        let key = Self.recordIdentity(for: summary, sourceID: sourceID)
        guard let stored = torrentDisplayNames[key], stored.rootName == summary.name else { return nil }
        return stored.season
    }

    private func storedDisplayName(for summary: TorrentSummary, sourceID: UUID) -> String? {
        let key = Self.recordIdentity(for: summary, sourceID: sourceID)
        guard let stored = torrentDisplayNames[key], stored.rootName == summary.name else { return nil }
        return stored.displayName
    }

    private func pruneTorrentDisplayNames(sourceID: UUID, keeping identities: Set<String>) {
        let prefix = "\(sourceID.uuidString):"
        let removedKeys = torrentDisplayNames.keys.filter { $0.hasPrefix(prefix) && !identities.contains($0) }
        guard !removedKeys.isEmpty else { return }
        for key in removedKeys { torrentDisplayNames[key] = nil }
        do {
            try profileStore.saveTorrentDisplayNames(torrentDisplayNames)
        } catch {
            errorMessage = "Glass couldn’t save torrent names: \(error.localizedDescription)"
        }
    }

    private func scheduleTorrentCachePersistence() {
        guard torrentCachePersistenceTask == nil else { return }
        let profileStore = profileStore
        torrentCachePersistenceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.torrentCachePersistenceDelay)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            let cache = self.torrentCache.values.sorted { $0.refreshedAt > $1.refreshedAt }
            do {
                try await Task.detached(priority: .utility) {
                    try profileStore.saveTorrentCache(cache)
                }.value
                self.torrentCachePersistenceTask = nil
            } catch {
                guard !Task.isCancelled else { return }
                self.errorMessage = error.localizedDescription
                self.torrentCachePersistenceTask = nil
            }
        }
    }

    private func trimTorrentCache() {
        let allowedSourceIDs = Set(profiles.map(\.id) + [Self.localProfileID])
        torrentCache = torrentCache.filter { allowedSourceIDs.contains($0.key) }

        let cutoff = Calendar.current.date(byAdding: .month, value: -2, to: Date()) ?? .distantPast
        torrentCache = torrentCache.filter { $0.value.refreshedAt >= cutoff }
    }

    private func rememberDownloadDirectory(_ directory: String?, for profileID: UUID) {
        let trimmed = directory?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return }

        var directories = downloadDirectoryHistory[profileID] ?? []
        directories.removeAll { $0 == trimmed }
        directories.insert(trimmed, at: 0)
        downloadDirectoryHistory[profileID] = Array(directories.prefix(8))
        trimDownloadDirectoryHistory()
        persistDownloadDirectoryHistory()
    }

    private func trimDownloadDirectoryHistory() {
        let allowedSourceIDs = Set(profiles.map(\.id) + [Self.localProfileID])
        downloadDirectoryHistory = downloadDirectoryHistory.filter { allowedSourceIDs.contains($0.key) }
        favoriteDownloadDirectories = favoriteDownloadDirectories.filter { allowedSourceIDs.contains($0.key) }
    }

    private static func localDeviceSystemImage() -> String {
        #if os(macOS)
        let model = macHardwareModel()
        if model.contains("MacBook") {
            return "macbook"
        }
        if model.contains("Macmini") {
            return "macmini"
        }
        if model.contains("MacPro") {
            return "macpro.gen3"
        }
        if model.contains("MacStudio") {
            return "macstudio"
        }
        return "desktopcomputer"
        #elseif os(iOS)
        switch UIDevice.current.userInterfaceIdiom {
        case .phone:
            return "iphone"
        case .pad:
            return "ipad"
        case .mac:
            return "desktopcomputer"
        case .tv:
            return "tv"
        case .carPlay:
            return "car"
        case .vision:
            return "vision.pro"
        default:
            return "iphone"
        }
        #else
        return "display"
        #endif
    }

    private static func defaultSelectedProfileID(from profiles: [RemoteProfile]) -> UUID? {
        #if os(iOS)
        return nil
        #else
        return profiles.first?.id ?? Self.localProfileID
        #endif
    }

    private static func selectedSourceID(_ initialSourceID: UUID?, from profiles: [RemoteProfile]) -> UUID? {
        if initialSourceID == localProfileID {
            return localProfileID
        }
        if let initialSourceID, profiles.contains(where: { $0.id == initialSourceID }) {
            return initialSourceID
        }
        return defaultSelectedProfileID(from: profiles)
    }

    #if os(macOS)
    private static func macHardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "" }

        var bytes = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &bytes, &size, nil, 0)
        return bytes.withUnsafeBufferPointer { buffer in
            let valueBytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            return String(decoding: valueBytes, as: UTF8.self)
        }
    }
    #endif

    private static let localProfileID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

}

public enum TorrentAddDestination: Sendable {
    case selectedSource
}

public enum TorrentQueueMove: Sendable {
    case top
    case up
    case down
    case bottom
}

private enum RemoteAppModelError: LocalizedError {
    case sourceUnavailable

    var errorDescription: String? {
        switch self {
        case .sourceUnavailable:
            return "The selected torrent source is unavailable."
        }
    }
}
