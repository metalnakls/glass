import AppKit
import GlassRemoteCore
import GlassRemoteServices
import GlassRemoteUI
import Sparkle
import SwiftUI
import UserNotifications

// An agent registered by an older install may briefly use its cached command
// during upgrade. Never let that command create a window or a second watcher.
@main
private enum GlassEntryPoint {
    @MainActor static func main() {
        guard !CommandLine.arguments.contains("--background-worker") else { return }
        if CommandLine.arguments.contains("--use-background-launch-agent") {
            do { try GlassBackgroundService.useLaunchAgent() }
            catch { print("Worker migration failed: \(error)"); exit(1) }
            return
        }
        if CommandLine.arguments.contains("--enable-background-worker") || CommandLine.arguments.contains("--disable-background-worker") {
            do {
                if CommandLine.arguments.contains("--restart-background-worker") { try GlassBackgroundService.setEnabled(false) }
                try GlassBackgroundService.setEnabled(!CommandLine.arguments.contains("--disable-background-worker"))
            }
            catch { print("Worker registration failed: \(error)"); exit(1) }
            print("Worker enabled: \(GlassBackgroundService.isEnabled); approval required: \(GlassBackgroundService.requiresApproval)")
            return
        }
        #if DEBUG
        if runLocalRootRenameCommand() { return }
        if runLocalDataLocationCommand() { return }
        if runCachedDownloadInspection() { return }
        if runSeasonNamingCommand() { return }
        #endif
        GlassApp.main()
    }
}

