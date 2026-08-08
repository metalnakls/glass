import Foundation
import GlassRemoteCore
import Observation
@testable import GlassRemoteServices
import Testing

@MainActor
@Suite("Remote app model")
struct RemoteAppModelTests {
    @Test("reuses pooled client per profile")
    func reusesPooledClientPerProfile() async throws {
        let profile = makeProfile()
        let factory = StubRPCClientFactory()
        let model = makeModel(profile: profile, factory: factory)

        await model.refresh()
        await model.refresh()

        #expect(factory.createdCount == 1)
        let client = try #require(factory.clients.first)
        #expect(await client.fetchTorrentsCount == 2)
        #expect(await client.fetchSessionStatsCount == 1)
        #expect(await client.fetchFreeSpaceCount == 1)
    }

    @Test("saving profile invalidates pooled client")
    func savingProfileInvalidatesPooledClient() async throws {
        let profile = makeProfile()
        let factory = StubRPCClientFactory()
        let model = makeModel(profile: profile, factory: factory)

        await model.refresh()
        model.saveProfile(profile, password: "new")
        await model.refresh()

        #expect(factory.createdCount == 2)
    }

    @Test("deleting profile invalidates client and clears remote state")
    func deletingProfileInvalidatesClient() async throws {
        let profile = makeProfile()
        let factory = StubRPCClientFactory()
        let model = makeModel(profile: profile, factory: factory)

        await model.refresh()
        #expect(model.torrents.isEmpty == false)

        model.deleteProfile(profile)

        #expect(model.selectedSourceProfile == nil)
        #expect(model.torrents.isEmpty)
        #expect(model.stats == nil)
    }

    @Test("concurrent refreshes coalesce into one trailing refresh")
    func concurrentRefreshesCoalesceWithTrailingRefresh() async throws {
        let profile = makeProfile()
        let factory = StubRPCClientFactory { _ in
            StubRPCClient(fetchDelay: .milliseconds(120))
        }
        let model = makeModel(profile: profile, factory: factory)

        async let first: Void = model.refresh()
        async let second: Void = model.refresh()
        async let third: Void = model.refresh()
        _ = await (first, second, third)

        #expect(factory.createdCount == 1)
        let client = try #require(factory.clients.first)
        #expect(await client.fetchTorrentsCount == 2)
    }

    @Test("command bursts debounce into one refresh")
    func commandBurstsDebounceRefresh() async throws {
        let profile = makeProfile()
        let factory = StubRPCClientFactory()
        let model = makeModel(profile: profile, factory: factory)
        await model.refresh()
        let torrent = try #require(model.torrents.first)
        let client = try #require(factory.clients.first)

        await model.start(torrent)
        await model.stop(torrent)
        try await Task.sleep(for: .milliseconds(300))

        #expect(await client.fetchTorrentsCount == 2)
    }

    @Test("polling backs off while inactive")
    func pollingBacksOffWhileInactive() async {
        let profile = makeProfile()
        let model = makeModel(profile: profile, factory: StubRPCClientFactory())
        await model.refresh()

        #expect(model.currentAutoRefreshInterval == RemoteAppModel.activeAutoRefreshInterval)
        model.setApplicationActive(false)
        #expect(model.currentAutoRefreshInterval == RemoteAppModel.quietAutoRefreshInterval)
    }

    @Test("loads only visible torrent detail sections")
    func loadsOnlyVisibleTorrentDetailSections() async throws {
        let profile = makeProfile()
        let factory = StubRPCClientFactory()
        let model = makeModel(profile: profile, factory: factory)
        await model.refresh()
        let torrent = try #require(model.torrents.first)
        let client = try #require(factory.clients.first)

        await model.loadDetails(for: torrent)
        model.setVisibleTorrentDetailSections([.files], forHashString: torrent.hashString)
        await model.loadDetailSection(.files, forHashString: torrent.hashString)

        #expect(await client.fetchTorrentDetailsCount == 1)
        #expect(await client.fetchTorrentFilesCount == 1)
        #expect(await client.fetchTorrentPeersCount == 0)
        #expect(model.selectedTorrentDetails?.files.first?.name == "Episode.mkv")
    }

