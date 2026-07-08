import Combine
import Foundation
import GlassRemoteCore
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
public final class RemoteAppModel: ObservableObject {
    public static let autoRefreshInterval: Duration = .seconds(2)

    @Published public private(set) var profiles: [RemoteProfile] = []
    @Published public var selectedProfileID: UUID?
    @Published public private(set) var torrents: [TorrentSummary] = []
    @Published public private(set) var stats: SessionStats?
    @Published public private(set) var selectedTorrentDetails: TorrentDetails?
    @Published public private(set) var isLoadingTorrentDetails = false
    @Published public private(set) var torrentDetailsError: String?
    @Published public private(set) var isLoading = false
    @Published public private(set) var loadingProfileID: UUID?
    @Published public private(set) var isShowingCachedTorrents = false
    @Published public private(set) var isSessionStale = false
    @Published public private(set) var refreshErrorMessage: String?
    @Published public var selectedTorrentGroup: TorrentGroup = .all
    @Published public private(set) var preferences = GlassRemotePreferences()
    @Published public private(set) var downloadDirectoryHistory: [UUID: [String]] = [:]
    @Published public private(set) var serverFreeSpace: [UUID: ServerFreeSpace] = [:]
    @Published public var errorMessage: String?

    private let profileStore: ProfileStore
    private let credentialStore: CredentialStore
    private let torrentSourceFileDisposer: TorrentSourceFileDisposing
    private let rpcClientFactory: @Sendable (TransmissionRPCConfig) -> any TransmissionRPCServicing
    private let localSessionFactory: @Sendable () -> any LocalTransmissionServicing
    private var torrentCache: [UUID: CachedTorrentList] = [:]
    private var providersBySourceID: [UUID: any TorrentProvider] = [:]
    private var refreshTasksBySourceID: [UUID: Task<Void, Never>] = [:]
    private var displayedTorrentSourceID: UUID?
    private var selectedDetailsTorrentHash: String?

    public init(
        profileStore: ProfileStore,
        credentialStore: CredentialStore,
        torrentSourceFileDisposer: TorrentSourceFileDisposing = SystemTorrentSourceFileDisposer(),
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
        loadProfiles()
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
            torrents = []
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
            torrents = []
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
            await existingTask.value
            return
        }