#if DEBUG
/// A bounded maintenance entry point using the owning app's sandbox and store.
/// Queue writes require the UI process to be closed so its in-memory queue
/// cannot overwrite the saved request.
extension GlassEntryPoint {
    @MainActor static func runLocalRootRenameCommand() -> Bool {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--rename-local-root") else { return false }
        guard args.indices.contains(index + 2) else { print("Supply the torrent hash and desired folder name."); exit(64) }
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "tsmc.glass").contains(where: {
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated
        }) else { print("Close Glass before repairing the local folder name."); exit(1) }
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        Task {
            do {
                let session = try LocalTransmissionSession()
                do {
                    let details = try await session.fetchTorrentDetails(hashString: args[index + 1])
                    try await session.renamePath(id: args[index + 1], path: details.name, name: args[index + 2])
                    print("Renamed download folder to \(args[index + 2]).")
                    await session.shutdown()
                    exit(0)
                } catch {
                    await session.shutdown()
                    throw error
                }
            } catch { print(error.localizedDescription); exit(1) }
        }
        application.run()
        return true
    }

    @MainActor static func runLocalDataLocationCommand() -> Bool {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--locate-local-data") else { return false }
        guard args.indices.contains(index + 2) else {
            print("Supply the torrent hash and existing folder path."); exit(64)
        }
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "tsmc.glass").contains(where: {
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated
        }) else { print("Close Glass before locating local data."); exit(1) }
        let hash = args[index + 1], folder = args[index + 2]
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        Task {
            do {
                let session = try LocalTransmissionSession()
                do {
                    try await session.locateData(id: hash, at: folder)
                    print("Checking existing pieces in \(folder). Both folders are preserved.")
                    try await Task.sleep(for: .seconds(1))
                    let deadline = ContinuousClock.now.advanced(by: .seconds(300))
                    while true {
                        let details = try await session.fetchTorrentDetails(hashString: hash)
                        if details.status != TransmissionTorrentStatus.checkQueued.rawValue && details.status != TransmissionTorrentStatus.checking.rawValue {
                            guard details.files.contains(where: { $0.bytesCompleted > 0 }) else {
                                throw NSError(domain: "GlassLocation", code: 2,
                                    userInfo: [NSLocalizedDescriptionKey: "No matching pieces were found. The transfer is paused and both folders are preserved."])
                            }
                            print("Verified location: \(details.downloadDir ?? "")/\(details.name)")
                            break
                        }
                        guard ContinuousClock.now < deadline else {
                            throw NSError(domain: "GlassLocation", code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "Verification did not finish; the transfer remains paused."])
                        }
                        try await Task.sleep(for: .seconds(1))
                    }
                    if args.contains("--resume") { try await session.start(ids: [hash]) }
                    await session.shutdown()
                    exit(0)
                } catch {
                    await session.shutdown()
                    throw error
                }
            } catch { print("Location recovery failed: \(error.localizedDescription)"); exit(1) }
        }
        application.run()
        return true
    }

    @MainActor static func runCachedDownloadInspection() -> Bool {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--inspect-cached-download"), args.indices.contains(index + 1) else { return false }
        do {
            let store = try FileProfileStore.applicationSupportStore()
            let names = try store.loadTorrentDisplayNames()
            for source in try store.loadTorrentCache() {
                for torrent in source.torrents {
                    let stored = names[TorrentRecord.identity(sourceID: source.profileID, hashString: torrent.hashString)]
                    guard torrent.name.localizedCaseInsensitiveContains(args[index + 1]) || stored?.displayName.localizedCaseInsensitiveContains(args[index + 1]) == true else { continue }
                    print("Root: \(torrent.name); display: \(stored?.displayName ?? torrent.name); directory: \(torrent.downloadDir ?? "unknown"); hash: \(torrent.hashString)")
                }
            }
        } catch { print("Cache inspection failed: \(error.localizedDescription)"); exit(1) }
        return true
    }

    @MainActor static func runSeasonNamingCommand() -> Bool {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--repair-season-file-names") else { return false }
        do {
            guard arguments.indices.contains(index + 2), let number = Int(arguments[index + 2]) else {
                throw NSError(domain: "GlassNaming", code: 1, userInfo: [NSLocalizedDescriptionKey: "Supply series title and season number."])
            }
            let title = TorrentSeriesIdentity.key(for: arguments[index + 1])
            let store = try FileProfileStore.applicationSupportStore()
            let names = try store.loadTorrentDisplayNames()
            let matches = try store.loadTorrentCache().flatMap { cached in
                cached.torrents.compactMap { torrent -> (UUID, TorrentSummary)? in
                    let key = TorrentRecord.identity(sourceID: cached.profileID, hashString: torrent.hashString)
                    let season = names[key]?.season ?? TorrentNameCleaner.seasonDescriptor(for: .init(rootName: torrent.name, files: []))
                    guard season?.season == number, season.map({ TorrentSeriesIdentity.key(for: $0.title) }) == title else { return nil }
                    return (cached.profileID, torrent)
                }
            }
            guard matches.count == 1, let (source, torrent) = matches.first else {
                throw NSError(domain: "GlassNaming", code: 2, userInfo: [NSLocalizedDescriptionKey: "Expected exactly one cached season; found \(matches.count)."])
            }
            let sourceName = try store.loadProfiles().first { $0.id == source }?.name ?? "This Mac"
            print("Target: \(sourceName) / \(torrent.name), season \(number), hash \(torrent.hashString)")
            if arguments.contains("--inspect") {
                let jobs = try store.loadTorrentAddQueue().filter {
                    $0.fileNameRepair == true && $0.sourceID == source && $0.receipt?.hashString == torrent.hashString
                }
                for job in jobs { print("Saved repair: \(job.id), \(job.phase.rawValue), \(job.completedRenames.count) paths completed") }
                return true
            }
            guard !NSRunningApplication.runningApplications(withBundleIdentifier: "tsmc.glass").contains(where: {
                $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated
            }) else {
                throw NSError(domain: "GlassNaming", code: 3, userInfo: [NSLocalizedDescriptionKey: "Close Glass before writing its queue."])
            }
            var queue = try store.loadTorrentAddQueue()
            if let existing = queue.first(where: { $0.fileNameRepair == true && $0.sourceID == source && $0.receipt?.hashString == torrent.hashString }) {
                print("Already queued: \(existing.id)")
            } else {
                let entry = TorrentAddQueueEntry.repairingFileNames(of: torrent, sourceID: source)
                queue.append(entry)
                try store.saveTorrentAddQueue(queue)
                guard try store.loadTorrentAddQueue().contains(where: { $0.id == entry.id }) else {
                    throw NSError(domain: "GlassNaming", code: 4)
                }
                print("Saved repair: \(entry.id). It will retry when this source refreshes.")
            }
        } catch {
            print("Naming repair failed: \(error.localizedDescription)")
            exit(1)
        }
        return true
    }
}
#endif

struct GlassApp: App {
    @NSApplicationDelegateAdaptor(GlassAppDelegate.self) private var appDelegate
    private let platformIntegration: GlassMacPlatformIntegration
    private let updaterController: SPUStandardUpdaterController?
    private let updaterDelegate: GlassUpdaterDelegate?
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: RemoteAppModel

    init() {
        GlassAppearanceDefaults.register()
        ReduceMotion.startObserving()
        let sparklePublicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        if let sparklePublicKey, !sparklePublicKey.isEmpty, !sparklePublicKey.contains("$(") {
            let delegate = GlassUpdaterDelegate()
            // SPUStandardUpdaterController keeps its updater delegate weakly referenced.
            updaterDelegate = delegate
            let controller = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: delegate,
                userDriverDelegate: nil
            )
            updaterController = controller
            GlassUpdateAvailability.shared.setCheckForUpdates {
                controller.updater.checkForUpdates()
            }
        } else {
            updaterDelegate = nil
            // Local builds have no SPARKLE_PUBLIC_ED_KEY injected, so the updater
            // stays off rather than failing to verify anything it downloads.
            updaterController = nil
            GlassUpdateAvailability.shared.setCheckForUpdates(nil)
        }