    @Test("refresh updates selected inspector details and visible sections")
    func refreshUpdatesSelectedInspectorDetails() async throws {
        let profile = makeProfile()
        let factory = StubRPCClientFactory()
        let model = makeModel(profile: profile, factory: factory)
        await model.refresh()
        let torrent = try #require(model.torrents.first)
        let client = try #require(factory.clients.first)

        await model.loadDetails(for: torrent)
        model.setVisibleTorrentDetailSections([.files], forHashString: torrent.hashString)
        await model.loadDetailSection(.files, forHashString: torrent.hashString)
        await client.setInspectorProgress(percentDone: 0.75, fileBytesCompleted: 75)

        await model.refresh()

        #expect(model.selectedTorrentDetails?.percentDone == 0.75)
        #expect(model.selectedTorrentDetails?.files.first?.bytesCompleted == 75)
        #expect(model.loadingTorrentDetailSections.isEmpty)
        #expect(await client.fetchTorrentPeersCount == 0)
    }

    @Test("changing selection cancels obsolete detail work")
    func changingSelectionCancelsDetails() async throws {
        let profile = makeProfile()
        let client = StubRPCClient(detailDelay: .milliseconds(120))
        let factory = StubRPCClientFactory { _ in client }
        let model = makeModel(profile: profile, factory: factory)
        await model.refresh()
        let firstTorrent = try #require(model.torrents.first)
        let secondTorrent = TorrentSummary(
            id: 2,
            hashString: "hash-2",
            name: "Second",
            status: TransmissionTorrentStatus.downloading.rawValue,
            percentDone: 0.25,
            rateDownload: 1,
            rateUpload: 0,
            sizeWhenDone: 100,
            leftUntilDone: 75,
            eta: 60,
            uploadRatio: 0,
            peersConnected: 1,
            downloadDir: "/downloads"
        )

        async let firstLoad: Void = model.loadDetails(for: firstTorrent)
        try await Task.sleep(for: .milliseconds(20))
        await model.loadDetails(for: secondTorrent)
        _ = await firstLoad

        #expect(await client.cancelledTorrentDetailsCount == 1)
        #expect(model.selectedTorrentDetails?.hashString == "hash-2")
    }

    @Test("torrent refresh does not invalidate sidebar-facing observation")
    func torrentRefreshDoesNotInvalidateSidebarObservation() async {
        let profile = makeProfile()
        let factory = StubRPCClientFactory()
        let model = makeModel(profile: profile, factory: factory)
        let invalidated = LockedFlag()

        withObservationTracking {
            _ = model.profiles
            _ = model.selectedProfileID
        } onChange: {
            invalidated.set()
        }

        await model.refresh()

        #expect(invalidated.value == false)
    }

    @Test("identical refresh does not republish torrents")
    func identicalRefreshDoesNotRepublishTorrents() async {
        let profile = makeProfile()
        let factory = StubRPCClientFactory()
        let model = makeModel(profile: profile, factory: factory)
        await model.refresh()
        let invalidated = LockedFlag()

        withObservationTracking {
            _ = model.torrents
        } onChange: {
            invalidated.set()
        }

        await model.refresh()

        #expect(invalidated.value == false)
    }

    @Test("telemetry refresh mutates one stable torrent record without republishing structure")
    func telemetryRefreshKeepsStableRecord() async throws {
        let profile = makeProfile()
        let factory = StubRPCClientFactory()
        let model = makeModel(profile: profile, factory: factory)
        await model.refresh()
        let client = try #require(factory.clients.first)
        let originalRecord = try #require(model.torrentRecords.first)
        let originalRevision = model.torrentStructureRevision
        let structureInvalidated = LockedFlag()

        withObservationTracking {
            _ = model.torrentRecords
            _ = model.torrentStructureRevision
        } onChange: {
            structureInvalidated.set()
        }

        await client.setTorrentRateDownload(4096)
        await model.refresh()

        let updatedRecord = try #require(model.torrentRecords.first)
        #expect(updatedRecord === originalRecord)
        #expect(updatedRecord.summary.rateDownload == 4096)
        #expect(model.torrentStructureRevision == originalRevision)
        #expect(structureInvalidated.value == false)
    }

