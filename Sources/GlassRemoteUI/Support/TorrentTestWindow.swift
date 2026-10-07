import AppKit
import GlassRemoteCore
import GlassRemoteServices
import Observation
import SwiftUI

/// A disposable alternate model used by Tune to put sample torrents in the main list.
@MainActor @Observable public final class TorrentTestSessionState {
    private let session: TorrentTestSession
    public let model: RemoteAppModel
    @ObservationIgnored private var failedAdditionID: UUID?
    @ObservationIgnored private var updateAvailabilityBeforeSample: Bool?

    public init() {
        let session = TorrentTestSession()
        self.session = session
        model = RemoteAppModel(profileStore: TestProfileStore(), credentialStore: TestCredentials(),
            rpcClientFactory: { config in
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [OfflineTestRPCProtocol.self]
                return TransmissionRPCClient(config: config, session: URLSession(configuration: configuration))
            }, localSessionFactory: { session })
    }

    public func addSample() async {
        _ = await session.addTorrentFile(data: Data([1]), torrentName: "New Sample.mkv",
            downloadDirectory: "/Sample/Downloads", fileSelection: nil)
        await model.refresh(sourceID: model.localSourceID)
    }

    public func addFailedRemoteAdd() async {
        if let failedAdditionID { model.cancelTorrentAddition(failedAdditionID) }
        let profile = RemoteProfile(id: Self.offlineProfileID,
            name: "Offline sample NAS", rpcURL: URL(string: "http://offline.invalid/transmission/rpc")!, username: "")
        model.saveProfile(profile, password: "")
        let id = UUID()
        failedAdditionID = id
        model.prepareTorrentAddition(id: id, sourceID: profile.id, name: "Queued Movie.mkv", size: 1_000_000_000,
            fileCount: 1, downloadDirectory: "/Sample/NAS", namingPlan: nil, data: Data([1]))
        _ = await model.retryTorrentAddition(id)
        model.selectedProfileID = model.localSourceID
    }

    public func completeAll() async {
        await session.completeAll()
        await model.refresh(sourceID: model.localSourceID)
    }

    public func reset() async {
        if let failedAdditionID { model.cancelTorrentAddition(failedAdditionID) }
        failedAdditionID = nil
        if let profile = model.profiles.first(where: { $0.id == Self.offlineProfileID }) {
            model.deleteProfile(profile)
        }
        await session.reset()
        model.selectedProfileID = model.localSourceID
        model.selectedTorrentGroup = .all
        if let updateAvailabilityBeforeSample {
            GlassUpdateAvailability.shared.setAvailable(updateAvailabilityBeforeSample)
            self.updateAvailabilityBeforeSample = nil
        }
        model.errorMessage = nil
        await model.refreshAllSources()
    }

    public func end() async { await reset() }

    public func showUpdateAvailabilitySample() {
        if updateAvailabilityBeforeSample == nil {
            updateAvailabilityBeforeSample = GlassUpdateAvailability.shared.isAvailable
        }
        GlassUpdateAvailability.shared.setAvailable(true)
    }

    private static let offlineProfileID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
}

/// All sample remote traffic fails locally, without reaching any server.
private final class OfflineTestRPCProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}

