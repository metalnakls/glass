import AppKit
import Foundation
import OSLog
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
        if enabled { try BackgroundDownloadsAccess.authorize() }
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
        if isEnabled || UserDefaults.standard.bool(forKey: "GlassBackground.enabled") {
            // Obtain access before changing an approved registration, so canceling
            // a folder grant leaves the existing agent intact.
            do {
                try BackgroundDownloadsAccess.authorize()
                if isEnabled, UserDefaults.standard.string(forKey: "GlassBackground.registeredVersion") != version {
                    try service.unregister()
                }
                try setEnabled(true)
            } catch {
                Logger(subsystem: "tsmc.glass", category: "background")
                    .error("Background access setup failed: \(error.localizedDescription, privacy: .public)")
            }
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

    /// Foreground file renaming does not require a registered login agent.
    public static func renameDownloadsWhileOpen() async {
        do {
            try BackgroundDownloadsAccess.ensureForegroundAccess()
        } catch {
            Logger(subsystem: "tsmc.glass", category: "background")
                .error("Smart Rename needs Downloads access: \(error.localizedDescription, privacy: .public)")
            return
        }
        await GlassBackgroundWorker.shared.runForeground()
    }

    public static func run() async {
        guard isAvailable else { return }
        await GlassBackgroundWorker.shared.run()
    }
}


/// The foreground app retains its authorized folder access for the launch agent.
/// Bookmark storage remains inside the shared app container, without changing permissions.
private enum BackgroundDownloadsAccess {
    static var storage: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("GlassBackground", isDirectory: true)
            .appendingPathComponent("Downloads.bookmark")
    }

    /// The Downloads entitlement does not override macOS privacy restrictions.
    /// Check access in the app process before starting a watcher that cannot read.
    @MainActor static func ensureForegroundAccess() throws {
        if let scoped = try? resolve() {
            defer { scoped.stopAccessingSecurityScopedResource() }
            if (try? FileManager.default.contentsOfDirectory(atPath: scoped.path)) != nil { return }
        }
        if let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first,
           (try? FileManager.default.contentsOfDirectory(atPath: downloads.path)) != nil { return }
        try authorize()
    }

    @MainActor static func authorize() throws {
        if let url = try? resolve() {
            let readable = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil
            url.stopAccessingSecurityScopedResource()
            if readable { return }
        }
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first,
              let storage else { throw CocoaError(.fileNoSuchFile) }
        // Standard-folder entitlement access does not produce a transferable scope
        // for an independently launched agent. The native picker grants that scope.
        let panel = NSOpenPanel()
        panel.title = glassText("Allow Downloads access")
        panel.message = glassText("Choose Downloads to allow Glass to Smart Rename torrent files.")
        panel.prompt = glassText("Allow")
        panel.directoryURL = downloads
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let chosen = panel.url else { throw CocoaError(.userCancelled) }
        guard chosen.resolvingSymlinksInPath().standardizedFileURL == downloads.resolvingSymlinksInPath().standardizedFileURL else {
            throw CocoaError(.fileReadNoPermission)
        }
        let accessing = chosen.startAccessingSecurityScopedResource()
        defer { if accessing { chosen.stopAccessingSecurityScopedResource() } }
        let data = try chosen.bookmarkData(options: .withSecurityScope)
        try FileManager.default.createDirectory(at: storage.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: storage, options: .atomic)
    }

    static func resolve() throws -> URL? {
        guard let storage, FileManager.default.fileExists(atPath: storage.path) else { return nil }
        let data = try Data(contentsOf: storage)
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], bookmarkDataIsStale: &stale)
        guard url.startAccessingSecurityScopedResource() else { throw CocoaError(.fileReadNoPermission) }
        do {
            if stale { try url.bookmarkData(options: .withSecurityScope).write(to: storage, options: .atomic) }
        } catch {
            url.stopAccessingSecurityScopedResource()
            throw error
        }
        return url
    }
}