    @Test("recently-active removal deletes the matching stable record")
    func recentlyActiveRemovalDeletesRecord() async throws {
        let profile = makeProfile()
        let factory = StubRPCClientFactory()
        let model = makeModel(profile: profile, factory: factory)
        await model.refresh()
        let client = try #require(factory.clients.first)

        await client.setRecentlyActiveUpdate(.delta(changed: [], removedIDs: [1]))
        await model.refresh()

        #expect(model.torrentRecords.isEmpty)
        #expect(model.torrents.isEmpty)
    }

    @Test("refresh defers torrent cache persistence")
    func refreshDefersTorrentCachePersistence() async {
        let profile = makeProfile()
        let factory = StubRPCClientFactory()
        let store = MemoryProfileStore(profiles: [profile])
        let model = RemoteAppModel(
            profileStore: store,
            credentialStore: MemoryCredentialStore(password: "secret"),
            rpcClientFactory: factory.make(config:)
        )

        await model.refresh()

        #expect(store.torrentCacheSaveCount == 0)
    }

    @Test("rename accepts a confirmed change after an RPC error")
    func renameAcceptsConfirmedChangeAfterRPCError() async throws {
        let profile = makeProfile()
        let factory = StubRPCClientFactory()
        let model = makeModel(profile: profile, factory: factory)
        await model.refresh()
        let torrent = try #require(model.torrents.first)
        let client = try #require(factory.clients.first)
        await client.setRenameBehavior(error: TestError.failed, appliesBeforeThrow: true)

        let didRename = await model.rename(torrent, to: "Spider-Gwen")

        #expect(didRename)
        #expect(model.errorMessage == nil)
        #expect(model.torrents.first?.name == "Spider-Gwen")
    }

    @Test("refresh failures are inline state instead of alert errors")
    func refreshFailuresAreInlineStateInsteadOfAlertErrors() async throws {
        let profile = makeProfile()
        let failingClient = StubRPCClient()
        await failingClient.setFetchTorrentsError(TestError.failed)
        let factory = StubRPCClientFactory { _ in failingClient }
        let model = makeModel(profile: profile, factory: factory)

        await model.refresh()

        #expect(model.errorMessage == nil)
        #expect(model.refreshErrorMessage != nil)
        #expect(model.torrents.isEmpty)
    }

    @Test("trashes source torrent only after successful add")
    func trashesSourceTorrentOnlyAfterSuccessfulAdd() async throws {
        let profile = makeProfile()
        let sourceURL = URL(fileURLWithPath: "/tmp/source.torrent")
        let disposer = RecordingTorrentSourceFileDisposer()
        let failingClient = StubRPCClient()
        await failingClient.setAddTorrentError(TestError.failed)
        let factory = StubRPCClientFactory { _ in failingClient }
        let model = makeModel(profile: profile, factory: factory, disposer: disposer)

        let failed = await model.addTorrentFile(
            Data([0x01]),
            downloadDirectory: nil,
            sourceURL: sourceURL,
            trashSourceOnSuccess: true
        )
        #expect(failed == false)
        #expect(disposer.trashedURLs.isEmpty)

        let succeedingClient = StubRPCClient()
        factory.makeClient = { _ in succeedingClient }
        model.saveProfile(profile, password: "secret")

        let succeeded = await model.addTorrentFile(
            Data([0x02]),
            downloadDirectory: nil,
            sourceURL: sourceURL,
            trashSourceOnSuccess: true
        )
        #expect(succeeded)
        #expect(disposer.trashedURLs == [sourceURL])
    }

    @Test("local source refresh uses local session and not RPC")
    func localSourceRefreshUsesLocalSessionAndNotRPC() async throws {
        let factory = StubRPCClientFactory()
        let localSession = StubLocalTransmissionSession()
        let model = makeModel(profiles: [], factory: factory, localSession: localSession)

        await model.refresh()

        #expect(model.isLocalSourceSelected)
        #expect(model.torrents.isEmpty == false)
        #expect(factory.createdCount == 0)
        #expect(await localSession.fetchSnapshotCount == 1)
    }