/// Disposable in-memory provider: every action is confined to these fixtures.
actor TorrentTestSession: LocalTransmissionServicing {
    struct Fixture: Sendable {
        let id: Int; let name: String; let progress: Double; let count: Int; var missing = false
    }
    private static let fixtures = [
        Fixture(id: 1, name: "Aurora 1", progress: 0.62, count: 4),
        Fixture(id: 2, name: "Aurora 2", progress: 0.18, count: 4),
        Fixture(id: 3, name: "Aurora 3", progress: 1, count: 4),
        Fixture(id: 4, name: "Solar Drift.mkv", progress: 0.47, count: 1),
        Fixture(id: 5, name: "Quiet Coast.mov", progress: 0.12, count: 1),
        Fixture(id: 6, name: "Summer House.mkv", progress: 1, count: 1),
        Fixture(id: 7, name: "Orbital.mkv", progress: 1, count: 1),
        Fixture(id: 8, name: "Moonlit Cut.mp4", progress: 1, count: 1),
        Fixture(id: 9, name: "Archive", progress: 1, count: 3),
        Fixture(id: 10, name: "Velvet Waves.flac", progress: 1, count: 1),
        Fixture(id: 11, name: "Lost Studio.mkv", progress: 1, count: 1, missing: true)
    ]
    private var addedFixtures: [Fixture] = []
    private var statuses: [Int: Int] = [:]
    private var completed = Set<Int>()
    private var removed = Set<Int>()
    private var wanted: [String: [Int: Bool]] = [:]
    private var priorities: [String: [Int: Int]] = [:]
    private var allFixtures: [Fixture] { Self.fixtures + addedFixtures }
    private func summary(_ item: Fixture) -> TorrentSummary {
        let progress = completed.contains(item.id) ? 1 : item.progress
        let size = UInt64(item.id + 4) * 1_000_000_000
        return TorrentSummary(id: item.id, hashString: "glass-sample-\(item.id)", name: item.name,
            status: statuses[item.id] ?? (item.id == 2 || item.id == 5 || progress == 1 ? 0 : 4),
            percentDone: progress, rateDownload: progress == 1 ? 0 : 1_800_000, rateUpload: 0,
            sizeWhenDone: size, leftUntilDone: UInt64(Double(size) * (1 - progress)), eta: 600,
            uploadRatio: 0, peersConnected: 12, downloadDir: "/Sample/Downloads", fileCount: item.count,
            error: item.missing ? 3 : 0, errorString: item.missing ? "No data found" : nil,
            doneDate: progress == 1 ? 1_700_000_000 : nil)
    }
    func fetchSnapshot() async throws -> TorrentProviderSnapshot {
        TorrentProviderSnapshot(stats: SessionStats(downloadSpeed: 1_800_000, uploadSpeed: 0),
            torrents: allFixtures.filter { !removed.contains($0.id) }.map(summary),
            freeSpace: ServerFreeSpace(path: "/Sample/Downloads", sizeBytes: 185_000_000_000))
    }
    func fetchDefaultDownloadDirectory() async throws -> String? { "/Sample/Downloads" }
    func fetchSessionSettings() async throws -> TransmissionSessionSettings {
        try JSONDecoder().decode(TransmissionSessionSettings.self, from: Data("{}".utf8))
    }
    func setSessionSettings(_ patch: TransmissionSessionSettingsPatch) async throws {}
    func fetchTorrentDetails(hashString: String) async throws -> TorrentDetails {
        guard let item = allFixtures.first(where: { "glass-sample-\($0.id)" == hashString }) else {
            throw LocalTransmissionSessionError.unavailable("Sample removed")
        }
        let torrent = summary(item)
        let names: [String]
        if item.count == 4 {
            names = (1...4).map { "\(item.name)/S0\(item.id)E0\($0).mkv" }
        } else if item.count > 1 {
            names = ["Archive/Films/Arrival.mkv", "Archive/Films/Interlude.mkv", "Archive/Notes/Production.txt"]
        } else { names = [item.name] }
        let files = names.map { TorrentFile(name: $0, length: torrent.sizeWhenDone / UInt64(names.count),
            bytesCompleted: UInt64(Double(torrent.sizeWhenDone / UInt64(names.count)) * torrent.percentDone)) }
        let stats = names.indices.map { TorrentFileStats(bytesCompleted: files[$0].bytesCompleted,
            wanted: wanted[hashString]?[$0] ?? true, priority: priorities[hashString]?[$0] ?? 0) }
        return TorrentDetails(id: item.id, hashString: hashString, name: item.name, status: torrent.status,
            percentDone: torrent.percentDone, sizeWhenDone: torrent.sizeWhenDone, leftUntilDone: torrent.leftUntilDone,
            downloadDir: torrent.downloadDir, doneDate: torrent.doneDate, files: files, fileStats: stats)
    }
    func completeAll() { completed = Set(allFixtures.map(\.id)) }
    func reset() {
        addedFixtures = []
        statuses = [:]
        completed = []
        removed = []
        wanted = [:]
        priorities = [:]
    }
    private func setRunning(_ ids: [String], running: Bool) async throws {
        try await Task.sleep(for: .milliseconds(180))
        for item in allFixtures where ids.contains("glass-sample-\(item.id)") { statuses[item.id] = running ? 4 : 0 }
    }
    func start(ids: [String]) async throws { try await setRunning(ids, running: true) }
    func stop(ids: [String]) async throws { try await setRunning(ids, running: false) }
    func remove(ids: [String], deleteLocalData: Bool) async throws {
        removed.formUnion(allFixtures.filter { ids.contains("glass-sample-\($0.id)") }.map(\.id))
    }
    func setFileWanted(ids: [String], fileIndices: [Int], wanted: Bool) async throws {
        for id in ids { for index in fileIndices { self.wanted[id, default: [:]][index] = wanted } }
    }
    func setFilePriority(ids: [String], fileIndices: [Int], priority: Int) async throws {
        for id in ids { for index in fileIndices { priorities[id, default: [:]][index] = priority } }
    }
    func addMagnet(_ magnet: String, downloadDirectory: String?) async throws -> TorrentAddResult? { nil }
    func addTorrentFile(data: Data, torrentName: String?, downloadDirectory: String?, fileSelection: TorrentAddFileSelection?) async throws -> TorrentAddResult? {
        let id = 12 + addedFixtures.count
        let name = torrentName ?? "Queued Movie.mkv"
        addedFixtures.append(Fixture(id: id, name: name, progress: 0, count: 1))
        return TorrentAddResult(hashString: "glass-sample-\(id)", name: name, wasDuplicate: false)
    }
    func verify(ids: [String]) async throws {}
    func reannounce(ids: [String]) async throws {}
    func queueMoveTop(ids: [String]) async throws {}
    func queueMoveUp(ids: [String]) async throws {}
    func queueMoveDown(ids: [String]) async throws {}
    func queueMoveBottom(ids: [String]) async throws {}
    func renamePath(id: String, path: String, name: String) async throws {}
    func setTorrentPriority(ids: [String], priority: Int) async throws {}
}

