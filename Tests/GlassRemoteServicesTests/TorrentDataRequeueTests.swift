import Foundation
import GlassRemoteCore
@testable import GlassRemoteServices
import Testing

@MainActor
struct TorrentDataRequeueTests {
    @Test(arguments: [false, true])
    func replacementPreservesChoicesAndNames(remote: Bool) async throws {
        let fixture = try Fixture(remote: remote)
        defer { fixture.clean() }
        await fixture.model.refresh(sourceID: fixture.sourceID)
        let summary = await fixture.client.summary()
        #expect(await fixture.model.deleteDataAndQueue([summary], sourceID: fixture.sourceID))
        let details = try await fixture.client.fetchTorrentDetails(hashString: summary.hashString)
        #expect(details.files.map(\.name) == ["Nice/B.mkv", "Nice/A.mkv"])
        #expect(details.fileStats.map(\.wanted) == [true, false])
        #expect(details.fileStats.map(\.priority) == [1, -1])
        #expect(details.status == 0)
        #expect(details.percentDone == 0)
        #expect(fixture.model.allTorrentRecords.first?.summary.percentDone == 0)
        #expect(details.downloadDir == "/downloads/existing")
        #expect(await fixture.client.deleteCount == 1)
        #expect(await fixture.client.startCount == 0)
        #expect(await fixture.client.restoredPriority == 1)
        #expect(await fixture.client.restoredPosition == 4)
        #expect(try fixture.store.loadTorrentAddQueue().isEmpty)
    }

    @Test func failedAddSurvivesRelaunchWithoutSecondDelete() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        await fixture.client.setFailure(.add)
        #expect(!(await fixture.model.deleteDataAndQueue([await fixture.client.summary()], sourceID: fixture.sourceID)))
        let saved = try #require(fixture.store.loadTorrentAddQueue().first)
        #expect(saved.data == RequeueClient.metainfo)
        #expect(saved.dataRequeue?.removalStage == .removed)
        #expect(saved.startPaused == true)
        await fixture.client.setFailure(nil)
        let recovered = fixture.makeModel()
        #expect(await recovered.retryTorrentAddition(saved.id))
        #expect(await fixture.client.deleteCount == 1)
        #expect(await fixture.client.startCount == 0)
        #expect(try fixture.store.loadTorrentAddQueue().isEmpty)
    }

    @Test(arguments: [RequeueClient.Failure.lostDeleteReply, .deleteRejected])
    fileprivate func uncertainDeleteIsNeverRepeated(failure: RequeueClient.Failure) async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        await fixture.client.setFailure(failure)
        #expect(!(await fixture.model.deleteDataAndQueue([await fixture.client.summary()], sourceID: fixture.sourceID)))
        let saved = try #require(fixture.store.loadTorrentAddQueue().first)
        #expect(saved.dataRequeue?.removalStage == .removing)
        await fixture.client.setFailure(nil)
        let recovered = fixture.makeModel()
        let result = await recovered.retryTorrentAddition(saved.id)
        #expect(result == (failure == .lostDeleteReply))
        #expect(await fixture.client.deleteCount == 1)
    }

    @Test func failedRemoteRequeueCannotChangeDestination() async throws {
        let fixture = try Fixture(remote: true)
        defer { fixture.clean() }
        await fixture.client.setFailure(.add)
        #expect(!(await fixture.model.deleteDataAndQueue([await fixture.client.summary()], sourceID: fixture.sourceID)))
        let saved = try #require(fixture.store.loadTorrentAddQueue().first)
        #expect(!fixture.model.canDownloadTorrentAdditionLocally(saved.id))
        #expect(!(await fixture.model.downloadTorrentAdditionLocally(saved.id)))
        #expect(try fixture.store.loadTorrentAddQueue().first?.sourceID == fixture.sourceID)
    }

    @Test func lostChoicesAreRestoredAfterReceiptRecovery() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        await fixture.client.setFailure(.choices)
        #expect(!(await fixture.model.deleteDataAndQueue([await fixture.client.summary()], sourceID: fixture.sourceID)))
        let saved = try #require(fixture.store.loadTorrentAddQueue().first)
        await fixture.client.setFailure(nil)
        let recovered = fixture.makeModel()
        #expect(await recovered.retryTorrentAddition(saved.id))
        let details = try await fixture.client.fetchTorrentDetails(hashString: RequeueClient.hash)
        #expect(details.fileStats.map(\.wanted) == [true, false])
        #expect(details.fileStats.map(\.priority) == [1, -1])
        #expect(await fixture.client.deleteCount == 1)
    }

    @Test func invalidMetadataNeverDeletes() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        await fixture.client.setFailure(.metadata)
        #expect(!(await fixture.model.deleteDataAndQueue([await fixture.client.summary()], sourceID: fixture.sourceID)))
        #expect(await fixture.client.deleteCount == 0)
        #expect(try fixture.store.loadTorrentAddQueue().isEmpty)
    }

    @Test func persistenceFailureNeverDeletes() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        // A directory at the atomic-write target forces the real store to fail.
        try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent("add-queue.json"), withIntermediateDirectories: true)
        #expect(!(await fixture.model.deleteDataAndQueue([await fixture.client.summary()], sourceID: fixture.sourceID)))
        #expect(await fixture.client.deleteCount == 0)
    }

    @Test func missingChoicesAndUnsafeRenamesAreRejected() throws {
        #expect(throws: RequeueError.self) {
            try TorrentDataRequeue.selection(from: .init(id: 1, hashString: "h", name: "x", files: [.init(name: "x", length: 1, bytesCompleted: 1)]))
        }
        #expect(throws: RequeueError.self) {
            try TorrentDataRequeue.renames(original: [.init(name: "x", length: 1, bytesCompleted: 0)],
                desired: [.init(name: "../x", length: 1, bytesCompleted: 1)])
        }
    }
}