        let task = Task { @MainActor in
            await self.performRefresh(sourceID: sourceID, provider: provider)
        }
        refreshTasksBySourceID[sourceID] = task
        await task.value
        refreshTasksBySourceID[sourceID] = nil
    }

    private func performRefresh(sourceID: UUID, provider: any TorrentProvider) async {
        guard selectedSourceID == sourceID else { return }

        prepareVisibleTorrentsForRefresh(of: sourceID)
        isLoading = true
        loadingProfileID = sourceID
        defer {
            isLoading = false
            loadingProfileID = nil
        }

        do {
            let snapshot = try await provider.fetchSnapshot()
            guard selectedSourceID == sourceID else { return }
            let mergedTorrents = TorrentListMerger.merge(existing: torrents, incoming: snapshot.torrents)
            self.stats = snapshot.stats
            self.torrents = mergedTorrents
            self.serverFreeSpace[sourceID] = snapshot.freeSpace
            self.displayedTorrentSourceID = sourceID
            self.isShowingCachedTorrents = false
            self.isSessionStale = false
            self.refreshErrorMessage = nil
            updateTorrentCache(mergedTorrents, for: sourceID)
        } catch {
            guard selectedSourceID == sourceID else { return }
            self.isSessionStale = !self.torrents.isEmpty
            self.refreshErrorMessage = error.localizedDescription
        }
    }

    public func runAutoRefresh() async {
        while !Task.isCancelled {
            await refresh()
            do {
                try await Task.sleep(for: Self.autoRefreshInterval)
            } catch {
                break
            }
        }
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
        rememberDownloadDirectory(downloadDirectory, for: sourceID)
        return await performProviderAction(sourceID: sourceID) { provider in
            try await provider.addMagnet(magnet, downloadDirectory: downloadDirectory)
        }
    }

    @discardableResult
    public func addTorrentFile(
        _ data: Data,
        downloadDirectory: String?,
        fileSelection: TorrentAddFileSelection? = nil,
        sourceURL: URL? = nil,
        trashSourceOnSuccess: Bool = false
    ) async -> Bool {
        let sourceID = selectedSourceID
        rememberDownloadDirectory(downloadDirectory, for: sourceID)
        let didAdd = await performProviderAction(sourceID: sourceID) { provider in
            try await provider.addTorrentFile(data: data, downloadDirectory: downloadDirectory, fileSelection: fileSelection)
        }
        if didAdd, trashSourceOnSuccess {
            torrentSourceFileDisposer.trashTorrentFileIfNeeded(sourceURL)
        }
        return didAdd
    }

    public func downloadDirectoriesForSelectedProfile() -> [String] {
        downloadDirectoryHistory[selectedSourceID] ?? []
    }

    public func defaultDownloadDirectoryForSelectedProfile() async -> String? {
        do {
            let provider = try providerForSelectedSource()
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

        if !force, selectedDetailsTorrentHash == torrent.hashString, selectedTorrentDetails != nil {
            return
        }

        selectedDetailsTorrentHash = torrent.hashString
        isLoadingTorrentDetails = true
        torrentDetailsError = nil
        defer { isLoadingTorrentDetails = false }

        do {
            let provider = try providerForSelectedSource()
            let details = try await provider.fetchTorrentDetails(hashString: torrent.hashString)
            guard selectedSourceID == sourceID, selectedDetailsTorrentHash == torrent.hashString else { return }
            selectedTorrentDetails = details
        } catch {
            guard selectedSourceID == sourceID, selectedDetailsTorrentHash == torrent.hashString else { return }
            torrentDetailsError = error.localizedDescription
        }
    }

    public func setFileWanted(_ torrent: TorrentSummary, fileIndices: [Int], wanted: Bool) async {
        let sourceID = selectedSourceID
        guard !fileIndices.isEmpty else { return }
        await performProviderAction(sourceID: sourceID) { provider in
            try await provider.setFileWanted(ids: [torrent.hashString], fileIndices: fileIndices, wanted: wanted)
        }
        await loadDetails(for: torrent, force: true)
    }

    public func setFilePriority(_ torrent: TorrentSummary, fileIndices: [Int], priority: Int) async {
        let sourceID = selectedSourceID
        guard !fileIndices.isEmpty else { return }
        await performProviderAction(sourceID: sourceID) { provider in
            try await provider.setFilePriority(ids: [torrent.hashString], fileIndices: fileIndices, priority: priority)
        }
        await loadDetails(for: torrent, force: true)
    }

    public func setTorrentPriority(_ torrent: TorrentSummary, priority: Int) async {
        let sourceID = selectedSourceID
        await performProviderAction(sourceID: sourceID) { provider in
            try await provider.setTorrentPriority(ids: [torrent.hashString], priority: priority)
        }
        await loadDetails(for: torrent, force: true)
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

    public func remove(_ torrent: TorrentSummary, deleteData: Bool) async {
        await remove([torrent], deleteData: deleteData)
    }

    public func remove(_ torrents: [TorrentSummary], deleteData: Bool) async {
        let sourceID = selectedSourceID
        let ids = torrents.map(\.hashString)
        guard !ids.isEmpty else { return }
        await performProviderAction(sourceID: sourceID) { provider in
            try await provider.remove(ids: ids, deleteLocalData: deleteData)
        }
        if let selectedDetailsTorrentHash, ids.contains(selectedDetailsTorrentHash) {
            clearTorrentDetails()
        }
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

    public func rename(_ torrent: TorrentSummary, to name: String) async {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceID = selectedSourceID
        guard !trimmedName.isEmpty else { return }
        await performProviderAction(sourceID: sourceID) { provider in
            try await provider.renamePath(id: torrent.hashString, path: torrent.name, name: trimmedName)
        }
        if selectedDetailsTorrentHash == torrent.hashString {
            await loadDetails(for: torrent, force: true)
        }
    }

    private func loadProfiles() {
        do {
            profiles = try profileStore.loadProfiles()
            selectedProfileID = Self.defaultSelectedProfileID(from: profiles)
            errorMessage = nil
        } catch {
            profiles = []
            selectedProfileID = Self.defaultSelectedProfileID(from: profiles)
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
            downloadDirectoryHistory = Dictionary(
                uniqueKeysWithValues: try profileStore.loadDownloadDirectoryHistory().map { ($0.profileID, $0.directories) }
            )
            trimDownloadDirectoryHistory()
        } catch {
            downloadDirectoryHistory = [:]
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
            let history = downloadDirectoryHistory
                .map { DownloadDirectoryHistory(profileID: $0.key, directories: $0.value) }
                .sorted { $0.profileID.uuidString < $1.profileID.uuidString }
            try profileStore.saveDownloadDirectoryHistory(history)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func clearTorrentDetails() {
        selectedDetailsTorrentHash = nil
        selectedTorrentDetails = nil
        isLoadingTorrentDetails = false
        torrentDetailsError = nil
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
    }

    @discardableResult
    private func performProviderAction(
        sourceID: UUID,
        action: (any TorrentProvider) async throws -> Void
    ) async -> Bool {
        isLoading = true
        loadingProfileID = sourceID
        errorMessage = nil
        defer {
            isLoading = false
            loadingProfileID = nil
        }

        do {
            let provider = try provider(for: sourceID)
            try await action(provider)
            await refresh()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func prepareVisibleTorrentsForRefresh(of sourceID: UUID) {
        if displayedTorrentSourceID == sourceID, !torrents.isEmpty {
            isShowingCachedTorrents = true
            return
        }

        guard preferences.isTorrentCachingEnabled, let cached = torrentCache[sourceID] else {
            torrents = []
            displayedTorrentSourceID = nil
            isShowingCachedTorrents = false
            isSessionStale = false
            refreshErrorMessage = nil
            return
        }
        torrents = cached.torrents
        displayedTorrentSourceID = sourceID
        isShowingCachedTorrents = true
    }

    private func updateTorrentCache(_ torrents: [TorrentSummary], for profileID: UUID) {
        guard preferences.isTorrentCachingEnabled else { return }
        torrentCache[profileID] = CachedTorrentList(profileID: profileID, torrents: torrents)
        trimTorrentCache()
        persistTorrentCache()
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
