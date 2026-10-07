import AppKit
import GlassRemoteCore
import GlassRemoteServices
import GlassRemoteUI
import Sparkle
import SwiftUI
import UserNotifications

@main
struct GlassApp: App {
    @NSApplicationDelegateAdaptor(GlassAppDelegate.self) private var appDelegate
    private let platformIntegration: GlassMacPlatformIntegration
    private let updaterController: SPUStandardUpdaterController?
    private let updaterDelegate: GlassUpdaterDelegate?
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: RemoteAppModel?

    init() {
        GlassAppearanceDefaults.register()
        ReduceMotion.startObserving()
        let sparklePublicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        if !GlassBackgroundService.isWorker, let sparklePublicKey, !sparklePublicKey.isEmpty, !sparklePublicKey.contains("$(") {
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
        _model = State(initialValue: GlassBackgroundService.isWorker ? nil : Self.makeModel())
    }

    var body: some Scene {
        Window("Glass", id: "main") {
            if let model {
            GlassRootView(model: model, platformIntegration: platformIntegration)
                .frame(minWidth: 680, minHeight: 260)
                .task { await GlassTuningUpdates.shared.refresh() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await GlassTuningUpdates.shared.refresh() } }
                }
            }
        }
        .defaultLaunchBehavior(GlassBackgroundService.isWorker ? .suppressed : .presented)
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
            Menu(glassText("Tune")) {
                Toggle(glassText("Enabled"), isOn: tuningPresented ?? .constant(false))
                    .keyboardShortcut(",", modifiers: .command)
                    .disabled(tuningPresented == nil)
                Button(glassText("Test Torrents…")) { TorrentTestWindow.show() }
                    .keyboardShortcut(",", modifiers: [.command, .shift])
            }
            #endif
        }
        CommandGroup(after: .appInfo) {
            if let updaterController {
                Button(glassText("Check for Updates…")) {
                    updaterController.updater.checkForUpdates()
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
    func applicationWillFinishLaunching(_ notification: Notification) {
        if GlassBackgroundService.isWorker {
            NSApp.setActivationPolicy(.prohibited)
            Task { await GlassBackgroundService.run() }
        }
        UNUserNotificationCenter.current().delegate = GlassCompletionNotificationCenter.shared
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

@MainActor
private final class GlassCompletionNotificationCenter: NSObject, TorrentCompletionNotifying,
    UNUserNotificationCenterDelegate
{
    static let shared = GlassCompletionNotificationCenter()

    private let center = UNUserNotificationCenter.current()
    private var didRequestAuthorization = false
    private var completedDownloadCount = 0

    func requestAuthorization() {
        guard !didRequestAuthorization else { return }
        didRequestAuthorization = true
        Task {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
    }

    func notifyTorrentCompleted(name: String) {
        completedDownloadCount += 1
        NSApp.dockTile.badgeLabel = completedDownloadCount.formatted()

        Task {
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                return
            }

            let content = UNMutableNotificationContent()
            content.title = glassText("Download Complete")
            content.body = name
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "torrent-completed-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            try? await center.add(request)
        }
    }

    func clearBadge() {
        completedDownloadCount = 0
        NSApp.dockTile.badgeLabel = nil
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