        platformIntegration = GlassMacPlatformIntegration()
        let model = Self.makeModel()
        _model = State(initialValue: model)
        appDelegate.prepareToTerminate = { await model.shutdownLocalSession() }
    }

    var body: some Scene {
        Window("Glass", id: "main") {
            GlassRootView(model: model, platformIntegration: platformIntegration)
                .frame(minWidth: 680, minHeight: 260)
                .task { await GlassTuningUpdates.shared.refresh() }
                .task { await InstallationReporter.shared.reportCurrentInstallation() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        Task { await GlassTuningUpdates.shared.refresh() }
                        Task { await InstallationReporter.shared.reportCurrentInstallation() }
                    }
                }
        }
        .defaultLaunchBehavior(.automatic)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: GlassAppearanceDefaults.mainWindowSize.width,
                     height: GlassAppearanceDefaults.mainWindowSize.height)
        .windowResizability(.contentMinSize)
        .commands {
            GlassCommands(updaterController: updaterController)
        }

    }

    private static func makeModel() -> RemoteAppModel {
        let profileStore: FileProfileStore
        do {
            profileStore = try FileProfileStore.applicationSupportStore(appName: "Glass")
        } catch {
            let fallback = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("Glass")
                .appendingPathComponent("profiles.json")
            profileStore = FileProfileStore(fileURL: fallback)
        }
        return RemoteAppModel(
            profileStore: profileStore,
            credentialStore: KeychainCredentialStore(),
            initialSourceID: UserDefaults.standard
                .string(forKey: "GlassRoot.selectedSourceID")
                .flatMap(UUID.init(uuidString:)),
            localSessionFactory: {
                do {
                    return try LocalTransmissionSession()
                } catch {
                    return UnavailableLocalTransmissionSession(
                        errorDescription: "Local torrent engine could not start: \(error.localizedDescription)"
                    )
                }
            },
            completionNotifier: GlassCompletionNotificationCenter.shared
        )
    }

}

@MainActor
private final class GlassUpdaterDelegate: NSObject, SPUUpdaterDelegate {
    func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? {
        ["appName", "appVersion", "osVersion"]
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        GlassUpdateAvailability.shared.setAvailable(true)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        GlassUpdateAvailability.shared.setAvailable(false)
    }
}

