import AppKit
import Foundation
import GlassRemoteCore
import ServiceManagement
import UserNotifications

/// A user-approved launch agent uses the app's executable and sandbox identity.
/// No credentials or access bookmarks are copied into another container.
@MainActor
public enum GlassBackgroundService {
    public static let isWorker = CommandLine.arguments.contains("--background-worker")
    public static var isAvailable: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
    private static var service: SMAppService { .agent(plistName: "tsmc.glass.background.plist") }
    public static var isEnabled: Bool { isAvailable && service.status == .enabled }
    public static var requiresApproval: Bool { isAvailable && service.status == .requiresApproval }

    public static func setEnabled(_ enabled: Bool) throws {
        guard !enabled || isAvailable else { return }
        if enabled, service.status != .enabled { try service.register() }
        else if !enabled, service.status != .notRegistered { try service.unregister() }
        UserDefaults.standard.set(enabled, forKey: "GlassBackground.enabled")
        if enabled { UserDefaults.standard.set(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            forKey: "GlassBackground.registeredVersion") }
        if requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    public static func offerIfNeeded() {
        guard isAvailable else {
            // A release upgrade retires a previously approved debug agent.
            if service.status != .notRegistered { try? service.unregister() }
            UserDefaults.standard.set(false, forKey: "GlassBackground.enabled")
            return
        }
        guard !isWorker else { return }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        if isEnabled, UserDefaults.standard.string(forKey: "GlassBackground.registeredVersion") != version {
            // Native launch agents must be re-registered when their executable changes.
            // Prior consent persists, so this updates the already-enabled agent only.
            do {
                try service.unregister()
                try setEnabled(true)
            } catch { /* Leave the previous registration state visible in Tune. */ }
        }
        guard !UserDefaults.standard.bool(forKey: "GlassBackground.offered") else { return }
        UserDefaults.standard.set(true, forKey: "GlassBackground.offered")
        let alert = NSAlert()
        alert.messageText = glassText("Allow background work?")
        alert.informativeText = glassText("Glass can Smart Rename torrent files in Downloads and check your saved servers for completed downloads while the app is closed. You can disable this in Tune or Login Items.")
        alert.addButton(withTitle: glassText("Allow"))
        alert.addButton(withTitle: glassText("Not now"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try setEnabled(true)
            Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
        } catch {
            let failure = NSAlert(error: error)
            failure.runModal()
        }
    }

    public static func run() async {
        guard isAvailable else { return }
        await GlassBackgroundWorker.shared.run()
    }
}

private actor GlassBackgroundWorker {
    static let shared = GlassBackgroundWorker()
    private var observed: [String: Double] = [:]
    private var fingerprints: [String: Date] = [:]
    private var directorySource: DispatchSourceFileSystemObject?
    private var scanTask: Task<Void, Never>?
    private let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    private let defaults = UserDefaults.standard

    func run() async {
        observed = defaults.dictionary(forKey: "GlassBackground.observed") as? [String: Double] ?? [:]
        watchDownloads()
        await scanDownloads()
        while !Task.isCancelled {
            // A visible Glass process owns completion notifications while running.
            let foregroundRunning = await MainActor.run {
                NSRunningApplication.runningApplications(withBundleIdentifier: "tsmc.glass")
                    .contains { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            }
            if !foregroundRunning || observed.isEmpty { await checkServers(notify: !foregroundRunning) }
            try? await Task.sleep(for: .seconds(30))
        }
    }

    private func watchDownloads() {
        guard let downloads else { return }
        let descriptor = open(downloads.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete], queue: .global(qos: .utility))
        source.setEventHandler { Task { await self.scheduleScan() } }
        source.setCancelHandler { close(descriptor) }
        directorySource = source
        source.resume()
    }

    private func scheduleScan() {
        scanTask?.cancel()
        scanTask = Task {
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            await scanDownloads()
        }
    }

    private func scanDownloads() async {
        guard let downloads,
              let enumerator = FileManager.default.enumerator(at: downloads,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
                options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]) else { return }
        var present = Set<String>()
        while let url = enumerator.nextObject() as? URL {
            guard !Task.isCancelled else { return }
            guard url.pathExtension.lowercased() == "torrent" else { continue }
            present.insert(url.path)
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true, let count = values.fileSize, count > 0, count <= 8 * 1_024 * 1_024,
                  let modified = values.contentModificationDate, fingerprints[url.path] != modified else { continue }
            // Ignore files still being written; their next directory event schedules another pass.
            guard modified.timeIntervalSinceNow < -1 else { scheduleScan(); continue }
            fingerprints[url.path] = modified
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            let contents = try? handle.read(upToCount: 8 * 1_024 * 1_024 + 1)
            try? handle.close()
            guard let data = contents, data.count <= 8 * 1_024 * 1_024,
                  !TorrentMetainfoIdentity.hashes(in: data).isEmpty else { continue }
            let preview = TorrentFilePreview(data: data, fallbackURL: url)
            let plan = TorrentNameCleaner.plan(rootName: preview.name, files: preview.files,
                selectedFileIndices: Set(preview.files.indices))
            let title = plan?.season.map { "\($0.title) \($0.season)" } ?? plan?.rootName ?? preview.name
            let safeTitle = String(title.replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-").prefix(180))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !safeTitle.isEmpty, safeTitle != ".", safeTitle != ".." else { continue }
            let target = downloads.appendingPathComponent(safeTitle).appendingPathExtension("torrent")
            do {
                if target != url {
                    guard !FileManager.default.fileExists(atPath: target.path) else { continue }
                    try FileManager.default.moveItem(at: url, to: target)
                }
                var values = URLResourceValues()
                values.hasHiddenExtension = true
                var mutableTarget = target
                try mutableTarget.setResourceValues(values)
                await MainActor.run {
                    let icon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
                    NSWorkspace.shared.setIcon(icon, forFile: target.path, options: [])
                }
            } catch { /* Access may be revoked or the downloader may replace the file. */ }
            await Task.yield()
        }
        fingerprints = fingerprints.filter { present.contains($0.key) }
    }

    private func checkServers(notify: Bool) async {
        guard let store = try? FileProfileStore.applicationSupportStore(),
              let profiles = try? store.loadProfiles() else { return }
        let credentials = KeychainCredentialStore()
        var seen = Set<String>()
        for profile in profiles {
            guard let password = try? credentials.password(for: profile.id) else { continue }
            let rpc = TransmissionRPCClient(config: .init(profile: profile, password: password, timeout: 8))
            guard let torrents = try? await rpc.fetchTorrents() else { continue }
            for torrent in torrents {
                let key = "\(profile.id.uuidString):\(torrent.hashString)"
                seen.insert(key)
                if notify, let previous = observed[key], previous < 1, torrent.percentDone >= 1 {
                    let content = UNMutableNotificationContent()
                    content.title = await MainActor.run { glassText("Download complete") }
                    content.body = torrent.name
                    content.sound = .default
                    content.userInfo = ["sourceID": profile.id.uuidString, "hashString": torrent.hashString, "name": torrent.name, "directory": torrent.downloadDir ?? ""]
                    try? await UNUserNotificationCenter.current().add(.init(identifier: "completed-\(key)", content: content, trigger: nil))
                }
                observed[key] = torrent.percentDone
            }
        }
        // Cap stale records but retain reconnect history through temporary RPC failure.
        if observed.count > 10_000 { observed = observed.filter { seen.contains($0.key) } }
        defaults.set(observed, forKey: "GlassBackground.observed")
    }
}
