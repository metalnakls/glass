import Foundation
import GlassRemoteCore
import Observation
@testable import GlassRemoteServices
import Testing

@MainActor
@Suite("Remote app model")
struct RemoteAppModelTests {
    @Test("inactive auto refresh finishes without opening local or remote connections")
    func inactiveAutoRefreshStops() async {
        let factory = StubRPCClientFactory()
        let local = StubLocalTransmissionSession()
        let model = makeModel(profiles: [makeProfile()], factory: factory, localSession: local)
        model.setApplicationActive(false)
        await model.runAutoRefresh()
        #expect(factory.createdCount == 0)
        #expect(await local.fetchSnapshotCount == 0)
    }

    @Test("activation starts polling and cancellation permits a fresh activation", .timeLimit(.minutes(1)))
    func autoRefreshActivationLifecycle() async {
        let client = StubRPCClient()
        let model = makeModel(profile: makeProfile(), factory: StubRPCClientFactory { _ in client })
        for count in 1...2 {
            model.setApplicationActive(true)
            let polling = Task { await model.runAutoRefresh() }
            await client.waitForTorrentFetch(count: count)
            model.setApplicationActive(false)
            polling.cancel()
            await polling.value
            #expect(await client.fetchTorrentsCount == count)
        }
    }

    @Test("group commands send all members in one request to their owning source")
    func batchedTransferCommands() async throws {
        let profile = makeProfile()
        let client = StubRPCClient()
        let model = makeModel(profile: profile, factory: StubRPCClientFactory { _ in client })
        await model.refresh(sourceID: profile.id)
        let first = try #require(model.torrentRecords.first?.summary)
        let second = TorrentSummary(id: 2, hashString: "hash-2", name: "Second", status: 0,
            percentDone: 0, rateDownload: 0, rateUpload: 0, sizeWhenDone: 100,
            leftUntilDone: 100, eta: -1, uploadRatio: 0, peersConnected: nil, downloadDir: nil)
        model.selectedProfileID = model.localSourceID
        #expect(await model.start([first, second], sourceID: profile.id))
        #expect(await model.stop([first, second], sourceID: profile.id))
        #expect(await client.startRequests == [["hash-1", "hash-2"]])
        #expect(await client.stopRequests == [["hash-1", "hash-2"]])
        #expect(await model.start([], sourceID: profile.id))
        #expect(await client.startRequests.count == 1)
    }

    @Test("adding rows survive stale snapshots and retire when the server row arrives")
    func pendingAdditionLifecycle() async throws {
        let profile = makeProfile()
        let client = StubRPCClient()
        let model = makeModel(profile: profile, factory: StubRPCClientFactory { _ in client })
        let id = UUID()
        model.prepareTorrentAddition(id: id, sourceID: profile.id, name: "New movie",
            size: 100, fileCount: 1, downloadDirectory: "/downloads", namingPlan: nil)
        let pending = try #require(model.allTorrentRecords.first)
        #expect(pending.isAdding)
        #expect(pending.summary.isUnfinished)
        let revision = model.libraryStructureRevision
        // An unrelated snapshot must not remove an unacknowledged addition.
        await model.refresh(sourceID: profile.id)
        #expect(model.allTorrentRecords.contains { $0 === pending })
        let added = await model.addTorrentFile(Data([1]), downloadDirectory: "/downloads",
            sourceID: profile.id, pendingAdditionID: id)
        #expect(added)
        #expect(!model.allTorrentRecords.contains { $0.isAdding })
        #expect(model.libraryStructureRevision > revision)
        #expect(model.allTorrentRecords.filter { $0.hashString == "hash-1" }.count == 1)
    }

    @Test("failed additions retain their row and leave other pending rows alone")
    func failedPendingAddition() async throws {
        let profile = makeProfile()
        let client = StubRPCClient()
        await client.setAddTorrentError(TestError.failed)
        let model = makeModel(profile: profile, factory: StubRPCClientFactory { _ in client })
        let first = UUID(), second = UUID()
        for id in [first, second] {
            model.prepareTorrentAddition(id: id, sourceID: profile.id, name: "New movie",
                size: 100, fileCount: 1, downloadDirectory: "/downloads", namingPlan: nil)
        }
        let added = await model.addTorrentFile(Data([1]), downloadDirectory: "/downloads",
            sourceID: profile.id, pendingAdditionID: first)
        #expect(!added)
        #expect(model.allTorrentRecords.count == 2)
        #expect(model.allTorrentRecords.contains { $0.hashString == "adding:\(first.uuidString)" })
        #expect(model.allTorrentRecords.contains { $0.hashString == "adding:\(second.uuidString)" })
        #expect(model.errorMessage != nil)
    }

