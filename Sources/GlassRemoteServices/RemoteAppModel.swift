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
    public private(set) var summary: TorrentSummary
    public private(set) var status: Int
    public private(set) var name: String
    public private(set) var isDownloading: Bool
    public private(set) var isCompleted: Bool

    init(_ summary: TorrentSummary) {
        id = summary.hashString.isEmpty ? "transmission-id:\(summary.id)" : summary.hashString
        hashString = summary.hashString
        self.summary = summary
        status = summary.status
        name = summary.name
        isDownloading = summary.isDownloading
        isCompleted = summary.isCompleted
    }

    @discardableResult
    func apply(_ updatedSummary: TorrentSummary) -> Bool {
        guard summary != updatedSummary else { return false }
        let structureChanged = name != updatedSummary.name
            || summary.queuePosition != updatedSummary.queuePosition
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

    public private(set) var profiles: [RemoteProfile] = []
    public var selectedProfileID: UUID?
    public private(set) var torrentRecords: [TorrentRecord] = []
    public private(set) var torrentStructureRevision = 0
    public private(set) var stats: SessionStats?
    public private(set) var selectedTorrentDetails: TorrentDetails?
    public private(set) var isLoadingTorrentDetails = false
    public private(set) var torrentDetailsError: String?
    public private(set) var loadingTorrentDetailSections: Set<TorrentDetailSection> = []
    public private(set) var torrentDetailSectionErrors: [TorrentDetailSection: String] = [:]
    public private(set) var isLoading = false
    public private(set) var loadingProfileID: UUID?
    public private(set) var isShowingCachedTorrents = false
    public private(set) var isSessionStale = false
    public private(set) var refreshErrorMessage: String?
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
    @ObservationIgnored private var torrentCache: [UUID: CachedTorrentList] = [:]
    @ObservationIgnored private var providersBySourceID: [UUID: any TorrentProvider] = [:]
    @ObservationIgnored private var refreshTasksBySourceID: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var refreshRequestedWhileInProgress: Set<UUID> = []
    @ObservationIgnored private var torrentCachePersistenceTask: Task<Void, Never>?
    @ObservationIgnored private var commandRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var pendingCommandRefreshSourceID: UUID?
    @ObservationIgnored private var pendingCommandDetailHash: String?
    @ObservationIgnored private var pendingCommandCoreDetailRefresh = false
    @ObservationIgnored private var pendingCommandDetailSections: Set<TorrentDetailSection> = []
    @ObservationIgnored private var displayedTorrentSourceID: UUID?
    @ObservationIgnored private var selectedDetailsTorrentHash: String?
    @ObservationIgnored private var detailsRequestID: UUID?
    @ObservationIgnored private var detailsLoadTask: Task<TorrentDetails, Error>?
    @ObservationIgnored private var detailSectionTasks: [TorrentDetailSection: Task<TorrentDetails, Error>] = [:]
    @ObservationIgnored private var loadedTorrentDetailSections: Set<TorrentDetailSection> = []
    @ObservationIgnored private var visibleTorrentDetailSections: Set<TorrentDetailSection> = []
    @ObservationIgnored private var isApplicationActive = true

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
        }
    ) {
        self.profileStore = profileStore
        self.credentialStore = credentialStore
        self.torrentSourceFileDisposer = torrentSourceFileDisposer
        self.rpcClientFactory = rpcClientFactory
        self.localSessionFactory = localSessionFactory
        loadProfiles(initialSourceID: initialSourceID)
    }

    public var localSourceName: String {
        "This Mac"
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
            return torrents.filter(\.isDownloading)
        case .completed:
            return torrents.filter(\.isCompleted)
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
        profiles.removeAll { $0.id == profile.id }
        try? credentialStore.deletePassword(for: profile.id)
        if selectedProfileID == profile.id {
            selectedProfileID = Self.defaultSelectedProfileID(from: profiles)
            replaceTorrentRecords(with: [])
            stats = nil
            serverFreeSpace[profile.id] = nil
            displayedTorrentSourceID = nil
            clearTorrentDetails()
            isShowingCachedTorrents = false
            isSessionStale = false
            refreshErrorMessage = nil
            loadingProfileID = nil
        }
        torrentCache[profile.id] = nil
        downloadDirectoryHistory[profile.id] = nil
        favoriteDownloadDirectories[profile.id] = nil
        serverFreeSpace[profile.id] = nil
        persistProfiles()
        persistTorrentCache()
        persistDownloadDirectoryHistory()
    }

    public func refresh() async {
        let sourceID = selectedSourceID
        let provider: any TorrentProvider
        do {
            provider = try providerForSelectedSource()
        } catch {
            replaceTorrentRecords(with: [])
            stats = nil
            displayedTorrentSourceID = nil
            refreshErrorMessage = error.localizedDescription
            clearTorrentDetails()
            isShowingCachedTorrents = false
            isSessionStale = false
            loadingProfileID = nil
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
        await task.value
        refreshTasksBySourceID[sourceID] = nil
    }

    private func performRefresh(sourceID: UUID, provider: any TorrentProvider) async {
        guard selectedSourceID == sourceID else { return }

        let shouldShowLoading = displayedTorrentSourceID != sourceID
        prepareVisibleTorrentsForRefresh(of: sourceID)
        if shouldShowLoading {
            isLoading = true
            loadingProfileID = sourceID
        }
        defer {
            if shouldShowLoading {
                isLoading = false
                loadingProfileID = nil
            }
        }

        do {
            let snapshot = try await provider.fetchSnapshot()
            guard selectedSourceID == sourceID else { return }
            let mergedTorrents: [TorrentSummary]
            switch snapshot.torrentUpdate {
            case let .full(incoming):
                mergedTorrents = TorrentListMerger.merge(existing: torrents, incoming: incoming)
                replaceTorrentRecords(with: mergedTorrents)
            case let .delta(changed, removedIDs):
                mergedTorrents = applyTorrentDelta(changed: changed, removedIDs: removedIDs)
            }
            if self.stats != snapshot.stats {
                self.stats = snapshot.stats
            }
            if self.serverFreeSpace[sourceID] != snapshot.freeSpace {
                self.serverFreeSpace[sourceID] = snapshot.freeSpace
            }
            self.displayedTorrentSourceID = sourceID
            if self.isShowingCachedTorrents {
                self.isShowingCachedTorrents = false
            }
            if self.isSessionStale {
                self.isSessionStale = false
            }
            if self.refreshErrorMessage != nil {
                self.refreshErrorMessage = nil
            }
            updateTorrentCache(mergedTorrents, for: sourceID)
            await refreshVisibleTorrentDetailsAfterListRefresh(sourceID: sourceID, provider: provider)
        } catch {
            guard !(error is CancellationError) else { return }
            guard selectedSourceID == sourceID else { return }
            let hasVisibleTorrents = !self.torrents.isEmpty
            if self.isSessionStale != hasVisibleTorrents {
                self.isSessionStale = hasVisibleTorrents
            }
            let message = error.localizedDescription
            if self.refreshErrorMessage != message {
                self.refreshErrorMessage = message
            }
        }
    }

    public func runAutoRefresh() async {
        while !Task.isCancelled {
            await refresh()
            do {
                try await Task.sleep(for: currentAutoRefreshInterval)
            } catch {
                break
            }
        }
    }

    public var currentAutoRefreshInterval: Duration {
        isApplicationActive && torrents.contains(where: \.isActive)
            ? Self.activeAutoRefreshInterval
            : Self.quietAutoRefreshInterval
    }

    public func setApplicationActive(_ isActive: Bool) {
        isApplicationActive = isActive
    }

    public func updatePreferences(_ preferences: GlassRemotePreferences) {
        self.preferences = preferences
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
    public func addMagnet(_ magnet: String, downloadDirectory: String?) async -> Bool {
        let sourceID = selectedSourceID
        let didAdd = await performProviderAction(sourceID: sourceID) { provider in
            try await provider.addMagnet(magnet, downloadDirectory: downloadDirectory)
        }
        if didAdd {
            rememberDownloadDirectory(downloadDirectory, for: sourceID)
        }
        return didAdd
    }

    @discardableResult
    public func addTorrentFile(
        _ data: Data,
        torrentName: String? = nil,
        downloadDirectory: String?,
        fileSelection: TorrentAddFileSelection? = nil,
        namingPlan: TorrentAddNamingPlan? = nil,
        sourceID: UUID? = nil,
        sourceURL: URL? = nil,
        trashSourceOnSuccess: Bool = false
    ) async -> Bool {
        let sourceID = sourceID ?? selectedSourceID
        var renameWarnings: [String] = []
        let didAdd = await performProviderAction(sourceID: sourceID) { provider in
            let result = try await provider.addTorrentFile(
                data: data,
                torrentName: namingPlan == nil ? torrentName : nil,
                downloadDirectory: downloadDirectory,
                fileSelection: fileSelection
            )

            guard let namingPlan, let result, !result.wasDuplicate else { return }
            for rename in namingPlan.pathRenames {
                do {
                    try await provider.renamePath(id: result.hashString, path: rename.path, name: rename.name)
                } catch {
                    renameWarnings.append("\(rename.path): \(error.localizedDescription)")
                }
            }

            guard namingPlan.rootName != result.name else { return }
            do {
                try await provider.renamePath(
                    id: result.hashString,
                    path: result.name,
                    name: namingPlan.rootName
                )
            } catch {
                renameWarnings.append("\(result.name): \(error.localizedDescription)")
            }
        }
        if didAdd {
            rememberDownloadDirectory(downloadDirectory, for: sourceID)
        }
        if didAdd, trashSourceOnSuccess {
            torrentSourceFileDisposer.trashTorrentFileIfNeeded(sourceURL)
        }
        if didAdd, !renameWarnings.isEmpty {
            errorMessage = "The torrent was added, but some names could not be cleaned.\n\n" + renameWarnings.joined(separator: "\n")
        }
        return didAdd
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
            let provider = try provider(for: sourceID)
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

    public func loadDetails(for torrent: TorrentSummary?, force: Bool = false) async {
        guard let torrent else {
            clearTorrentDetails()
            return
        }
        let sourceID = selectedSourceID
        let requestID = UUID()

        if !force, selectedDetailsTorrentHash == torrent.hashString, selectedTorrentDetails != nil {
            return
        }

        cancelTorrentDetailRequests()
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
            let provider = try providerForSelectedSource()
            let task = Task {
                try await provider.fetchTorrentDetails(hashString: torrent.hashString)
            }
            detailsLoadTask = task
            let details = try await task.value
            guard
                selectedSourceID == sourceID,
                selectedDetailsTorrentHash == torrent.hashString,
                detailsRequestID == requestID
            else { return }
            selectedTorrentDetails = details
            detailsLoadTask = nil
        } catch {
            guard !(error is CancellationError) else { return }
            guard
                selectedSourceID == sourceID,
                selectedDetailsTorrentHash == torrent.hashString,
                detailsRequestID == requestID
            else { return }
            torrentDetailsError = error.localizedDescription
        }
    }

    public func setVisibleTorrentDetailSections(
        _ sections: Set<TorrentDetailSection>,
        forHashString hashString: String
    ) {
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
        force: Bool = false,
        showsLoadingIndicator: Bool = true
    ) async {
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

        do {
            let sourceID = selectedSourceID
            let provider = try providerForSelectedSource()
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
                selectedSourceID == sourceID,
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
            detailSectionTasks[section] = nil
            if showsLoadingIndicator {
                loadingTorrentDetailSections.remove(section)
            }
            guard !(error is CancellationError), selectedDetailsTorrentHash == hashString else { return }
            torrentDetailSectionErrors[section] = error.localizedDescription
        }
    }

    public func setFileWanted(_ torrent: TorrentSummary, fileIndices: [Int], wanted: Bool) async {
        let sourceID = selectedSourceID
        guard !fileIndices.isEmpty else { return }
        await performProviderAction(
            sourceID: sourceID,
            detailHash: torrent.hashString,
            detailSections: [.files],
            showsActivity: false
        ) { provider in
            try await provider.setFileWanted(ids: [torrent.hashString], fileIndices: fileIndices, wanted: wanted)
        }
    }

    public func setFilePriority(_ torrent: TorrentSummary, fileIndices: [Int], priority: Int) async {
        let sourceID = selectedSourceID
        guard !fileIndices.isEmpty else { return }
        await performProviderAction(
            sourceID: sourceID,
            detailHash: torrent.hashString,
            detailSections: [.files],
            showsActivity: false
        ) { provider in
            try await provider.setFilePriority(ids: [torrent.hashString], fileIndices: fileIndices, priority: priority)
        }
    }

    public func setTorrentPriority(_ torrent: TorrentSummary, priority: Int) async {
        let sourceID = selectedSourceID
        await performProviderAction(
            sourceID: sourceID,
            detailHash: torrent.hashString,
            reloadCoreDetails: true
        ) { provider in
            try await provider.setTorrentPriority(ids: [torrent.hashString], priority: priority)
        }
    }

    public func start(_ torrent: TorrentSummary) async {
        let sourceID = selectedSourceID
        await performProviderAction(sourceID: sourceID) { provider in
            try await provider.start(ids: [torrent.hashString])
        }
    }

    public func stop(_ torrent: TorrentSummary) async {
        let sourceID = selectedSourceID
        await performProviderAction(sourceID: sourceID) { provider in
            try await provider.stop(ids: [torrent.hashString])
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
        if didRemove, let selectedDetailsTorrentHash, ids.contains(selectedDetailsTorrentHash) {
            clearTorrentDetails()
        }
        return didRemove
    }

    public func verify(_ torrent: TorrentSummary) async {
        let sourceID = selectedSourceID
        await performProviderAction(sourceID: sourceID) { provider in
            try await provider.verify(ids: [torrent.hashString])
        }
    }

    public func reannounce(_ torrent: TorrentSummary) async {
        let sourceID = selectedSourceID
        await performProviderAction(sourceID: sourceID) { provider in
            try await provider.reannounce(ids: [torrent.hashString])
        }
    }

    public func moveInQueue(_ torrents: [TorrentSummary], direction: TorrentQueueMove) async {
        let sourceID = selectedSourceID
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
    public func rename(_ torrent: TorrentSummary, to name: String) async -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceID = selectedSourceID
        guard !trimmedName.isEmpty else { return false }
        guard trimmedName != torrent.name else { return true }

        isLoading = true
        loadingProfileID = sourceID
        errorMessage = nil
        defer {
            isLoading = false
            loadingProfileID = nil
        }

        var requestError: (any Error)?
        do {
            let provider = try provider(for: sourceID)
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
            if selectedSourceID == sourceID {
                errorMessage = requestError?.localizedDescription ?? "Transmission did not confirm the rename."
                return false
            }
            return true
        }

        errorMessage = nil
        if selectedDetailsTorrentHash == torrent.hashString {
            Task { await self.loadDetails(for: confirmedTorrent, force: true) }
        }
        return true
    }

    private func confirmRename(sourceID: UUID, hashString: String, newName: String) async -> TorrentSummary? {
        for attempt in 0..<4 {
            guard selectedSourceID == sourceID else { return nil }
            if attempt > 0 {
                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    return nil
                }
            }

            await refresh()
            if let renamedTorrent = torrents.first(where: {
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
        } catch {
            preferences = GlassRemotePreferences()
        }

        do {
            torrentCache = Dictionary(uniqueKeysWithValues: try profileStore.loadTorrentCache().map { ($0.profileID, $0) })
            trimTorrentCache()
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
        if showsActivity {
            isLoading = true
            loadingProfileID = sourceID
        }
        errorMessage = nil
        defer {
            if showsActivity {
                isLoading = false
                loadingProfileID = nil
            }
        }

        do {
            let provider = try provider(for: sourceID)
            try await action(provider)
            if selectedSourceID == sourceID {
                scheduleCommandRefresh(
                    sourceID: sourceID,
                    detailHash: detailHash,
                    reloadCoreDetails: reloadCoreDetails,
                    detailSections: detailSections
                )
            }
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
        pendingCommandRefreshSourceID = sourceID
        if let detailHash {
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
        guard let sourceID = pendingCommandRefreshSourceID else { return }
        let detailHash = pendingCommandDetailHash
        let reloadCoreDetails = pendingCommandCoreDetailRefresh
        let detailSections = pendingCommandDetailSections
        pendingCommandRefreshSourceID = nil
        pendingCommandDetailHash = nil
        pendingCommandCoreDetailRefresh = false
        pendingCommandDetailSections.removeAll()
        commandRefreshTask = nil

        guard selectedSourceID == sourceID else { return }
        await refresh()
        guard let detailHash, selectedDetailsTorrentHash == detailHash else { return }
        if reloadCoreDetails, let torrent = torrents.first(where: { $0.hashString == detailHash }) {
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
            selectedSourceID == sourceID,
            !isLoadingTorrentDetails,
            detailSectionTasks.isEmpty,
            let hashString = selectedDetailsTorrentHash,
            let previousDetails = selectedTorrentDetails
        else { return }

        do {
            let coreDetails = try await provider.fetchTorrentDetails(hashString: hashString)
            guard
                selectedSourceID == sourceID,
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
        await loadDetails(for: torrent, force: true)
        guard var details = selectedTorrentDetails, let previousDetails else { return }
        for section in previousLoadedSections {
            details = details.merging(previousDetails, section: section)
        }
        selectedTorrentDetails = details
        loadedTorrentDetailSections = previousLoadedSections
    }

    private func prepareVisibleTorrentsForRefresh(of sourceID: UUID) {
        if displayedTorrentSourceID == sourceID {
            return
        }

        guard preferences.isTorrentCachingEnabled, let cached = torrentCache[sourceID] else {
            if !torrents.isEmpty {
                replaceTorrentRecords(with: [])
            }
            displayedTorrentSourceID = sourceID
            if isShowingCachedTorrents {
                isShowingCachedTorrents = false
            }
            if isSessionStale {
                isSessionStale = false
            }
            if refreshErrorMessage != nil {
                refreshErrorMessage = nil
            }
            return
        }
        replaceTorrentRecords(with: cached.torrents)
        displayedTorrentSourceID = sourceID
        if !isShowingCachedTorrents {
            isShowingCachedTorrents = true
        }
    }

    private func updateTorrentCache(_ torrents: [TorrentSummary], for profileID: UUID) {
        guard preferences.isTorrentCachingEnabled else { return }
        torrentCache[profileID] = CachedTorrentList(profileID: profileID, torrents: torrents)
        trimTorrentCache()
        scheduleTorrentCachePersistence()
    }

    private func replaceTorrentRecords(with summaries: [TorrentSummary]) {
        let existingByIdentity = Dictionary(
            torrentRecords.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var structureChanged = torrentRecords.map(\.id) != summaries.map(Self.recordIdentity(for:))
        let updatedRecords = summaries.map { summary in
            let identity = Self.recordIdentity(for: summary)
            if let record = existingByIdentity[identity] {
                structureChanged = record.apply(summary) || structureChanged
                return record
            }
            structureChanged = true
            return TorrentRecord(summary)
        }

        if torrentRecords.map(\.id) != updatedRecords.map(\.id) {
            torrentRecords = updatedRecords
        }
        if structureChanged {
            torrentStructureRevision &+= 1
        }
    }

    private func applyTorrentDelta(changed: [TorrentSummary], removedIDs: [Int]) -> [TorrentSummary] {
        let removedIDSet = Set(removedIDs)
        var records = torrentRecords.filter { !removedIDSet.contains($0.summary.id) }
        var recordsByIdentity = Dictionary(
            records.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var structureChanged = records.count != torrentRecords.count

        for summary in changed {
            let identity = Self.recordIdentity(for: summary)
            if let record = recordsByIdentity[identity] {
                structureChanged = record.apply(summary) || structureChanged
            } else {
                let record = TorrentRecord(summary)
                records.append(record)
                recordsByIdentity[identity] = record
                structureChanged = true
            }
        }

        if torrentRecords.map(\.id) != records.map(\.id) {
            torrentRecords = records
        }
        if structureChanged {
            torrentStructureRevision &+= 1
        }
        return records.map(\.summary)
    }

    private static func recordIdentity(for summary: TorrentSummary) -> String {
        summary.hashString.isEmpty ? "transmission-id:\(summary.id)" : summary.hashString
    }

    private func scheduleTorrentCachePersistence() {
        guard torrentCachePersistenceTask == nil else { return }
        let cache = torrentCache.values.sorted { $0.refreshedAt > $1.refreshedAt }
        let profileStore = profileStore
        torrentCachePersistenceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.torrentCachePersistenceDelay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }

            do {
                try await Task.detached(priority: .utility) {
                    try profileStore.saveTorrentCache(cache)
                }.value
                self?.torrentCachePersistenceTask = nil
            } catch {
                guard !Task.isCancelled else { return }
                self?.errorMessage = error.localizedDescription
                self?.torrentCachePersistenceTask = nil
            }
        }
    }

    private func trimTorrentCache() {
        let allowedSourceIDs = Set(profiles.map(\.id) + [Self.localProfileID])
        torrentCache = torrentCache.filter { allowedSourceIDs.contains($0.key) }

        let limit = max(1, preferences.cachedServerLimit)
        let sortedIDs = torrentCache.values
            .sorted { $0.refreshedAt > $1.refreshedAt }
            .map(\.profileID)
        for profileID in sortedIDs.dropFirst(limit) {
            torrentCache[profileID] = nil
        }
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
