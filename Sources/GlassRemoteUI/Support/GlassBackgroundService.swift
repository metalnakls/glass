import AppKit
import Foundation
import OSLog
import GlassRemoteCore
import ServiceManagement

/// Register the independent Downloads helper with Service Management.
@MainActor
public enum GlassBackgroundService {
    public static var isAvailable: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
    private static var service: SMAppService { .loginItem(identifier: "tsmc.glass.worker") }
    private static var version: String? { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String }
    private static var previousService: SMAppService { .agent(plistName: "tsmc.glass.background.plist") }
    public static var isEnabled: Bool { isAvailable && service.status == .enabled }
    public static var requiresApproval: Bool { isAvailable && service.status == .requiresApproval }

    public static func setEnabled(_ enabled: Bool) throws {
        guard !enabled || isAvailable else { return }
        if enabled, service.status != .enabled { try service.register() }
        else if !enabled, service.status != .notRegistered { try service.unregister() }
        UserDefaults.standard.set(enabled, forKey: "GlassBackground.enabled")
        if enabled { UserDefaults.standard.set(version, forKey: "GlassBackground.workerVersion") }
        if requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    public static func offerIfNeeded() {
        // Retire the legacy launchd job explicitly. Reusing its label also
        // reuses the saved signing requirement for the old UI executable.
        let migrateEnabledJob = previousService.status == .enabled
        if previousService.status != .notRegistered && previousService.status != .notFound {
            do { try previousService.unregister() }
            catch {
                Logger(subsystem: "tsmc.glass", category: "background").error("Retire old worker: \(error.localizedDescription)")
                return
            }
        }
        guard isAvailable else {
            // A release upgrade retires a previously approved debug agent.
            if service.status != .notRegistered { try? service.unregister() }
            UserDefaults.standard.set(false, forKey: "GlassBackground.enabled")
            return
        }
        let installedUpdate = isEnabled && UserDefaults.standard.string(forKey: "GlassBackground.workerVersion") != version
        if migrateEnabledJob || installedUpdate || (service.status == .notRegistered && UserDefaults.standard.bool(forKey: "GlassBackground.enabled")) {
            do {
                if installedUpdate { try service.unregister() }
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
        alert.informativeText = glassText("Glass can Smart Rename torrent files in Downloads even while the app is closed. You can disable this in Tune or Login Items.")
        alert.addButton(withTitle: glassText("Allow"))
        alert.addButton(withTitle: glassText("Not now"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try setEnabled(true)
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
    private var fingerprints: [String: Date] = [:]
    private var directorySource: DispatchSourceFileSystemObject?
    private var scanning = false
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
    private var downloads: URL? { diagnosticDirectory ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first }

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
                let renamed = diagnosticDirectory.appendingPathComponent(names[0])
                let modified = try renamed.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
                let icon = await TorrentFinderIconWriter.shared.apply(to: renamed, content: .file(name: name), modified: modified)
                guard try Data(contentsOf: renamed) == data, icon == .current else {
                    print("Worker icon or byte preservation failed: \(icon)")
                    exit(1)
                }
                let policy = await MainActor.run { NSRunningApplication.current.activationPolicy }
                guard policy == .prohibited else {
                    print("Worker became a foreground-capable process after Finder icon work: \(policy.rawValue)")
                    exit(1)
                }
                print("Worker rename, ghost icon, byte preservation, and prohibited activation passed: \(names[0])")
                exit(0)
            } catch { print("Worker check failed: \(error.localizedDescription)"); exit(1) }
        }
        #endif
        while !Task.isCancelled {
            if directorySource == nil { watchDownloads() }
            await scanDownloads()
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
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
            scanTask = nil
            await scanDownloads()
        }
    }

    private func scanDownloads() async {
        guard let downloads = downloads?.resolvingSymlinksInPath() else { return }
        guard !scanning else { scheduleScan(); return }
        scanning = true
        defer { scanning = false }
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
            let result = await TorrentFinderIconWriter.shared.apply(to: url, content: preview.iconContent, modified: modified)
            if result == .failed { logger.notice("Could not update torrent Finder icon") }
            guard !Task.isCancelled else { return }
            // Rendering suspends this scan. Do not rename from stale metadata
            // if the browser replaced or finished writing the torrent meanwhile.
            guard let current = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                  current.contentModificationDate == modified else { continue }
            let plan = TorrentNameCleaner.plan(rootName: preview.name, files: preview.files,
                selectedFileIndices: Set(preview.files.indices))
            let title = plan?.season.map { "\($0.title) \($0.season)" } ?? plan?.rootName ?? preview.name
            let displayTitle = TorrentExtensionPolicy.name(title, hiding: TorrentExtensionPolicy.hiddenExtension(paths: [title]))
            let safeTitle = String(displayTitle.replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-").prefix(180))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !safeTitle.isEmpty, safeTitle != ".", safeTitle != ".." else { continue }
            var target = downloads.appendingPathComponent(safeTitle).appendingPathExtension("torrent")
            var copy = 1
            while target != url && FileManager.default.fileExists(atPath: target.path) {
                copy += 1
                target = downloads.appendingPathComponent("\(safeTitle) (\(copy))").appendingPathExtension("torrent")
            }
            do {
                if target != url {
                    try DownloadsTorrentRename.move(url, to: target)
                }
                var values = URLResourceValues()
                values.hasHiddenExtension = true
                var mutableTarget = target
                try mutableTarget.setResourceValues(values)
                if result != .failed { fingerprints[target.path] = modified }
                present.insert(target.path)
                processed += 1
            } catch { logger.error("Torrent rename failed: \(error.localizedDescription, privacy: .public)") }
            await Task.yield()
        }
        fingerprints = fingerprints.filter { present.contains($0.key) }
        logger.info("Downloads scan: \(candidates) torrents, \(readable) read, \(processed) processed")
    }
}