private struct GlassCommands: Commands {
    let updaterController: SPUStandardUpdaterController?
    @AppStorage("GlassList.showExtensions") private var showExtensions = false
    @AppStorage("GlassList.grid") private var grid = false
    @AppStorage("GlassList.density") private var density = 1
    @AppStorage("GlassList.enableIconView") private var enableIconView = false
    @AppStorage("GlassList.enableCompactView") private var enableCompactView = false
    @FocusedValue(\.glassTuningPresented) private var tuningPresented
    @FocusedValue(\.glassCommandActions) private var actions
    @FocusedValue(\.glassInspectorSearchPresented) private var inspectorSearchPresented
    @FocusedValue(\.glassMainListSearchPresented) private var mainListSearchPresented
    @FocusedValue(\.glassSearchDestination) private var searchDestination
    @FocusedValue(\.glassInspectorSelectAll) private var inspectorSelectAll
    @FocusedValue(\.glassInspectorFileFilterFocused) private var isInspectorFileFilterFocused

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            #if DEBUG
            Toggle(glassText("Tune"), isOn: tuningPresented ?? .constant(false))
                .keyboardShortcut(",", modifiers: .command)
                .disabled(tuningPresented == nil)
            #endif
        }
        CommandGroup(after: .appInfo) {
            if updaterController != nil {
                Button(glassText("Check for Updates…")) {
                    GlassUpdateAvailability.shared.checkForUpdates()
                }
            }
        }

        CommandGroup(after: .toolbar) {
            if enableIconView {
                Button(glassText("Icon View")) { grid = true }.keyboardShortcut("1", modifiers: .command)
                Button(glassText("List View")) { grid = false }.keyboardShortcut("2", modifiers: .command)
            }
            if enableIconView || enableCompactView { Divider() }
            if enableCompactView {
                Button(glassText("Make Smaller")) { density = max(0, density - 1) }.keyboardShortcut("-", modifiers: .command)
                    .disabled(density <= 0)
                Button(glassText("Make Larger")) { density = min(2, density + 1) }.keyboardShortcut("+", modifiers: .command)
                    .disabled(density >= 2)
                Divider()
            }
            Toggle(glassText("Show Extensions"), isOn: $showExtensions)
            Toggle(glassText("Rounded Sizes"), isOn: Binding(
                get: { glassRoundedSizes },
                set: { glassRoundedSizes = $0 }
            ))
        }

        CommandGroup(replacing: .newItem) {
            Button(glassText("Add Magnet...")) {
                actions?.addMagnet()
            }
            .keyboardShortcut("n", modifiers: [.command])
            .disabled(actions == nil)

            Button(glassText("Add Torrent File...")) {
                actions?.addTorrentFile()
            }
            .keyboardShortcut("o", modifiers: [.command])
            .disabled(actions == nil)
        }

        CommandGroup(before: .textEditing) {
            if let inspectorSelectAll {
                Button(glassText("Select All"), action: inspectorSelectAll)
                    .keyboardShortcut("a", modifiers: .command)
            }
            Button(glassText("Find"), action: openSearch)
                .keyboardShortcut("f", modifiers: .command)
                .disabled(!canOpenSearch)
        }

        CommandGroup(after: .newItem) {
            Divider()

            Button(glassText("Paste Magnet Link")) {
                guard let magnet = Self.pasteboardMagnetLink else { return }
                actions?.openMagnet(magnet)
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])
            .disabled(actions == nil || Self.pasteboardMagnetLink == nil)

            Divider()

            Button(glassText("Delete Torrent")) {
                actions?.removeSelectedTorrent(false)
            }
            .keyboardShortcut(.delete, modifiers: [])
            .disabled(actions?.canRemoveSelectedTorrent != true || isInspectorFileFilterFocused == true)

            Button(glassText("Delete Torrent + Data")) {
                actions?.removeSelectedTorrent(true)
            }
            .keyboardShortcut(.delete, modifiers: [.command])
            .disabled(actions?.canRemoveSelectedTorrent != true || isInspectorFileFilterFocused == true)
        }

        CommandGroup(replacing: .help) { }
    }

    private var canOpenSearch: Bool {
        switch searchDestination {
        case .mainList:
            mainListSearchPresented != nil
        case .inspector:
            inspectorSearchPresented != nil
        case nil:
            mainListSearchPresented != nil || inspectorSearchPresented != nil
        }
    }

    private func openSearch() {
        switch searchDestination {
        case .inspector:
            inspectorSearchPresented?.wrappedValue = true
        case .mainList:
            mainListSearchPresented?.wrappedValue = true
        case nil:
            if let mainListSearchPresented {
                mainListSearchPresented.wrappedValue = true
            } else {
                inspectorSearchPresented?.wrappedValue = true
            }
        }
    }

    private static var pasteboardMagnetLink: String? {
        guard let text = NSPasteboard.general.string(forType: .string) else { return nil }
        return normalizedMagnetLink(from: text)
    }
}

@MainActor
private final class GlassAppDelegate: NSObject, NSApplicationDelegate {
    var prepareToTerminate: (@MainActor () async -> Void)?
    private var isTerminating = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let prepareToTerminate else { return .terminateNow }
        guard !isTerminating else { return .terminateLater }
        isTerminating = true
        Task {
            await prepareToTerminate()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        GlassCompletionNotificationCenter.shared.configure()
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleOpenDocuments(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEOpenDocuments)
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSAppleEventManager.shared().removeEventHandler(
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEOpenDocuments)
        )
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationShouldSaveApplicationState(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldRestoreApplicationState(_ sender: NSApplication) -> Bool {
        true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        open(urls, in: application)
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        open(filenames.map(URL.init(fileURLWithPath:)), in: sender)
        sender.reply(toOpenOrPrint: .success)
    }

    @objc
    private func handleOpenDocuments(
        _ event: NSAppleEventDescriptor,
        withReplyEvent replyEvent: NSAppleEventDescriptor
    ) {
        guard let documents = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) else {
            return
        }

        guard documents.numberOfItems > 0 else { return }
        let urls = (1 ... documents.numberOfItems).compactMap { index in
            documents.atIndex(index)?.fileURLValue
        }
        open(urls, in: NSApp)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return false }
        if let window = sender.windows.first(where: { $0.title == "Glass" }) {
            window.makeKeyAndOrderFront(nil)
            sender.activate()
            return false
        }
        return true
    }

    private func open(_ urls: [URL], in application: NSApplication) {
        GlassOpenURLRouter.shared.open(urls)
        revealMainWindow(in: application)
    }

    private func revealMainWindow(in application: NSApplication) {
        application.activate()
        application.windows.first(where: { $0.title == "Glass" })?.makeKeyAndOrderFront(nil)
    }
}
