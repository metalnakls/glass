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

public protocol TransmissionRPCServicing: Sendable {
    func testConnection() async throws
    func fetchDefaultDownloadDirectory() async throws -> String?
    func fetchDefaultFreeSpace() async throws -> ServerFreeSpace?
    func fetchSessionStats() async throws -> SessionStats
    func fetchSessionSettings() async throws -> TransmissionSessionSettings
    func setSessionSettings(_ patch: TransmissionSessionSettingsPatch) async throws
    func fetchTorrents() async throws -> [TorrentSummary]
    func fetchTorrentDetails(hashString: String) async throws -> TorrentDetails
    func addMagnet(_ magnet: String, downloadDirectory: String?) async throws
    func addTorrentFile(
        data: Data,
        downloadDirectory: String?,
        fileSelection: TorrentAddFileSelection?
    ) async throws
    func start(ids: [String]) async throws
    func stop(ids: [String]) async throws
    func remove(ids: [String], deleteLocalData: Bool) async throws
    func verify(ids: [String]) async throws
    func reannounce(ids: [String]) async throws
    func queueMoveTop(ids: [String]) async throws
    func queueMoveUp(ids: [String]) async throws
    func queueMoveDown(ids: [String]) async throws
    func queueMoveBottom(ids: [String]) async throws
    func renamePath(id: String, path: String, name: String) async throws
    func setFileWanted(ids: [String], fileIndices: [Int], wanted: Bool) async throws
    func setFilePriority(ids: [String], fileIndices: [Int], priority: Int) async throws
    func setTorrentPriority(ids: [String], priority: Int) async throws
}

extension TransmissionRPCClient: TransmissionRPCServicing {}

@MainActor
public final class RemoteAppModel: ObservableObject {
    public static let autoRefreshInterval: Duration = .seconds(5)

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
    @Published public var selectedTorrentGroup: TorrentGroup = .all
    @Published public private(set) var preferences = GlassRemotePreferences()
    @Published public private(set) var downloadDirectoryHistory: [UUID: [String]] = [:]
    @Published public private(set) var serverFreeSpace: [UUID: ServerFreeSpace] = [:]
    @Published public var errorMessage: String?

    private let profileStore: ProfileStore
    private let credentialStore: CredentialStore
    private let torrentSourceFileDisposer: TorrentSourceFileDisposing
    private let rpcClientFactory: @Sendable (TransmissionRPCConfig) -> any TransmissionRPCServicing
    private var torrentCache: [UUID: CachedTorrentList] = [:]
    private var clientsByProfileID: [UUID: any TransmissionRPCServicing] = [:]
    private var refreshTasksByProfileID: [UUID: Task<Void, Never>] = [:]
    private var displayedTorrentProfileID: UUID?
    private var selectedDetailsTorrentHash: String?

    public init(
        profileStore: ProfileStore,
        credentialStore: CredentialStore,
        torrentSourceFileDisposer: TorrentSourceFileDisposing = SystemTorrentSourceFileDisposer(),
        rpcClientFactory: @escaping @Sendable (TransmissionRPCConfig) -> any TransmissionRPCServicing = {
            TransmissionRPCClient(config: $0)
        }
    ) {
        self.profileStore = profileStore
        self.credentialStore = credentialStore
        self.torrentSourceFileDisposer = torrentSourceFileDisposer
        self.rpcClientFactory = rpcClientFactory
        loadProfiles()
    }