    @Test("local source imports torrent files and trashes source after success")
    func localSourceImportsTorrentFilesAndTrashesSourceAfterSuccess() async throws {
        let sourceURL = URL(fileURLWithPath: "/tmp/local-source.torrent")
        let disposer = RecordingTorrentSourceFileDisposer()
        let factory = StubRPCClientFactory()
        let localSession = StubLocalTransmissionSession()
        let model = makeModel(profiles: [], factory: factory, disposer: disposer, localSession: localSession)

        let succeeded = await model.addTorrentFile(
            Data([0x03]),
            downloadDirectory: "/Users/me/Downloads",
            sourceURL: sourceURL,
            trashSourceOnSuccess: true
        )

        #expect(succeeded)
        #expect(disposer.trashedURLs == [sourceURL])
        #expect(model.downloadDirectoriesForSelectedProfile() == ["/Users/me/Downloads"])
        #expect(await localSession.addTorrentFileCount == 1)
        #expect(factory.createdCount == 0)
    }

    @Test("torrent file dialog can target a source other than the sidebar selection")
    func torrentFileCanTargetAnotherSource() async {
        let profile = makeProfile()
        let factory = StubRPCClientFactory()
        let localSession = StubLocalTransmissionSession()
        let model = makeModel(profiles: [profile], factory: factory, localSession: localSession)

        #expect(model.selectedSourceID == profile.id)

        let succeeded = await model.addTorrentFile(
            Data([0x04]),
            downloadDirectory: "/Users/me/Torrents",
            sourceID: model.localSourceID
        )
        model.setDownloadDirectory("/Users/me/Torrents", isFavorite: true, for: model.localSourceID)

        #expect(succeeded)
        #expect(await localSession.addTorrentFileCount == 1)
        #expect(factory.createdCount == 0)
        #expect(model.downloadDirectories(for: model.localSourceID) == ["/Users/me/Torrents"])
        #expect(model.favoriteDownloadDirectories(for: model.localSourceID) == ["/Users/me/Torrents"])
    }

    @Test("auto clean renames selected paths before the torrent root")
    func autoCleanRenamesChildrenBeforeRoot() async throws {
        let profile = makeProfile()
        let client = StubRPCClient()
        let factory = StubRPCClientFactory { _ in client }
        let model = makeModel(profile: profile, factory: factory)
        let child = TorrentPathRename(path: "Spider-Noir/Show.S02E20.mkv", name: "S02E20.mkv")

        let succeeded = await model.addTorrentFile(
            Data([0x05]),
            downloadDirectory: nil,
            namingPlan: TorrentAddNamingPlan(rootName: "Spider Noir", pathRenames: [child])
        )

        #expect(succeeded)
        #expect(await client.renamedPaths == [
            child,
            TorrentPathRename(path: "Spider-Noir", name: "Spider Noir")
        ])
    }
}

@MainActor
private func makeModel(
    profile: RemoteProfile,
    factory: StubRPCClientFactory,
    disposer: RecordingTorrentSourceFileDisposer = RecordingTorrentSourceFileDisposer()
) -> RemoteAppModel {
    RemoteAppModel(
        profileStore: MemoryProfileStore(profiles: [profile]),
        credentialStore: MemoryCredentialStore(password: "secret"),
        torrentSourceFileDisposer: disposer,
        rpcClientFactory: factory.make(config:)
    )
}

@MainActor
private func makeModel(
    profiles: [RemoteProfile],
    factory: StubRPCClientFactory,
    disposer: RecordingTorrentSourceFileDisposer = RecordingTorrentSourceFileDisposer(),
    localSession: StubLocalTransmissionSession = StubLocalTransmissionSession()
) -> RemoteAppModel {
    RemoteAppModel(
        profileStore: MemoryProfileStore(profiles: profiles),
        credentialStore: MemoryCredentialStore(password: "secret"),
        torrentSourceFileDisposer: disposer,
        rpcClientFactory: factory.make(config:),
        localSessionFactory: { localSession }
    )
}

private func makeProfile() -> RemoteProfile {
    RemoteProfile(
        id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
        name: "Ultra",
        rpcURL: URL(string: "http://192.168.1.1:9091/transmission/rpc")!,
        username: "admin"
    )
}

private enum TestError: Error {
    case failed
}

private final class StubRPCClientFactory: @unchecked Sendable {
    private let lock = NSLock()
    var makeClient: @Sendable (TransmissionRPCConfig) -> StubRPCClient
    private(set) var clients: [StubRPCClient] = []
    private(set) var configs: [TransmissionRPCConfig] = []

