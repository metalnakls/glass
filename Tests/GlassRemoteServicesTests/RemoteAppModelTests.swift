import Foundation
import GlassRemoteCore
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

    @Test("concurrent refreshes coalesce")
    func concurrentRefreshesCoalesce() async throws {
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
        #expect(await client.fetchTorrentsCount == 1)
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

    init(makeClient: @escaping @Sendable (TransmissionRPCConfig) -> StubRPCClient = { _ in StubRPCClient() }) {
        self.makeClient = makeClient
    }

    var createdCount: Int {
        lock.withLock { clients.count }
    }

    func make(config: TransmissionRPCConfig) -> any TransmissionRPCServicing {
        let client = makeClient(config)
        lock.withLock {
            clients.append(client)
        }
        return client
    }
}

private actor StubRPCClient: TransmissionRPCServicing {
    private let fetchDelay: Duration?
    private var addTorrentError: (any Error)?
    private(set) var fetchTorrentsCount = 0

    init(fetchDelay: Duration? = nil) {
        self.fetchDelay = fetchDelay
    }

    func setAddTorrentError(_ error: (any Error)?) {
        addTorrentError = error
    }

    func testConnection() async throws {}

    func fetchDefaultDownloadDirectory() async throws -> String? {
        "/downloads"
    }

    func fetchDefaultFreeSpace() async throws -> ServerFreeSpace? {
        ServerFreeSpace(path: "/downloads", sizeBytes: 1024)
    }

    func fetchSessionStats() async throws -> SessionStats {
        try JSONDecoder().decode(
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
        return [
            TorrentSummary(
                id: 1,
                hashString: "hash-1",
                name: "Spider-Noir",
                status: TransmissionTorrentStatus.downloading.rawValue,
                percentDone: 0.5,
                rateDownload: 1024,
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

    func fetchTorrentDetails(hashString: String) async throws -> TorrentDetails {
        TorrentDetails(id: 1, hashString: hashString, name: "Spider-Noir")
    }

    func addMagnet(_ magnet: String, downloadDirectory: String?) async throws {}

    func addTorrentFile(data: Data, downloadDirectory: String?, fileSelection: TorrentAddFileSelection?) async throws {
        if let addTorrentError {
            throw addTorrentError
        }
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
}

private final class MemoryProfileStore: ProfileStore, @unchecked Sendable {
    private let lock = NSLock()
    private var profiles: [RemoteProfile]
    private var preferences = GlassRemotePreferences()
    private var torrentCache: [CachedTorrentList] = []
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
        }
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