private actor GlassBackgroundWorker {
    static let shared = GlassBackgroundWorker()
    private var observed: [String: Double] = [:]
    private var fingerprints: [String: Date] = [:]
    private var directorySource: DispatchSourceFileSystemObject?
    private var scanTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "tsmc.glass", category: "background")
    // Debug-only isolation permits exercising the real watcher without renaming user files or polling servers.
    private let diagnosticDirectory: URL? = {
        #if DEBUG
        let arguments = CommandLine.arguments
        if arguments.contains("--background-worker-self-test") {
            return FileManager.default.temporaryDirectory.appendingPathComponent("GlassWorkerCheck-" + UUID().uuidString, isDirectory: true)
        }
        if let index = arguments.firstIndex(of: "--background-worker-directory"), arguments.indices.contains(index + 1) {
            return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        }
        #endif
        return nil
    }()
    private var scopedDownloads: URL?
    private var downloads: URL? { diagnosticDirectory ?? scopedDownloads ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first }
    private let defaults = UserDefaults.standard

    private var foregroundOwner = false

    func runForeground() async {
        guard !foregroundOwner else { return }
        foregroundOwner = true
        do { scopedDownloads = try BackgroundDownloadsAccess.resolve() }
        catch { logger.error("Downloads access: \(error.localizedDescription, privacy: .public)") }
        watchDownloads()
        defer {
            scanTask?.cancel()
            directorySource?.cancel()
            directorySource = nil
            scopedDownloads?.stopAccessingSecurityScopedResource()
            scopedDownloads = nil
            foregroundOwner = false
        }
        while !Task.isCancelled {
            await scanDownloads()
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
        }
    }

    func run() async {
        #if DEBUG
        if CommandLine.arguments.contains("--background-worker-self-test"), let diagnosticDirectory {
            do {
                let contents = diagnosticDirectory.appendingPathExtension("contents")
                try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(at: diagnosticDirectory, withDestinationURL: contents)
                defer {
                    try? FileManager.default.removeItem(at: diagnosticDirectory)
                    try? FileManager.default.removeItem(at: contents)
                }
                let name = "The.People.vs.Larry.Flynt.1996.1080p.BluRay.mkv"
                var data = Data("d4:infod6:lengthi100e4:name\(name.utf8.count):\(name)12:piece lengthi16384e6:pieces20:".utf8)
                data.append(Data(repeating: 48, count: 20))
                data.append(Data("ee".utf8))
                let original = diagnosticDirectory.appendingPathComponent("Original long name.torrent")
                try data.write(to: original)
                try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -5)], ofItemAtPath: original.path)
                await scanDownloads()
                let names = try FileManager.default.contentsOfDirectory(atPath: diagnosticDirectory.path)
                guard names == ["The People vs Larry Flynt.torrent"] else {
                    print("Worker rename failed: \(names)")
                    exit(1)
                }
                print("Worker rename passed: \(names[0])")
                exit(0)
            } catch { print("Worker check failed: \(error.localizedDescription)"); exit(1) }
        }
        #endif
        if diagnosticDirectory == nil {
            do { scopedDownloads = try BackgroundDownloadsAccess.resolve() }
            catch { logger.error("Could not restore Downloads access: \(error.localizedDescription, privacy: .public)") }
        }
        defer { scopedDownloads?.stopAccessingSecurityScopedResource() }
        observed = defaults.dictionary(forKey: "GlassBackground.observed") as? [String: Double] ?? [:]
        watchDownloads()
        await scanDownloads()
        while !Task.isCancelled {
            // A visible Glass process owns completion notifications while running.
            let foregroundRunning = await MainActor.run {
                NSRunningApplication.runningApplications(withBundleIdentifier: "tsmc.glass")
                    .contains { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            }
            if diagnosticDirectory == nil, !foregroundRunning || observed.isEmpty { await checkServers(notify: !foregroundRunning) }
            try? await Task.sleep(for: .seconds(30))
        }
    }

    private func watchDownloads() {
        guard let downloads else { return }
        let descriptor = open(downloads.path, O_EVTONLY)
        guard descriptor >= 0 else {
            logger.error("Downloads watcher could not open directory: errno \(errno)")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete], queue: .global(qos: .utility))
        source.setEventHandler { @Sendable [weak self] in
            Task { await self?.scheduleScan() }
        }
        source.setCancelHandler { @Sendable in close(descriptor) }
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
        if !foregroundOwner && diagnosticDirectory == nil {
            let foregroundRunning = await MainActor.run {
                NSRunningApplication.runningApplications(withBundleIdentifier: "tsmc.glass")
                    .contains { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            }
            guard !foregroundRunning else { return }
        }
        guard let downloads = downloads?.resolvingSymlinksInPath() else { return }
        let entries: [URL]
        do {
            // This is a flat scan. The sandbox's standard Downloads URL is a
            // symlink, which a recursive DirectoryEnumerator refuses to follow.
            entries = try FileManager.default.contentsOfDirectory(at: downloads,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles])
        } catch {
            logger.error("Downloads listing failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        var present = Set<String>()
        var candidates = 0
        var readable = 0
        var processed = 0
        for url in entries {
            guard !Task.isCancelled else { return }
            guard url.pathExtension.lowercased() == "torrent" else { continue }
            present.insert(url.path)
            candidates += 1
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true, let count = values.fileSize, count > 0, count <= 8 * 1_024 * 1_024,
                  let modified = values.contentModificationDate, fingerprints[url.path] != modified else { continue }
            // Ignore files still being written; their next directory event schedules another pass.
            guard modified.timeIntervalSinceNow < -1 else { scheduleScan(); continue }
            let data: Data
            do {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                data = try handle.read(upToCount: 8 * 1_024 * 1_024 + 1) ?? Data()
            } catch {
                logger.error("Torrent read failed: \(error.localizedDescription, privacy: .public)")
                continue
            }
            readable += 1
            guard data.count <= 8 * 1_024 * 1_024,
                  !TorrentMetainfoIdentity.hashes(in: data).isEmpty else {
                logger.notice("Skipping invalid torrent metainfo")
                continue
            }
            let preview = TorrentFilePreview(data: data, fallbackURL: url)
            let plan = TorrentNameCleaner.plan(rootName: preview.name, files: preview.files,
                selectedFileIndices: Set(preview.files.indices))
            let title = plan?.season.map { "\($0.title) \($0.season)" } ?? plan?.rootName ?? preview.name
            let displayTitle = TorrentExtensionPolicy.name(title, hiding: TorrentExtensionPolicy.hiddenExtension(paths: [title]))
            let safeTitle = String(displayTitle.replacingOccurrences(of: "/", with: "-")
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
                fingerprints[target.path] = modified
                present.insert(target.path)
                processed += 1
            } catch { logger.error("Torrent rename failed: \(error.localizedDescription, privacy: .public)") }
            await Task.yield()
        }
        fingerprints = fingerprints.filter { present.contains($0.key) }
        logger.info("Downloads scan: \(candidates) torrents, \(readable) read, \(processed) processed")
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
                    let details = try? await rpc.fetchTorrentDetails(hashString: torrent.hashString)
                    let stored = (try? store.loadTorrentDisplayNames())?["\(profile.id.uuidString):\(torrent.hashString)"]
                    await GlassCompletionNotificationCenter.shared.notifyTorrentCompleted(name: torrent.name,
                        displayName: stored.flatMap { $0.rootName == torrent.name ? $0.displayName : nil } ?? torrent.name,
                        fileCount: torrent.fileCount,
                        filePath: details?.files.first?.name.split(separator: "/").first.map(String.init), sourceID: profile.id, hashString: torrent.hashString,
                        downloadDirectory: torrent.downloadDir, completionDate: details?.doneDate ?? torrent.doneDate)
                }
                observed[key] = torrent.percentDone
            }
        }
        // Cap stale records but retain reconnect history through temporary RPC failure.
        if observed.count > 10_000 { observed = observed.filter { seen.contains($0.key) } }
        defaults.set(observed, forKey: "GlassBackground.observed")
    }
}