    init(makeClient: @escaping @Sendable (TransmissionRPCConfig) -> StubRPCClient = { _ in StubRPCClient() }) {
        self.makeClient = makeClient
    }

    var createdCount: Int {
        lock.withLock { clients.count }
    }

    func make(config: TransmissionRPCConfig) -> any TransmissionRPCServicing {
        let client = makeClient(config)
        lock.withLock {
            configs.append(config)
            clients.append(client)
        }
        return client
    }
}

private actor StubRPCClient: TransmissionRPCServicing {
    private let fetchDelay: Duration?
    private let detailDelay: Duration?
    private var fetchTorrentsError: (any Error)?
    private var addTorrentError: (any Error)?
    private var renameError: (any Error)?
    private var renameAppliesBeforeThrow = false
    private var torrentName = "Spider-Noir"
    private var torrentRateDownload: Double = 1024
    private var inspectorPercentDone = 0.5
    private var inspectorFileBytesCompleted: UInt64 = 50
    private var recentlyActiveUpdate: TorrentCollectionUpdate?
    private(set) var fetchTorrentsCount = 0
    private(set) var fetchSessionStatsCount = 0
    private(set) var fetchFreeSpaceCount = 0
    private(set) var fetchTorrentDetailsCount = 0
    private(set) var fetchTorrentFilesCount = 0
    private(set) var fetchTorrentPeersCount = 0
    private(set) var cancelledTorrentDetailsCount = 0
    private(set) var renamedPaths: [TorrentPathRename] = []

    init(fetchDelay: Duration? = nil, detailDelay: Duration? = nil) {
        self.fetchDelay = fetchDelay
        self.detailDelay = detailDelay
    }

    func setAddTorrentError(_ error: (any Error)?) {
        addTorrentError = error
    }

    func setFetchTorrentsError(_ error: (any Error)?) {
        fetchTorrentsError = error
    }

    func setRenameBehavior(error: (any Error)?, appliesBeforeThrow: Bool) {
        renameError = error
        renameAppliesBeforeThrow = appliesBeforeThrow
    }

    func setTorrentRateDownload(_ rate: Double) {
        torrentRateDownload = rate
    }

    func setInspectorProgress(percentDone: Double, fileBytesCompleted: UInt64) {
        inspectorPercentDone = percentDone
        inspectorFileBytesCompleted = fileBytesCompleted
    }

    func setRecentlyActiveUpdate(_ update: TorrentCollectionUpdate?) {
        recentlyActiveUpdate = update
    }

    func testConnection() async throws {}

    func fetchDefaultDownloadDirectory() async throws -> String? {
        "/downloads"
    }

    func fetchDefaultFreeSpace() async throws -> ServerFreeSpace? {
        fetchFreeSpaceCount += 1
        return ServerFreeSpace(path: "/downloads", sizeBytes: 1024)
    }

    func fetchSessionStats() async throws -> SessionStats {
        fetchSessionStatsCount += 1
        return try JSONDecoder().decode(
            SessionStats.self,
            from: #"{"downloadSpeed":1,"uploadSpeed":2}"#.data(using: .utf8)!
        )
    }

    func fetchSessionSettings() async throws -> TransmissionSessionSettings {
        try JSONDecoder().decode(
            TransmissionSessionSettings.self,
            from: #"{"version":"test"}"#.data(using: .utf8)!
        )
    }

    func setSessionSettings(_ patch: TransmissionSessionSettingsPatch) async throws {}

    func fetchTorrents() async throws -> [TorrentSummary] {
        fetchTorrentsCount += 1
        if let fetchDelay {
            try await Task.sleep(for: fetchDelay)
        }
        if let fetchTorrentsError {
            throw fetchTorrentsError
        }
        return [
            TorrentSummary(
                id: 1,
                hashString: "hash-1",
                name: torrentName,
                status: TransmissionTorrentStatus.downloading.rawValue,
                percentDone: 0.5,
                rateDownload: torrentRateDownload,
                rateUpload: 0,
                sizeWhenDone: 100,
                leftUntilDone: 50,
                eta: 60,
                uploadRatio: 0,
                peersConnected: 1,
                downloadDir: "/downloads",
                queuePosition: 0
            )
        ]
    }

    func fetchRecentlyActiveTorrents() async throws -> TorrentCollectionUpdate {
        if let recentlyActiveUpdate {
            return recentlyActiveUpdate
        }
        return .full(try await fetchTorrents())
    }

    func fetchTorrentDetails(hashString: String) async throws -> TorrentDetails {
        fetchTorrentDetailsCount += 1
        if let detailDelay {
            do {
                try await Task.sleep(for: detailDelay)
            } catch {
                cancelledTorrentDetailsCount += 1
                throw error
            }
        }
        return TorrentDetails(
            id: 1,
            hashString: hashString,
            name: "Spider-Noir",
            percentDone: inspectorPercentDone
        )
    }

    func fetchTorrentFiles(hashString: String) async throws -> TorrentDetails {
        fetchTorrentFilesCount += 1
        return TorrentDetails(
            id: 1,
            hashString: hashString,
            name: "Spider-Noir",
            files: [
                TorrentFile(
                    name: "Episode.mkv",
                    length: 100,
                    bytesCompleted: inspectorFileBytesCompleted
                )
            ]
        )
    }

    func fetchTorrentPeers(hashString: String) async throws -> TorrentDetails {
        fetchTorrentPeersCount += 1
        return TorrentDetails(id: 1, hashString: hashString, name: "Spider-Noir")
    }

    func addMagnet(_ magnet: String, downloadDirectory: String?) async throws {}

    func addTorrentFile(
        data: Data,
        torrentName: String?,
        downloadDirectory: String?,
        fileSelection: TorrentAddFileSelection?
    ) async throws -> TorrentAddResult? {
        if let addTorrentError {
            throw addTorrentError
        }
        return TorrentAddResult(hashString: "hash-1", name: torrentName ?? self.torrentName, wasDuplicate: false)
    }

    func start(ids: [String]) async throws {}
    func stop(ids: [String]) async throws {}
    func remove(ids: [String], deleteLocalData: Bool) async throws {}
    func verify(ids: [String]) async throws {}
    func reannounce(ids: [String]) async throws {}
    func queueMoveTop(ids: [String]) async throws {}
    func queueMoveUp(ids: [String]) async throws {}
    func queueMoveDown(ids: [String]) async throws {}
    func queueMoveBottom(ids: [String]) async throws {}
    func renamePath(id: String, path: String, name: String) async throws {
        renamedPaths.append(TorrentPathRename(path: path, name: name))
        if renameAppliesBeforeThrow {
            torrentName = name
        }
        if let renameError {
            throw renameError
        }
        torrentName = name
    }
    func setFileWanted(ids: [String], fileIndices: [Int], wanted: Bool) async throws {}
    func setFilePriority(ids: [String], fileIndices: [Int], priority: Int) async throws {}
    func setTorrentPriority(ids: [String], priority: Int) async throws {}
}