private struct TestProfileStore: ProfileStore {
    func loadTorrentAddQueue() throws -> [TorrentAddQueueEntry] { [] }
    func saveTorrentAddQueue(_ queue: [TorrentAddQueueEntry]) throws {}
    func loadProfiles() throws -> [RemoteProfile] { [] }
    func saveProfiles(_ profiles: [RemoteProfile]) throws {}
    func loadPreferences() throws -> GlassRemotePreferences { .init() }
    func savePreferences(_ preferences: GlassRemotePreferences) throws {}
    func loadTorrentCache() throws -> [CachedTorrentList] { [] }
    func saveTorrentCache(_ cache: [CachedTorrentList]) throws {}
    func loadDownloadDirectoryHistory() throws -> [DownloadDirectoryHistory] { [] }
    func saveDownloadDirectoryHistory(_ history: [DownloadDirectoryHistory]) throws {}
    func loadTorrentDisplayNames() throws -> [String: TorrentStoredDisplayName] { [:] }
    func saveTorrentDisplayNames(_ names: [String: TorrentStoredDisplayName]) throws {}
}
private struct TestCredentials: CredentialStore {
    func password(for profileID: UUID) throws -> String { "" }
    func savePassword(_ password: String, for profileID: UUID) throws {}
    func deletePassword(for profileID: UUID) throws {}
}

private struct SampleArtworkKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var glassSampleArtwork: Bool {
        get { self[SampleArtworkKey.self] }
        set { self[SampleArtworkKey.self] = newValue }
    }
}

@MainActor enum TorrentSampleArtwork {
    private static let cache = NSCache<NSString, NSImage>()
    static func image(for name: String) -> NSImage {
        if let image = cache.object(forKey: name as NSString) { return image }
        let preview = name.contains("Moonlit")
        let size = preview ? NSSize(width: 320, height: 180) : NSSize(width: 180, height: 260)
        let palette: [(NSColor, NSColor)] = [(.init(red: 0.93, green: 0.71, blue: 0.61, alpha: 1), .init(red: 0.45, green: 0.35, blue: 0.55, alpha: 1)),
            (.init(red: 0.65, green: 0.81, blue: 0.85, alpha: 1), .init(red: 0.22, green: 0.41, blue: 0.47, alpha: 1)),
            (.init(red: 0.83, green: 0.79, blue: 0.92, alpha: 1), .init(red: 0.43, green: 0.36, blue: 0.58, alpha: 1))]
        let seed = name.utf8.reduce(0) { ($0 + Int($1)) % palette.count }
        let colors = palette[seed]
        let image = NSImage(size: size)
        image.lockFocus()
        NSGradient(starting: colors.0, ending: colors.1)?.draw(in: NSRect(origin: .zero, size: size), angle: 90)
        NSColor.white.withAlphaComponent(0.42).setFill()
        NSBezierPath(ovalIn: NSRect(x: size.width * 0.52, y: size.height * 0.5, width: size.width * 0.38, height: size.width * 0.38)).fill()
        let hills = NSBezierPath()
        hills.move(to: .zero); hills.line(to: NSPoint(x: size.width, y: 0))
        hills.line(to: NSPoint(x: size.width, y: size.height * 0.4))
        hills.curve(to: NSPoint(x: 0, y: size.height * 0.3), controlPoint1: NSPoint(x: size.width * 0.6, y: size.height * 0.14), controlPoint2: NSPoint(x: size.width * 0.3, y: size.height * 0.5))
        hills.close(); colors.1.withAlphaComponent(0.55).setFill(); hills.fill()
        let title = (name as NSString).deletingPathExtension.uppercased()
        (title as NSString).draw(in: NSRect(x: 16, y: 16, width: size.width - 32, height: preview ? 32 : 75),
            withAttributes: [.font: NSFont.systemFont(ofSize: preview ? 21 : 24, weight: .bold), .foregroundColor: NSColor.white])
        image.unlockFocus()
        cache.setObject(image, forKey: name as NSString)
        return image
    }
}