    @Test("failed queue preserves complete submissions across relaunch")
    func failedQueueSurvivesRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = makeProfile()
        let store = FileProfileStore(fileURL: directory.appendingPathComponent("profiles.json"))
        try store.saveProfiles([profile])
        let client = StubRPCClient()
        await client.setAddTorrentError(URLError(.notConnectedToInternet))
        let factory = StubRPCClientFactory { _ in client }
        let model = RemoteAppModel(profileStore: store, credentialStore: MemoryCredentialStore(password: "secret"), rpcClientFactory: factory.make(config:))
        let id = UUID(), next = UUID()
        let selection = TorrentAddFileSelection(filesWanted: [0], filesUnwanted: [1], priorityHigh: [0])
        let plan = TorrentAddNamingPlan(rootName: "Spider Noir", pathRenames: [TorrentPathRename(path: "Spider-Noir/01.mkv", name: "Episode 1.mkv")])
        let data = Data("d4:infod4:name11:Spider-Noiree".utf8)
        for job in [id, next] {
            #expect(model.prepareTorrentAddition(id: job, sourceID: profile.id, name: "Spider-Noir", size: 100,
                fileCount: 2, downloadDirectory: "/nas/movies", namingPlan: plan, data: data,
                fileSelection: selection, sourceURL: directory.appendingPathComponent("source.torrent")))
        }
        #expect(!(await model.retryTorrentAddition(id)))
        let restored = RemoteAppModel(profileStore: store, credentialStore: MemoryCredentialStore(password: "secret"), rpcClientFactory: factory.make(config:))
        #expect(restored.allTorrentRecords.count == 2)
        #expect(restored.allTorrentRecords.allSatisfy { $0.additionPhase == .failed })
        let saved = try store.loadTorrentAddQueue()
        #expect(saved.count == 2)
        #expect(saved[0].data == data)
        #expect(saved[0].fileSelection == selection)
        #expect(saved[0].namingPlan == plan)
        #expect(saved[0].sourceID == profile.id)
        #expect(saved[0].downloadDirectory == "/nas/movies")
        #expect(!(await restored.retryTorrentAddition(id)))
        #expect(restored.allTorrentRecords.filter { $0.isAdding }.count == 2)
        await client.setAddTorrentError(nil)
        #expect(await restored.retryTorrentAddition(id))
        #expect(try store.loadTorrentAddQueue().map(\.id) == [next])
        #expect(await client.addedFiles.last?.data == data)
        #expect(await client.addedFiles.last?.selection == selection)
    }

    @Test("a lost add reply is recovered from the server and finishes Smart Rename without re-adding")
    func lateAcceptedAdditionKeepsNamingPlan() async throws {
        let profile = makeProfile(), client = StubRPCClient()
        let data = Data("d4:infod4:name11:Spider-Noiree".utf8)
        // Use an identity derived from the original metainfo, not its display name.
        let expectedHash = "aeddfc3b841a0eb14bbb58bc1517c9a78ec5e4b9"
        await client.configureQueuedAdd(hash: expectedHash, visible: false, acceptsBeforeThrow: true)
        await client.setAddTorrentError(URLError(.timedOut))
        let model = makeModel(profile: profile, factory: StubRPCClientFactory { _ in client })
        let id = UUID()
        model.prepareTorrentAddition(id: id, sourceID: profile.id, name: "Spider-Noir", size: 100, fileCount: 1,
            downloadDirectory: "/nas", namingPlan: TorrentAddNamingPlan(rootName: "Spider Noir", pathRenames: []), data: data)
        #expect(!(await model.retryTorrentAddition(id)))
        #expect(model.allTorrentRecords.first?.additionPhase == .failed)
        await model.refresh(sourceID: profile.id)
        await client.waitForRename()
        #expect(await model.retryTorrentAddition(id))
        #expect(await client.addedFiles.count == 1)
        #expect(await client.renamedPaths == [TorrentPathRename(path: "Spider-Noir", name: "Spider Noir")])
        #expect(model.allTorrentRecords.filter { $0.hashString == expectedHash }.count == 1)
        #expect(!model.allTorrentRecords.contains(where: { $0.isAdding }))
    }

    @Test("retry resumes failed renames without repeating the add or completed children")
    func retryContinuesAcceptedRename() async throws {
        let profile = makeProfile(), client = StubRPCClient()
        await client.setRenameFailurePath("Spider-Noir")
        let model = makeModel(profile: profile, factory: StubRPCClientFactory { _ in client })
        let id = UUID(), child = TorrentPathRename(path: "Spider-Noir/Old.mkv", name: "New.mkv")
        model.prepareTorrentAddition(id: id, sourceID: profile.id, name: "Spider-Noir", size: 100, fileCount: 1,
            downloadDirectory: nil, namingPlan: TorrentAddNamingPlan(rootName: "Spider Noir", pathRenames: [child]), data: Data([1]))
        #expect(!(await model.retryTorrentAddition(id)))
        #expect(model.allTorrentRecords.first?.additionPhase == .failed)
        await client.setRenameFailurePath(nil)
        #expect(await model.retryTorrentAddition(id))
        #expect(await client.addedFiles.count == 1)
        #expect(await client.renamedPaths.filter { $0 == child }.count == 1)
        #expect(!model.allTorrentRecords.contains(where: { $0.isAdding }))
    }

    @Test("download locally keeps the submission but uses the Mac destination")
    func failedRemoteAdditionDownloadsLocally() async throws {
        let profile = makeProfile(), client = StubRPCClient(), local = StubLocalTransmissionSession()
        await client.setAddTorrentError(URLError(.cannotConnectToHost))
        let model = makeModel(profiles: [profile], factory: StubRPCClientFactory { _ in client }, localSession: local)
        let id = UUID(), data = Data([1, 2, 3])
        let selection = TorrentAddFileSelection(filesUnwanted: [1])
        let plan = TorrentAddNamingPlan(rootName: "Local movie", pathRenames: [])
        model.prepareTorrentAddition(id: id, sourceID: profile.id, name: "Movie", size: 100, fileCount: 2,
            downloadDirectory: "/nas/Ultra/Movies", namingPlan: plan, data: data, fileSelection: selection)
        #expect(!(await model.retryTorrentAddition(id)))
        #expect(await model.downloadTorrentAdditionLocally(id))
        #expect(model.selectedSourceID == model.localSourceID)
        #expect(await local.addedFiles.first?.data == data)
        #expect(await local.addedFiles.first?.selection == selection)
        #expect(await local.addedFiles.first?.directory == "/Users/me/Downloads")
        #expect(await local.renamedPaths == [TorrentPathRename(path: "Local", name: "Local movie")])
        #expect(await client.addedFiles.count == 1)
    }

    @Test("concurrent retry clicks share one model-owned add")
    func concurrentRetryUsesOneRequest() async throws {
        let profile = makeProfile(), client = StubRPCClient()
        await client.holdAdd()
        let model = makeModel(profile: profile, factory: StubRPCClientFactory { _ in client })
        let id = UUID()
        model.prepareTorrentAddition(id: id, sourceID: profile.id, name: "Movie", size: 100, fileCount: 1,
            downloadDirectory: nil, namingPlan: nil, data: Data([1]))
        let first = Task { await model.retryTorrentAddition(id) }
        await client.waitForAdd()
        let second = Task { await model.retryTorrentAddition(id) }
        await Task.yield()
        await client.releaseAdd()
        #expect(await first.value)
        #expect(await second.value)
        #expect(await client.addedFiles.count == 1)
    }

    @Test("a queue write failure retains the row and prevents any RPC submission")
    func unsavedQueueDoesNotSubmit() async throws {
        let profile = makeProfile(), client = StubRPCClient()
        let store = MemoryProfileStore(profiles: [profile])
        store.rejectQueueWrites()
        let model = RemoteAppModel(profileStore: store, credentialStore: MemoryCredentialStore(password: ""),
            rpcClientFactory: { _ in client })
        #expect(!(await model.addTorrentFile(Data([1]), downloadDirectory: nil)))
        #expect(model.allTorrentRecords.first?.additionPhase == .failed)
        #expect(await client.addedFiles.isEmpty)
        let id = try #require(model.allTorrentRecords.first?.additionID)
        #expect(!(await model.retryTorrentAddition(id)))
        #expect(await client.addedFiles.isEmpty)
        model.cancelTorrentAddition(id)
        #expect(model.allTorrentRecords.count == 1)
    }

    @Test("an applied rename with a lost reply is confirmed rather than reported failed")
    func queuedRenameLostReply() async {
        let profile = makeProfile(), client = StubRPCClient()
        await client.setRenameBehavior(error: URLError(.timedOut), appliesBeforeThrow: true)
        let model = makeModel(profile: profile, factory: StubRPCClientFactory { _ in client })
        #expect(await model.addTorrentFile(Data([1]), downloadDirectory: nil,
            namingPlan: TorrentAddNamingPlan(rootName: "Spider Noir", pathRenames: [])))
        #expect(!model.allTorrentRecords.contains { $0.isAdding })
        #expect(await client.addedFiles.count == 1)
    }

    @Test("manual duplicate names still rename while Smart Rename leaves preexisting duplicates alone")
    func duplicateNamingChoices() async {
        for manual in [false, true] {
            let profile = makeProfile(), client = StubRPCClient()
            await client.setAddTorrentWasDuplicate(true)
            let model = makeModel(profile: profile, factory: StubRPCClientFactory { _ in client })
            #expect(await model.addTorrentFile(Data([1]), torrentName: manual ? "Chosen name" : nil,
                downloadDirectory: nil, namingPlan: manual ? nil : TorrentAddNamingPlan(rootName: "Smart name", pathRenames: [])))
            #expect(await client.renamedPaths.count == (manual ? 1 : 0))
        }
    }

    @Test("file priority updates before the server responds and rolls back on rejection", arguments: [false, true])
    func immediateFilePriority(rejected: Bool) async throws {
        let profile = makeProfile()
        let client = StubRPCClient()
        let model = makeModel(profile: profile, factory: StubRPCClientFactory { _ in client })
        await model.refresh(sourceID: profile.id)
        let torrent = try #require(model.torrentRecords.first?.summary)
        await model.loadDetails(for: torrent, sourceID: profile.id)
        model.setVisibleTorrentDetailSections([.files], forHashString: torrent.hashString)
        await model.loadDetailSection(.files, forHashString: torrent.hashString)
        let original = try #require(model.selectedTorrentDetails?.fileStats.first)
        await client.holdFilePriority(rejected: rejected)
        let request = Task { await model.setFilePriority(torrent, fileIndices: [0], priority: 1, sourceID: profile.id) }
        await client.waitForFilePriorityCall()
        #expect(model.selectedTorrentDetails?.fileStats.first?.priority == 1)
        #expect(model.selectedTorrentDetails?.fileStats.first?.bytesCompleted == original.bytesCompleted)
        await client.releaseFilePriority()
        await request.value
        #expect(model.selectedTorrentDetails?.fileStats.first?.priority == (rejected ? original.priority : 1))
    }

    @Test("native reorder updates immediately and can move to the queue end")
    func optimisticReorder() async throws {
        let profile = makeProfile()
        let client = StubRPCClient()
        let model = makeModel(profile: profile, factory: StubRPCClientFactory { _ in client })
        await model.refresh(sourceID: profile.id)
        let second = TorrentSummary(id: 2, hashString: "hash-2", name: "Second", status: 0,
            percentDone: 0.5, rateDownload: 0, rateUpload: 0, sizeWhenDone: 100,
            leftUntilDone: 50, eta: -1, uploadRatio: 0, peersConnected: nil, downloadDir: nil)
        await client.setRecentlyActiveUpdate(.delta(changed: [second], removedIDs: []))
        await model.refresh(sourceID: profile.id)
        await client.holdQueuePosition(error: nil)
        let task = Task { await model.reorder(["hash-1"], before: [], sourceID: profile.id) }
        await client.waitForQueuePositionCall()
        #expect(model.torrentRecords.map(\.hashString) == ["hash-2", "hash-1"])
        await client.releaseQueuePosition()
        await task.value
        #expect(model.torrentRecords.map(\.hashString) == ["hash-2", "hash-1"])
    }

    @Test("a rejected native reorder restores the previous source order")
    func rejectedReorder() async throws {
        let profile = makeProfile()
        let client = StubRPCClient()
        let model = makeModel(profile: profile, factory: StubRPCClientFactory { _ in client })
        await model.refresh(sourceID: profile.id)
        let second = TorrentSummary(id: 2, hashString: "hash-2", name: "Second", status: 0,
            percentDone: 0.5, rateDownload: 0, rateUpload: 0, sizeWhenDone: 100,
            leftUntilDone: 50, eta: -1, uploadRatio: 0, peersConnected: nil, downloadDir: nil)
        await client.setRecentlyActiveUpdate(.delta(changed: [second], removedIDs: []))
        await model.refresh(sourceID: profile.id)
        await client.holdQueuePosition(error: TestError.failed)
        let task = Task { await model.reorder(["hash-2"], before: ["hash-1"], sourceID: profile.id) }
        await client.waitForQueuePositionCall()
        #expect(model.torrentRecords.map(\.hashString) == ["hash-2", "hash-1"])
        await client.releaseQueuePosition()
        await task.value
        #expect(model.torrentRecords.map(\.hashString) == ["hash-1", "hash-2"])
        #expect(model.errorMessage != nil)
    }

    @Test("all sources retain separate identities and source-scoped deltas")
    func allSourcesKeepSeparateRecords() async throws {
        let first = makeProfile()
        let second = RemoteProfile(id: UUID(), name: "Second", rpcURL: URL(string: "http://second.test:9091/transmission/rpc")!, username: "")
        let firstClient = StubRPCClient()
        let secondClient = StubRPCClient()
        let factory = StubRPCClientFactory { config in
            config.profile.id == first.id ? firstClient : secondClient
        }
        let model = makeModel(profiles: [first, second], factory: factory)
        await model.refreshAllSources()
        let firstRecord = try #require(model.allTorrentRecords.first { $0.sourceID == first.id })
        let secondRecord = try #require(model.allTorrentRecords.first { $0.sourceID == second.id })
        #expect(firstRecord.hashString == secondRecord.hashString)
        #expect(firstRecord.id != secondRecord.id)
        #expect(model.allTorrentRecords.count == 3)

        await firstClient.setRecentlyActiveUpdate(.delta(changed: [], removedIDs: [1]))
        await model.refresh(sourceID: first.id)
        #expect(!model.allTorrentRecords.contains { $0.sourceID == first.id })
        #expect(model.allTorrentRecords.first { $0.sourceID == second.id } === secondRecord)
    }

    @Test("source failure preserves its records and other sources keep refreshing")
    func failedSourcePreservesLibrary() async throws {
        let profile = makeProfile()
        let client = StubRPCClient()
        let factory = StubRPCClientFactory { _ in client }
        let local = StubLocalTransmissionSession()
        let model = makeModel(profiles: [profile], factory: factory, localSession: local)
        await model.refreshAllSources()
        let record = try #require(model.allTorrentRecords.first { $0.sourceID == profile.id })
        await client.setFetchTorrentsError(TestError.failed)
        await model.refreshAllSources()
        #expect(model.allTorrentRecords.first { $0.sourceID == profile.id } === record)
        let state = try #require(model.sources.first { $0.id == profile.id })
        #expect(state.isSessionStale)
        #expect(state.refreshErrorMessage != nil)
        #expect(await local.fetchSnapshotCount == 2)
    }

    @Test("torrent commands use their explicit owner and refresh nonselected sources")
    func commandsUseExplicitSource() async throws {
        let profile = makeProfile()
        let factory = StubRPCClientFactory()
        let model = makeModel(profile: profile, factory: factory)
        await model.refresh()
        let record = try #require(model.torrentRecords.first)
        let client = try #require(factory.clients.first)
        model.selectedProfileID = model.localSourceID
        await model.stop(record.summary, sourceID: record.sourceID)
        try await Task.sleep(for: .milliseconds(300))
        #expect(await client.stoppedIDs == [record.hashString])
        #expect(await client.fetchTorrentsCount == 2)
        #expect(model.selectedSourceID == model.localSourceID)
    }

    @Test("same-hash inspector selection reloads from the new source")
    func inspectorUsesSourceIdentity() async throws {
        let first = makeProfile()
        let second = RemoteProfile(id: UUID(), name: "Second", rpcURL: URL(string: "http://second.test:9091/transmission/rpc")!, username: "")
        let firstClient = StubRPCClient()
        let secondClient = StubRPCClient()
        let factory = StubRPCClientFactory { config in
            config.profile.id == first.id ? firstClient : secondClient
        }
        let model = makeModel(profiles: [first, second], factory: factory)
        await model.refreshAllSources()
        let record = try #require(model.allTorrentRecords.first { $0.sourceID == first.id })
        await model.loadDetails(for: record.summary, sourceID: first.id)
        await model.loadDetails(for: record.summary, sourceID: second.id)
        #expect(await firstClient.fetchTorrentDetailsCount == 1)
        #expect(await secondClient.fetchTorrentDetailsCount == 1)
    }

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

    @Test("watches only newly added torrents and stops after completion")
    func watchesAddedTorrentUntilCompletion() async throws {
        let profile = makeProfile()
        let factory = StubRPCClientFactory()
        let notifier = RecordingTorrentCompletionNotifier()
        let model = makeModel(profile: profile, factory: factory, completionNotifier: notifier)

        let didAdd = await model.addTorrentFile(Data([0x01]), downloadDirectory: nil)

        #expect(didAdd)
        #expect(notifier.authorizationRequestCount == 1)
        #expect(model.isCompletionWatcherRunning)

        let client = try #require(factory.clients.first)
        await client.setInspectorProgress(percentDone: 1, fileBytesCompleted: 100)
        await model.checkWatchedTorrentCompletions()

        #expect(notifier.completedTorrentNames == ["Spider-Noir"])
        #expect(model.isCompletionWatcherRunning == false)
    }

    @Test("does not watch a duplicate torrent")
    func doesNotWatchDuplicateTorrent() async throws {
        let profile = makeProfile()
        let factory = StubRPCClientFactory()
        let notifier = RecordingTorrentCompletionNotifier()
        let model = makeModel(profile: profile, factory: factory, completionNotifier: notifier)
        await model.refresh()
        let client = try #require(factory.clients.first)
        await client.setAddTorrentWasDuplicate(true)

        let didAdd = await model.addTorrentFile(Data([0x01]), downloadDirectory: nil)

        #expect(didAdd)
        #expect(notifier.authorizationRequestCount == 0)
        #expect(model.isCompletionWatcherRunning == false)
    }

    @Test("inspector publishes a selection only when its files are ready and source matches")
    func inspectorWaitsForFiles() async throws {
        let profile = makeProfile()
        let factory = StubRPCClientFactory()
        let model = makeModel(profile: profile, factory: factory)
        await model.refresh()
        let torrent = try #require(model.torrents.first)
        await model.loadDetails(for: torrent)
        #expect(model.readyTorrentDetails(forHashString: torrent.hashString, sourceID: profile.id, including: [.files]) == nil)

        model.setVisibleTorrentDetailSections([.files], forHashString: torrent.hashString)
        await model.loadDetailSection(.files, forHashString: torrent.hashString)
        let ready = try #require(model.readyTorrentDetails(forHashString: torrent.hashString, sourceID: profile.id, including: [.files]))
        #expect(ready.files.first?.name == "Episode.mkv")
        #expect(model.readyTorrentDetails(forHashString: torrent.hashString, sourceID: UUID(), including: [.files]) == nil)
        #expect(model.readyTorrentDetails(forHashString: "another-torrent", sourceID: profile.id, including: [.files]) == nil)
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

    @Test("a newly selected torrent never publishes the previous torrent's files")
    func inspectorSelectionReadiness() async throws {
        let profile = makeProfile()
        let client = StubRPCClient(detailDelay: .milliseconds(120))
        let factory = StubRPCClientFactory { _ in client }
        let model = makeModel(profile: profile, factory: factory)
        await model.refresh()
        let first = try #require(model.torrents.first)
        await model.loadDetails(for: first)
        model.setVisibleTorrentDetailSections([.files], forHashString: first.hashString)
        await model.loadDetailSection(.files, forHashString: first.hashString)
        #expect(model.readyTorrentDetails(forHashString: first.hashString, sourceID: profile.id, including: [.files]) != nil)
        let second = TorrentSummary(id: 2, hashString: "hash-2", name: "Second", status: 0, percentDone: 0,
            rateDownload: 0, rateUpload: 0, sizeWhenDone: 100, leftUntilDone: 100, eta: -1, uploadRatio: 0,
            peersConnected: nil, downloadDir: "/downloads")
        let loading = Task { await model.loadDetails(for: second) }
        for _ in 0..<100 {
            if model.isLoadingTorrentDetails { break }
            await Task.yield()
        }
        #expect(model.isLoadingTorrentDetails)
        #expect(model.readyTorrentDetails(forHashString: first.hashString, sourceID: profile.id, including: [.files]) == nil)
        #expect(model.readyTorrentDetails(forHashString: second.hashString, sourceID: profile.id, including: [.files]) == nil)
        await loading.value
        #expect(model.readyTorrentDetails(forHashString: second.hashString, sourceID: profile.id, including: [.files]) == nil)
        model.setVisibleTorrentDetailSections([.files], forHashString: second.hashString)
        await model.loadDetailSection(.files, forHashString: second.hashString)
        #expect(model.readyTorrentDetails(forHashString: second.hashString, sourceID: profile.id, including: [.files])?.hashString == second.hashString)
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

    @Test("section observation ignores progress telemetry but follows completion and metadata")
    func sectionObservation() {
        func summary(progress: Double, metadata: Double = 1) -> TorrentSummary {
            TorrentSummary(id: 1, hashString: "section-observation", name: "Movie", status: 4,
                percentDone: progress, metadataPercentComplete: metadata, rateDownload: 1, rateUpload: 0,
                sizeWhenDone: 100, leftUntilDone: progress == 1 ? 0 : 50, eta: 60,
                uploadRatio: 0, peersConnected: 1, downloadDir: "/downloads")
        }
        let record = TorrentRecord(summary(progress: 0.5), sourceID: UUID())
        let changed = LockedFlag()
        withObservationTracking {
            _ = record.isUnfinished
        } onChange: { changed.set() }
        record.apply(summary(progress: 0.75))
        #expect(!changed.value)
        record.apply(summary(progress: 1))
        #expect(changed.value)
        #expect(!record.isUnfinished)
        record.apply(summary(progress: 1, metadata: 0.5))
        #expect(record.isUnfinished)
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

    @Test("automatic cache keeps every recent server and expires two-month-old entries despite the legacy toggle")
    func automaticCacheExpiry() async throws {
        let profiles = (0..<6).map { index in RemoteProfile(id: UUID(), name: "Server \(index)", rpcURL: URL(string: "http://server\(index)/rpc")!, username: "") }
        let store = MemoryProfileStore(profiles: profiles)
        try store.savePreferences(GlassRemotePreferences(isTorrentCachingEnabled: false, cachedServerLimit: 1))
        let cached = TorrentSummary(id: 55, hashString: "cached", name: "Cached", status: 0, percentDone: 1, rateDownload: 0, rateUpload: 0, sizeWhenDone: 100, leftUntilDone: 0, eta: -1, uploadRatio: 0, peersConnected: nil, downloadDir: nil)
        try store.saveTorrentCache(profiles.enumerated().map { index, profile in
            CachedTorrentList(profileID: profile.id, torrents: [cached], refreshedAt: index == 5 ? Calendar.current.date(byAdding: .month, value: -3, to: Date())! : Date())
        })
        let client = StubRPCClient()
        await client.setFetchTorrentsError(TestError.failed)
        let model = RemoteAppModel(profileStore: store, credentialStore: MemoryCredentialStore(password: "secret"), rpcClientFactory: { _ in client })
        for profile in profiles { await model.refresh(sourceID: profile.id) }
        #expect(model.preferences.isTorrentCachingEnabled)
        for profile in profiles.prefix(5) { #expect(model.sources.first { $0.id == profile.id }?.records.first?.hashString == "cached") }
        #expect(model.sources.first { $0.id == profiles[5].id }?.records.isEmpty == true)
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

    @Test("local source moves torrent data to the selected directory")
    func localSourceMovesTorrentData() async throws {
        let localSession = StubLocalTransmissionSession()
        let model = makeModel(
            profiles: [],
            factory: StubRPCClientFactory(),
            localSession: localSession
        )
        await model.refresh()
        let torrent = try #require(model.torrents.first)

        let moved = await model.moveLocalData(torrent, to: "/Users/me/Movies")

        #expect(moved)
        #expect(await localSession.movedData == ["local-hash": "/Users/me/Movies"])
        #expect(model.downloadDirectoriesForSelectedProfile().first == "/Users/me/Movies")
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

    @Test("a flat season root keeps its source-scoped display name across restart without caching")
    func flatSeasonNameSurvivesRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = makeProfile()
        let otherProfile = RemoteProfile(name: "Other", rpcURL: URL(string: "http://other.test:9091/transmission/rpc")!, username: "")
        let store = FileProfileStore(fileURL: directory.appendingPathComponent("profiles.json"))
        try store.saveProfiles([profile, otherProfile])
        try store.savePreferences(GlassRemotePreferences(isTorrentCachingEnabled: false))
        let client = StubRPCClient()
        let factory = StubRPCClientFactory { _ in client }
        let model = RemoteAppModel(profileStore: store, credentialStore: MemoryCredentialStore(password: "secret"), rpcClientFactory: factory.make(config:))
        #expect(await model.addTorrentFile(
            Data([0x05]), torrentName: "Fargo 4", downloadDirectory: "/Volumes/and",
            namingPlan: TorrentAddNamingPlan(rootName: "Fargo", pathRenames: [], displayName: "Fargo 4")
        ))
        await model.refresh()
        let record = try #require(model.torrentRecords.first)
        #expect(record.summary.name == "Fargo")
        #expect(record.displayName == "Fargo 4")
        #expect(await client.renamedPaths == [TorrentPathRename(path: "Spider-Noir", name: "Fargo")])

        let restored = RemoteAppModel(profileStore: store, credentialStore: MemoryCredentialStore(password: "secret"), rpcClientFactory: factory.make(config:))
        await restored.refresh()
        let restoredRecord = try #require(restored.torrentRecords.first)
        #expect(restoredRecord.summary.name == "Fargo")
        #expect(restoredRecord.displayName == "Fargo 4")
        restored.selectedProfileID = otherProfile.id
        await restored.refresh()
        #expect(try #require(restored.torrentRecords.first).displayName == nil)
        restored.selectedProfileID = profile.id
        #expect(await restored.rename(restoredRecord.summary, to: "Fargo Four"))
        #expect(restoredRecord.summary.name == "Fargo")
        #expect(restoredRecord.displayName == "Fargo Four")
        #expect(await client.renamedPaths.count == 1)
        #expect(try store.loadTorrentDisplayNames()[restoredRecord.id]?.displayName == "Fargo Four")
        try await client.renamePath(id: restoredRecord.hashString, path: "Fargo", name: "External name")
        await restored.refresh()
        #expect(restoredRecord.summary.name == "External name")
        #expect(restoredRecord.displayName == nil)
        #expect(await restored.remove(restoredRecord.summary, deleteData: false))
        #expect(try store.loadTorrentDisplayNames().isEmpty)
    }
}

@MainActor
private func makeModel(
    profile: RemoteProfile,
    factory: StubRPCClientFactory,
    disposer: RecordingTorrentSourceFileDisposer = RecordingTorrentSourceFileDisposer(),
    completionNotifier: (any TorrentCompletionNotifying)? = nil
) -> RemoteAppModel {
    RemoteAppModel(
        profileStore: MemoryProfileStore(profiles: [profile]),
        credentialStore: MemoryCredentialStore(password: "secret"),
        torrentSourceFileDisposer: disposer,
        rpcClientFactory: factory.make(config:),
        completionNotifier: completionNotifier,
        completionPollingInterval: .seconds(60)
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

@MainActor
private final class RecordingTorrentCompletionNotifier: TorrentCompletionNotifying {
    private(set) var authorizationRequestCount = 0
    private(set) var completedTorrentNames: [String] = []
    private(set) var badgeClearCount = 0

    func requestAuthorization() {
        authorizationRequestCount += 1
    }

    func notifyTorrentCompleted(name: String) {
        completedTorrentNames.append(name)
    }

    func clearBadge() {
        badgeClearCount += 1
    }
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
    private var holdingQueuePosition = false
    private var queuePositionError: (any Error)?
    private var queuePositionContinuation: CheckedContinuation<Void, Never>?
    private var queuePositionWaiter: CheckedContinuation<Void, Never>?
    private var didRequestQueuePosition = false
    private var holdingFilePriority = false
    private var rejectFilePriority = false
    private var filePriorityContinuation: CheckedContinuation<Void, Never>?
    private var filePriorityWaiter: CheckedContinuation<Void, Never>?
    private var didRequestFilePriority = false

    func holdFilePriority(rejected: Bool) {
        holdingFilePriority = true
        rejectFilePriority = rejected
        didRequestFilePriority = false
    }
    func waitForFilePriorityCall() async {
        if didRequestFilePriority { return }
        await withCheckedContinuation { filePriorityWaiter = $0 }
    }
    func releaseFilePriority() {
        holdingFilePriority = false
        filePriorityContinuation?.resume()
        filePriorityContinuation = nil
    }

    func holdQueuePosition(error: (any Error)?) {
        holdingQueuePosition = true
        queuePositionError = error
        didRequestQueuePosition = false
    }
    func waitForQueuePositionCall() async {
        if didRequestQueuePosition { return }
        await withCheckedContinuation { queuePositionWaiter = $0 }
    }
    func releaseQueuePosition() {
        holdingQueuePosition = false
        queuePositionContinuation?.resume()
        queuePositionContinuation = nil
    }
    func setQueuePosition(ids: [String], position: Int) async throws {
        didRequestQueuePosition = true
        queuePositionWaiter?.resume()
        queuePositionWaiter = nil
        if holdingQueuePosition { await withCheckedContinuation { queuePositionContinuation = $0 } }
        if let queuePositionError { throw queuePositionError }
    }

    private var torrentHash = "hash-1"
    private var torrentVisible = true
    private var acceptsAddBeforeThrow = false
    private var renameFailurePath: String?
    private var holdingAdd = false
    private var addContinuation: CheckedContinuation<Void, Never>?
    private var addWaiter: CheckedContinuation<Void, Never>?
    private var renameWaiter: CheckedContinuation<Void, Never>?
    private(set) var addedFiles: [(data: Data, directory: String?, selection: TorrentAddFileSelection?)] = []
    func configureQueuedAdd(hash: String, visible: Bool, acceptsBeforeThrow: Bool) {
        torrentHash = hash; torrentVisible = visible; acceptsAddBeforeThrow = acceptsBeforeThrow
    }
    func setRenameFailurePath(_ path: String?) { renameFailurePath = path }
    func holdAdd() { holdingAdd = true }
    func waitForAdd() async {
        if !addedFiles.isEmpty { return }
        await withCheckedContinuation { addWaiter = $0 }
    }
    func releaseAdd() { holdingAdd = false; addContinuation?.resume(); addContinuation = nil }
    func waitForRename() async {
        if !renamedPaths.isEmpty { return }
        await withCheckedContinuation { renameWaiter = $0 }
    }
    private var addTorrentWasDuplicate = false
    private(set) var fetchTorrentsCount = 0
    private(set) var fetchSessionStatsCount = 0
    private(set) var fetchFreeSpaceCount = 0
    private(set) var fetchTorrentDetailsCount = 0
    private(set) var fetchTorrentFilesCount = 0
    private(set) var fetchTorrentPeersCount = 0
    private(set) var cancelledTorrentDetailsCount = 0
    private(set) var renamedPaths: [TorrentPathRename] = []
    private(set) var stoppedIDs: [String] = []
    private(set) var startRequests: [[String]] = []
    private(set) var stopRequests: [[String]] = []
    private var torrentFetchWaiter: (count: Int, continuation: CheckedContinuation<Void, Never>)?

    func waitForTorrentFetch(count: Int) async {
        guard fetchTorrentsCount < count else { return }
        await withCheckedContinuation { torrentFetchWaiter = (count, $0) }
    }

    init(fetchDelay: Duration? = nil, detailDelay: Duration? = nil) {
        self.fetchDelay = fetchDelay
        self.detailDelay = detailDelay
    }

    func setAddTorrentError(_ error: (any Error)?) {
        addTorrentError = error
    }

    func setAddTorrentWasDuplicate(_ wasDuplicate: Bool) {
        addTorrentWasDuplicate = wasDuplicate
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
        if let waiter = torrentFetchWaiter, fetchTorrentsCount >= waiter.count {
            torrentFetchWaiter = nil
            waiter.continuation.resume()
        }
        if let fetchDelay {
            try await Task.sleep(for: fetchDelay)
        }
        if let fetchTorrentsError {
            throw fetchTorrentsError
        }
        guard torrentVisible else { return [] }
        return [
            TorrentSummary(
                id: 1,
                hashString: torrentHash,
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
            name: torrentName,
            files: [
                TorrentFile(
                    name: "Episode.mkv",
                    length: 100,
                    bytesCompleted: inspectorFileBytesCompleted
                )
            ],
            fileStats: [TorrentFileStats(bytesCompleted: inspectorFileBytesCompleted, wanted: true, priority: 0)]
        )
    }

    func fetchTorrentPeers(hashString: String) async throws -> TorrentDetails {
        fetchTorrentPeersCount += 1
        return TorrentDetails(id: 1, hashString: hashString, name: "Spider-Noir")
    }

    func addMagnet(_ magnet: String, downloadDirectory: String?) async throws -> TorrentAddResult? {
        TorrentAddResult(hashString: "hash-1", name: torrentName, wasDuplicate: false)
    }

    func addTorrentFile(
        data: Data,
        torrentName: String?,
        downloadDirectory: String?,
        fileSelection: TorrentAddFileSelection?
    ) async throws -> TorrentAddResult? {
        addedFiles.append((data, downloadDirectory, fileSelection))
        addWaiter?.resume(); addWaiter = nil
        if holdingAdd { await withCheckedContinuation { addContinuation = $0 } }
        if acceptsAddBeforeThrow { torrentVisible = true }
        if let addTorrentError { throw addTorrentError }
        torrentVisible = true
        return TorrentAddResult(
            hashString: torrentHash,
            name: torrentName ?? self.torrentName,
            wasDuplicate: addTorrentWasDuplicate
        )
    }

    func start(ids: [String]) async throws { startRequests.append(ids) }
    func stop(ids: [String]) async throws {
        stopRequests.append(ids)
        stoppedIDs.append(contentsOf: ids)
    }
    func remove(ids: [String], deleteLocalData: Bool) async throws {}
    func verify(ids: [String]) async throws {}
    func reannounce(ids: [String]) async throws {}
    func queueMoveTop(ids: [String]) async throws {}
    func queueMoveUp(ids: [String]) async throws {}
    func queueMoveDown(ids: [String]) async throws {}
    func queueMoveBottom(ids: [String]) async throws {}
    func renamePath(id: String, path: String, name: String) async throws {
        renamedPaths.append(TorrentPathRename(path: path, name: name))
        renameWaiter?.resume(); renameWaiter = nil
        if renameFailurePath == path { throw TestError.failed }
        if renameAppliesBeforeThrow {
            torrentName = name
        }
        if let renameError {
            throw renameError
        }
        torrentName = name
    }
    func setFileWanted(ids: [String], fileIndices: [Int], wanted: Bool) async throws {}
    func setFilePriority(ids: [String], fileIndices: [Int], priority: Int) async throws {
        didRequestFilePriority = true
        filePriorityWaiter?.resume()
        filePriorityWaiter = nil
        if holdingFilePriority { await withCheckedContinuation { filePriorityContinuation = $0 } }
        if rejectFilePriority { throw TestError.failed }
    }
    func setTorrentPriority(ids: [String], priority: Int) async throws {}
}

private actor StubLocalTransmissionSession: LocalTransmissionServicing {
    private(set) var fetchSnapshotCount = 0
    private(set) var addedFiles: [(data: Data, directory: String?, selection: TorrentAddFileSelection?)] = []
    private(set) var renamedPaths: [TorrentPathRename] = []
    private(set) var addTorrentFileCount = 0
    private(set) var movedData: [String: String] = [:]

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

    func addMagnet(_ magnet: String, downloadDirectory: String?) async throws -> TorrentAddResult? {
        TorrentAddResult(hashString: "local-hash", name: "Local", wasDuplicate: false)
    }

    func addTorrentFile(
        data: Data,
        torrentName: String?,
        downloadDirectory: String?,
        fileSelection: TorrentAddFileSelection?
    ) async throws -> TorrentAddResult? {
        addTorrentFileCount += 1
        addedFiles.append((data, downloadDirectory, fileSelection))
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
    func moveData(id: String, to downloadDirectory: String) async throws {
        movedData[id] = downloadDirectory
    }
    func renamePath(id: String, path: String, name: String) async throws { renamedPaths.append(TorrentPathRename(path: path, name: name)) }
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
    private var addQueue: [TorrentAddQueueEntry] = []
    private var refusesQueueWrites = false
    func rejectQueueWrites() { lock.withLock { refusesQueueWrites = true } }
    private var history: [DownloadDirectoryHistory] = []
    private var displayNames: [String: TorrentStoredDisplayName] = [:]

    init(profiles: [RemoteProfile]) {
        self.profiles = profiles
    }

    func loadTorrentAddQueue() throws -> [TorrentAddQueueEntry] { lock.withLock { addQueue } }
    func saveTorrentAddQueue(_ queue: [TorrentAddQueueEntry]) throws {
        try lock.withLock {
            if refusesQueueWrites { throw TestError.failed }
            addQueue = queue
        }
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

    func loadTorrentDisplayNames() throws -> [String: TorrentStoredDisplayName] {
        lock.withLock { displayNames }
    }

    func saveTorrentDisplayNames(_ names: [String: TorrentStoredDisplayName]) throws {
        lock.withLock { displayNames = names }
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