private actor StubLocalTransmissionSession: LocalTransmissionServicing {
    private(set) var fetchSnapshotCount = 0
    private(set) var addTorrentFileCount = 0

    func fetchSnapshot() async throws -> TorrentProviderSnapshot {
        fetchSnapshotCount += 1
        return TorrentProviderSnapshot(
            stats: try JSONDecoder().decode(
                SessionStats.self,
                from: #"{"downloadSpeed":1,"uploadSpeed":2}"#.data(using: .utf8)!
            ),
            torrents: [makeLocalTorrent()],
            freeSpace: ServerFreeSpace(path: "/Users/me/Downloads", sizeBytes: 1024)
        )
    }

    func fetchDefaultDownloadDirectory() async throws -> String? {
        "/Users/me/Downloads"
    }

    func fetchSessionSettings() async throws -> TransmissionSessionSettings {
        try JSONDecoder().decode(
            TransmissionSessionSettings.self,
            from: #"{"version":"local-test","download-dir":"/Users/me/Downloads"}"#.data(using: .utf8)!
        )
    }

    func setSessionSettings(_ patch: TransmissionSessionSettingsPatch) async throws {}

    func fetchTorrentDetails(hashString: String) async throws -> TorrentDetails {
        TorrentDetails(id: 7, hashString: hashString, name: "Local")
    }

    func addMagnet(_ magnet: String, downloadDirectory: String?) async throws {}

    func addTorrentFile(
        data: Data,
        torrentName: String?,
        downloadDirectory: String?,
        fileSelection: TorrentAddFileSelection?
    ) async throws -> TorrentAddResult? {
        addTorrentFileCount += 1
        return TorrentAddResult(hashString: "local-hash", name: torrentName ?? "Local", wasDuplicate: false)
    }

    func start(ids: [String]) async throws {}
    func stop(ids: [String]) async throws {}
    func remove(ids: [String], deleteLocalData: Bool) async throws {}
    func verify(ids: [String]) async throws {}
    func reannounce(ids: [String]) async throws {}
    func queueMoveTop(ids: [String]) async throws {}
    func queueMoveUp(ids: [String]) async throws {}
    func queueMoveDown(ids: [String]) async throws {}
    func queueMoveBottom(ids: [String]) async throws {}
    func renamePath(id: String, path: String, name: String) async throws {}
    func setFileWanted(ids: [String], fileIndices: [Int], wanted: Bool) async throws {}
    func setFilePriority(ids: [String], fileIndices: [Int], priority: Int) async throws {}
    func setTorrentPriority(ids: [String], priority: Int) async throws {}

    private func makeLocalTorrent() -> TorrentSummary {
        TorrentSummary(
            id: 7,
            hashString: "local-hash",
            name: "Local",
            status: TransmissionTorrentStatus.downloading.rawValue,
            percentDone: 0.1,
            rateDownload: 3,
            rateUpload: 4,
            sizeWhenDone: 100,
            leftUntilDone: 90,
            eta: 60,
            uploadRatio: 0,
            peersConnected: 2,
            downloadDir: "/Users/me/Downloads",
            queuePosition: 0
        )
    }
}