@MainActor private struct Fixture {
    let root: URL
    let store: FileProfileStore
    let client: RequeueClient
    let sourceID: UUID
    let model: RemoteAppModel
    let remote: Bool
    init(remote: Bool = false) throws {
        self.remote = remote
        root = FileManager.default.temporaryDirectory.appendingPathComponent("GlassRequeue-" + UUID().uuidString)
        store = FileProfileStore(fileURL: root.appendingPathComponent("profiles.json"))
        client = RequeueClient(store: store)
        let source = remote ? UUID() : UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        sourceID = source
        if remote { try store.saveProfiles([RemoteProfile(id: source, name: "Fixture", rpcURL: URL(string: "http://localhost:9091/transmission/rpc")!, username: "")]) }
        let client = client
        model = RemoteAppModel(profileStore: store, credentialStore: RequeueCredentials(), initialSourceID: source,
            rpcClientFactory: { _ in client }, localSessionFactory: { client })
    }
    func makeModel() -> RemoteAppModel {
        let client = client
        return RemoteAppModel(profileStore: store, credentialStore: RequeueCredentials(), initialSourceID: sourceID,
            rpcClientFactory: { _ in client }, localSessionFactory: { client })
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
}
private struct RequeueCredentials: CredentialStore {
    func password(for id: UUID) throws -> String { "" }
    func savePassword(_ password: String, for id: UUID) throws {}
    func deletePassword(for id: UUID) throws {}
}

private actor RequeueClient: LocalTransmissionServicing, TransmissionRPCServicing {
    enum Failure: Sendable { case add, lostDeleteReply, deleteRejected, metadata, choices }
    static let metainfo: Data = {
        let files = ["A.mkv", "B.mkv"].map { "d6:lengthi10e4:pathl\($0.utf8.count):\($0)ee" }.joined()
        return Data("d4:infod5:filesl\(files)e4:name3:Raw12:piece lengthi32768e6:pieces20:00000000000000000000ee".utf8)
    }()
    static let hash = TorrentMetainfoIdentity.hashes(in: metainfo).first(where: { $0.count == 40 })!
    let store: FileProfileStore
    var failure: Failure?
    var present = true
    var replaced = false
    var names = ["Nice/B.mkv", "Nice/A.mkv"]
    var selection = TorrentAddFileSelection(filesWanted: [0], filesUnwanted: [1], priorityHigh: [0], priorityLow: [1])
    var deleteCount = 0, startCount = 0
    var restoredPriority: Int?, restoredPosition: Int?
    init(store: FileProfileStore) { self.store = store }
    func setFailure(_ value: Failure?) { failure = value }
    func exportMetainfo(hashString: String) async throws -> Data { failure == .metadata ? Data([1]) : Self.metainfo }
    func fetchTorrentMagnet(hashString: String) async throws -> String { "magnet:?xt=urn:btih:\(Self.hash)" }
    func resolveMagnetMetainfo(_ magnet: String) async throws -> Data { Self.metainfo }
    func summary() -> TorrentSummary {
        .init(id: replaced ? 2 : 1, hashString: Self.hash, name: replaced ? names[0].components(separatedBy: "/")[0] : "Nice",
            status: 0, percentDone: replaced ? 0 : 1, rateDownload: 0, rateUpload: 0, sizeWhenDone: 10,
            leftUntilDone: replaced ? 10 : 0, eta: -1, uploadRatio: 0, peersConnected: 0,
            downloadDir: "/downloads/existing", bandwidthPriority: 1, queuePosition: 4, fileCount: 2)
    }
    func fetchTorrents() async throws -> [TorrentSummary] { present ? [summary()] : [] }
    func fetchRecentlyActiveTorrents() async throws -> TorrentCollectionUpdate { .delta(changed: [], removedIDs: []) }
    func fetchSnapshot() async throws -> TorrentProviderSnapshot {
        .init(stats: try await fetchSessionStats(), torrents: present ? [summary()] : [], freeSpace: nil)
    }
    func fetchSessionStats() async throws -> SessionStats {
        try JSONDecoder().decode(SessionStats.self, from: Data(#"{"downloadSpeed":0,"uploadSpeed":0}"#.utf8))
    }
    func fetchDefaultFreeSpace() async throws -> ServerFreeSpace? { nil }
    func testConnection() async throws {}
    func fetchDefaultDownloadDirectory() async throws -> String? { "/downloads/existing" }
    func fetchSessionSettings() async throws -> TransmissionSessionSettings { try JSONDecoder().decode(TransmissionSessionSettings.self, from: Data("{}".utf8)) }
    func setSessionSettings(_ patch: TransmissionSessionSettingsPatch) async throws {}
    func fetchTorrentDetails(hashString: String) async throws -> TorrentDetails {
        guard present else { throw RequeueError("Absent") }
        return .init(id: replaced ? 2 : 1, hashString: Self.hash, name: names[0].components(separatedBy: "/")[0],
            status: 0, percentDone: replaced ? 0 : 1, sizeWhenDone: 10, downloadDir: "/downloads/existing",
            files: names.map { .init(name: $0, length: 10, bytesCompleted: replaced ? 0 : 10) },
            fileStats: names.indices.map { .init(bytesCompleted: replaced ? 0 : 10, wanted: selection.filesWanted.contains($0),
                priority: selection.priorityHigh.contains($0) ? 1 : selection.priorityLow.contains($0) ? -1 : 0) },
            bandwidthPriority: 1, queuePosition: 4)
    }
    func addMagnet(_ magnet: String, downloadDirectory: String?) async throws -> TorrentAddResult? { throw RequeueError("Must add saved bytes") }
    func addTorrentFile(data: Data, torrentName: String?, downloadDirectory: String?, fileSelection: TorrentAddFileSelection?) async throws -> TorrentAddResult? { throw RequeueError("Must add paused") }
    func addTorrentFile(data: Data, torrentName: String?, downloadDirectory: String?, fileSelection: TorrentAddFileSelection?, startPaused: Bool) async throws -> TorrentAddResult? {
        #expect(startPaused); #expect(data == Self.metainfo); #expect(downloadDirectory == "/downloads/existing")
        if failure == .add { throw RequeueError("Add failed") }
        present = true; replaced = true; names = ["Raw/A.mkv", "Raw/B.mkv"]
        if failure == .choices {
            selection = .init(filesWanted: [0, 1])
            throw RequeueError("Interrupted before applying file choices")
        }
        selection = try #require(fileSelection)
        return .init(hashString: Self.hash, name: "Raw", wasDuplicate: false)
    }
    func stop(ids: [String]) async throws {}
    func start(ids: [String]) async throws { startCount += 1 }
    func remove(ids: [String], deleteLocalData: Bool) async throws {
        let saved = try #require(store.loadTorrentAddQueue().first)
        #expect(saved.data == Self.metainfo)
        #expect(saved.dataRequeue?.removalStage == .removing)
        #expect(deleteLocalData)
        deleteCount += 1
        if failure == .deleteRejected { throw RequeueError("Delete rejected") }
        present = false
        if failure == .lostDeleteReply { throw RequeueError("Lost reply") }
    }
    func renamePath(id: String, path: String, name: String) async throws {
        let parent = (path as NSString).deletingLastPathComponent
        let target = parent.isEmpty ? name : parent + "/" + name
        names = names.map { $0 == path ? target : $0.hasPrefix(path + "/") ? target + $0.dropFirst(path.count) : $0 }
    }
    func setQueuePosition(ids: [String], position: Int) async throws { restoredPosition = position }
    func setTorrentPriority(ids: [String], priority: Int) async throws { restoredPriority = priority }
    func verify(ids: [String]) async throws {}
    func reannounce(ids: [String]) async throws {}
    func queueMoveTop(ids: [String]) async throws {}
    func queueMoveUp(ids: [String]) async throws {}
    func queueMoveDown(ids: [String]) async throws {}
    func queueMoveBottom(ids: [String]) async throws {}
    func setFileWanted(ids: [String], fileIndices: [Int], wanted: Bool) async throws {
        selection.filesWanted.removeAll { fileIndices.contains($0) }
        selection.filesUnwanted.removeAll { fileIndices.contains($0) }
        if wanted { selection.filesWanted += fileIndices } else { selection.filesUnwanted += fileIndices }
    }
    func setFilePriority(ids: [String], fileIndices: [Int], priority: Int) async throws {
        selection.priorityHigh.removeAll { fileIndices.contains($0) }
        selection.priorityNormal.removeAll { fileIndices.contains($0) }
        selection.priorityLow.removeAll { fileIndices.contains($0) }
        if priority == 1 { selection.priorityHigh += fileIndices }
        else if priority == -1 { selection.priorityLow += fileIndices }
        else { selection.priorityNormal += fileIndices }
    }
}