    public var localSourceName: String {
        Self.localDeviceName()
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

    public var isLocalSourceSelected: Bool {
        selectedProfileID == Self.localProfileID || selectedProfileID == nil
    }

    public func canAddToRemote(using destination: TorrentAddDestination) -> Bool {
        switch destination {
        case .selectedSource:
            return selectedSourceProfile != nil
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
        invalidateClient(for: profile.id)
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
        invalidateClient(for: profile.id)
        cancelRefresh(for: profile.id)
        profiles.removeAll { $0.id == profile.id }
        try? credentialStore.deletePassword(for: profile.id)
        if selectedProfileID == profile.id {
            selectedProfileID = Self.defaultSelectedProfileID(from: profiles)
            torrents = []
            stats = nil
            serverFreeSpace[profile.id] = nil
            displayedTorrentProfileID = nil
            clearTorrentDetails()
            isShowingCachedTorrents = false
            isSessionStale = false
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
        guard let profile = selectedSourceProfile else {
            torrents = []
            stats = nil
            serverFreeSpace = [:]
            displayedTorrentProfileID = nil
            errorMessage = nil
            clearTorrentDetails()
            isShowingCachedTorrents = false
            isSessionStale = false
            loadingProfileID = nil
            return
        }

        if let existingTask = refreshTasksByProfileID[profile.id] {
            await existingTask.value
            return
        }

        let task = Task { @MainActor in
            await self.performRefresh(profile: profile)
        }
        refreshTasksByProfileID[profile.id] = task
        await task.value
        refreshTasksByProfileID[profile.id] = nil
    }

    private func performRefresh(profile: RemoteProfile) async {
        guard selectedProfileID == profile.id else { return }

        prepareVisibleTorrentsForRefresh(of: profile)
        isLoading = true
        loadingProfileID = profile.id
        errorMessage = nil
        defer {
            isLoading = false
            loadingProfileID = nil
        }

        do {
            let client = try client(for: profile)
            async let fetchedStats = client.fetchSessionStats()
            async let fetchedTorrents = client.fetchTorrents()
            async let fetchedFreeSpace = defaultFreeSpace(using: client)
            let (freshStats, freshTorrents, freshFreeSpace) = try await (fetchedStats, fetchedTorrents, fetchedFreeSpace)
            guard selectedProfileID == profile.id else { return }
            let mergedTorrents = TorrentListMerger.merge(existing: torrents, incoming: freshTorrents)
            self.stats = freshStats
            self.torrents = mergedTorrents
            self.serverFreeSpace[profile.id] = freshFreeSpace
            self.displayedTorrentProfileID = profile.id
            self.isShowingCachedTorrents = false
            self.isSessionStale = false
            updateTorrentCache(mergedTorrents, for: profile.id)
        } catch {
            guard selectedProfileID == profile.id else { return }
            self.isSessionStale = !self.torrents.isEmpty
            errorMessage = error.localizedDescription
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
        guard let profile = selectedSourceProfile else { return false }
        rememberDownloadDirectory(downloadDirectory, for: profile.id)
        return await performRemoteAction(profile: profile) { client in
            try await client.addMagnet(magnet, downloadDirectory: downloadDirectory)
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
        guard let profile = selectedSourceProfile else { return false }
        rememberDownloadDirectory(downloadDirectory, for: profile.id)
        let didAdd = await performRemoteAction(profile: profile) { client in
            try await client.addTorrentFile(data: data, downloadDirectory: downloadDirectory, fileSelection: fileSelection)
        }
        if didAdd, trashSourceOnSuccess {
            torrentSourceFileDisposer.trashTorrentFileIfNeeded(sourceURL)
        }
        return didAdd
    }

    public func downloadDirectoriesForSelectedProfile() -> [String] {
        guard let profile = selectedSourceProfile else { return [] }
        return downloadDirectoryHistory[profile.id] ?? []
    }

    public func defaultDownloadDirectoryForSelectedProfile() async -> String? {
        guard let profile = selectedSourceProfile else { return nil }
        do {
            let client = try client(for: profile)
            return try await client.fetchDefaultDownloadDirectory()
        } catch {
            return nil
        }
    }

    public func fetchSessionSettingsForSelectedProfile() async -> TransmissionSessionSettings? {
        guard let profile = selectedSourceProfile else { return nil }
        do {
            let client = try client(for: profile)
            let settings = try await client.fetchSessionSettings()
            errorMessage = nil
            return settings
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    public func setSessionSettingsForSelectedProfile(_ patch: TransmissionSessionSettingsPatch) async -> Bool {
        guard let profile = selectedSourceProfile else { return false }
        return await performRemoteAction(profile: profile) { client in
            try await client.setSessionSettings(patch)
        }
    }

    public func loadDetails(for torrent: TorrentSummary?, force: Bool = false) async {
        guard let torrent, let profile = selectedSourceProfile else {
            clearTorrentDetails()
            return
        }

        if !force, selectedDetailsTorrentHash == torrent.hashString, selectedTorrentDetails != nil {
            return
        }

        selectedDetailsTorrentHash = torrent.hashString
        isLoadingTorrentDetails = true
        torrentDetailsError = nil
        defer { isLoadingTorrentDetails = false }

        do {
            let client = try client(for: profile)
            let details = try await client.fetchTorrentDetails(hashString: torrent.hashString)
            guard selectedProfileID == profile.id, selectedDetailsTorrentHash == torrent.hashString else { return }
            selectedTorrentDetails = details
        } catch {
            guard selectedProfileID == profile.id, selectedDetailsTorrentHash == torrent.hashString else { return }
            torrentDetailsError = error.localizedDescription
        }
    }

    public func setFileWanted(_ torrent: TorrentSummary, fileIndices: [Int], wanted: Bool) async {
        guard let profile = selectedSourceProfile, !fileIndices.isEmpty else { return }
        await performRemoteAction(profile: profile) { client in
            try await client.setFileWanted(ids: [torrent.hashString], fileIndices: fileIndices, wanted: wanted)
        }
        await loadDetails(for: torrent, force: true)
    }

    public func setFilePriority(_ torrent: TorrentSummary, fileIndices: [Int], priority: Int) async {
        guard let profile = selectedSourceProfile, !fileIndices.isEmpty else { return }
        await performRemoteAction(profile: profile) { client in
            try await client.setFilePriority(ids: [torrent.hashString], fileIndices: fileIndices, priority: priority)
        }
        await loadDetails(for: torrent, force: true)
    }

    public func setTorrentPriority(_ torrent: TorrentSummary, priority: Int) async {
        guard let profile = selectedSourceProfile else { return }
        await performRemoteAction(profile: profile) { client in
            try await client.setTorrentPriority(ids: [torrent.hashString], priority: priority)
        }
        await loadDetails(for: torrent, force: true)
    }

    public func start(_ torrent: TorrentSummary) async {
        guard let profile = selectedSourceProfile else { return }
        await performRemoteAction(profile: profile) { client in
            try await client.start(ids: [torrent.hashString])
        }
    }

    public func stop(_ torrent: TorrentSummary) async {
        guard let profile = selectedSourceProfile else { return }
        await performRemoteAction(profile: profile) { client in
            try await client.stop(ids: [torrent.hashString])
        }
    }

    public func remove(_ torrent: TorrentSummary, deleteData: Bool) async {
        await remove([torrent], deleteData: deleteData)
    }

    public func remove(_ torrents: [TorrentSummary], deleteData: Bool) async {
        guard let profile = selectedSourceProfile else { return }
        let ids = torrents.map(\.hashString)
        guard !ids.isEmpty else { return }
        await performRemoteAction(profile: profile) { client in
            try await client.remove(ids: ids, deleteLocalData: deleteData)
        }
        if let selectedDetailsTorrentHash, ids.contains(selectedDetailsTorrentHash) {
            clearTorrentDetails()
        }
    }

    public func verify(_ torrent: TorrentSummary) async {
        guard let profile = selectedSourceProfile else { return }
        await performRemoteAction(profile: profile) { client in
            try await client.verify(ids: [torrent.hashString])
        }
    }

    public func reannounce(_ torrent: TorrentSummary) async {
        guard let profile = selectedSourceProfile else { return }
        await performRemoteAction(profile: profile) { client in
            try await client.reannounce(ids: [torrent.hashString])
        }
    }

    public func moveInQueue(_ torrents: [TorrentSummary], direction: TorrentQueueMove) async {
        guard let profile = selectedSourceProfile else { return }
        let ids = torrents.map(\.hashString)
        guard !ids.isEmpty else { return }
        await performRemoteAction(profile: profile) { client in
            switch direction {
            case .top:
                try await client.queueMoveTop(ids: ids)
            case .up:
                try await client.queueMoveUp(ids: ids)
            case .down:
                try await client.queueMoveDown(ids: ids)
            case .bottom:
                try await client.queueMoveBottom(ids: ids)
            }
        }
    }

    public func rename(_ torrent: TorrentSummary, to name: String) async {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let profile = selectedSourceProfile, !trimmedName.isEmpty else { return }
        await performRemoteAction(profile: profile) { client in
            try await client.renamePath(id: torrent.hashString, path: torrent.name, name: trimmedName)
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

    private func client(for profile: RemoteProfile) throws -> any TransmissionRPCServicing {
        if let client = clientsByProfileID[profile.id] {
            return client
        }
        let password = profile.id == Self.localProfileID ? "" : try credentialStore.password(for: profile.id)
        let client = rpcClientFactory(TransmissionRPCConfig(profile: profile, password: password))
        clientsByProfileID[profile.id] = client
        return client
    }

    private func invalidateClient(for profileID: UUID) {
        clientsByProfileID[profileID] = nil
    }

    private func cancelRefresh(for profileID: UUID) {
        refreshTasksByProfileID[profileID]?.cancel()
        refreshTasksByProfileID[profileID] = nil
    }

    private func defaultFreeSpace(using client: any TransmissionRPCServicing) async -> ServerFreeSpace? {
        try? await client.fetchDefaultFreeSpace()
    }

    @discardableResult
    private func performRemoteAction(
        profile: RemoteProfile,
        action: (any TransmissionRPCServicing) async throws -> Void
    ) async -> Bool {
        isLoading = true
        loadingProfileID = profile.id
        errorMessage = nil
        defer {
            isLoading = false
            loadingProfileID = nil
        }

        do {
            let client = try client(for: profile)
            try await action(client)
            await refresh()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func prepareVisibleTorrentsForRefresh(of profile: RemoteProfile) {
        if displayedTorrentProfileID == profile.id, !torrents.isEmpty {
            isShowingCachedTorrents = true
            return
        }

        guard preferences.isTorrentCachingEnabled, let cached = torrentCache[profile.id] else {
            torrents = []
            displayedTorrentProfileID = nil
            isShowingCachedTorrents = false
            isSessionStale = false
            return
        }
        torrents = cached.torrents
        displayedTorrentProfileID = profile.id
        isShowingCachedTorrents = true
    }

    private func updateTorrentCache(_ torrents: [TorrentSummary], for profileID: UUID) {
        guard preferences.isTorrentCachingEnabled else { return }
        torrentCache[profileID] = CachedTorrentList(profileID: profileID, torrents: torrents)
        trimTorrentCache()
        persistTorrentCache()
    }

    private func trimTorrentCache() {
        let allowedProfileIDs = Set(profiles.map(\.id))
        torrentCache = torrentCache.filter { allowedProfileIDs.contains($0.key) }

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
        let allowedProfileIDs = Set(profiles.map(\.id))
        downloadDirectoryHistory = downloadDirectoryHistory.filter { allowedProfileIDs.contains($0.key) }
    }

    private static func localDeviceName() -> String {
        #if os(macOS)
        return Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        #elseif os(iOS)
        return UIDevice.current.name
        #else
        return "This Device"
        #endif
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