private final class MemoryProfileStore: ProfileStore, @unchecked Sendable {
    private let lock = NSLock()
    private var profiles: [RemoteProfile]
    private var preferences = GlassRemotePreferences()
    private var torrentCache: [CachedTorrentList] = []
    private var torrentCacheSaveCounter = 0
    private var history: [DownloadDirectoryHistory] = []

    init(profiles: [RemoteProfile]) {
        self.profiles = profiles
    }

    func loadProfiles() throws -> [RemoteProfile] {
        lock.withLock { profiles }
    }

    func saveProfiles(_ profiles: [RemoteProfile]) throws {
        lock.withLock {
            self.profiles = profiles
        }
    }

    func loadPreferences() throws -> GlassRemotePreferences {
        lock.withLock { preferences }
    }

    func savePreferences(_ preferences: GlassRemotePreferences) throws {
        lock.withLock {
            self.preferences = preferences
        }
    }

    func loadTorrentCache() throws -> [CachedTorrentList] {
        lock.withLock { torrentCache }
    }

    func saveTorrentCache(_ cache: [CachedTorrentList]) throws {
        lock.withLock {
            torrentCache = cache
            torrentCacheSaveCounter += 1
        }
    }

    var torrentCacheSaveCount: Int {
        lock.withLock { torrentCacheSaveCounter }
    }

    func loadDownloadDirectoryHistory() throws -> [DownloadDirectoryHistory] {
        lock.withLock { history }
    }

    func saveDownloadDirectoryHistory(_ history: [DownloadDirectoryHistory]) throws {
        lock.withLock {
            self.history = history
        }
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        lock.withLock { storage }
    }

    func set() {
        lock.withLock {
            storage = true
        }
    }
}

private final class MemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var password: String

    init(password: String) {
        self.password = password
    }

    func password(for profileID: UUID) throws -> String {
        lock.withLock { password }
    }

    func savePassword(_ password: String, for profileID: UUID) throws {
        lock.withLock {
            self.password = password
        }
    }

    func deletePassword(for profileID: UUID) throws {
        lock.withLock {
            password = ""
        }
    }
}

private final class RecordingTorrentSourceFileDisposer: TorrentSourceFileDisposing, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var trashedURLs: [URL] = []

    func trashTorrentFileIfNeeded(_ url: URL?) {
        guard let url else { return }
        lock.withLock {
            trashedURLs.append(url)
        }
    }
}
