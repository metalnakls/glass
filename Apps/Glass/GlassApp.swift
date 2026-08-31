import AppKit
import GlassRemoteCore
import GlassRemoteServices
import GlassRemoteUI
import SwiftUI
import UserNotifications

@main
struct GlassApp: App {
    @NSApplicationDelegateAdaptor(GlassAppDelegate.self) private var appDelegate
    private let platformIntegration: GlassMacPlatformIntegration
    @State private var model: RemoteAppModel

    init() {
        platformIntegration = GlassMacPlatformIntegration()
        _model = State(initialValue: Self.makeModel())
    }

    var body: some Scene {
        Window("Glass", id: "main") {
            GlassRootView(model: model, platformIntegration: platformIntegration)
                .frame(minWidth: 820, minHeight: 260)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1020, height: 460)
        .commands {
            GlassCommands()
            ToolbarCommands()
        }

        Settings {
            PreferencesView(model: model)
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

private struct GlassCommands: Commands {
    @FocusedValue(\.glassCommandActions) private var actions
    @FocusedValue(\.glassInspectorFileFilterFocused) private var isInspectorFileFilterFocused

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Server...") {
                actions?.addServer()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(actions == nil)

            Divider()

            Button("Add Magnet...") {
                actions?.addMagnet()
            }
            .keyboardShortcut("n", modifiers: [.command])
            .disabled(actions == nil)

            Button("Add Torrent File...") {
                actions?.addTorrentFile()
            }
            .keyboardShortcut("o", modifiers: [.command])
            .disabled(actions == nil)
        }

        CommandGroup(after: .pasteboard) {
            Divider()

            Button("Paste Magnet Link") {
                guard let magnet = Self.pasteboardMagnetLink else { return }
                actions?.openMagnet(magnet)
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])
            .disabled(actions == nil || Self.pasteboardMagnetLink == nil)
        }

        CommandMenu("Torrent") {
            Button(actions?.isDownloadingFilterActive == true ? "Show All Torrents" : "Show Downloading Torrents") {
                actions?.toggleDownloadingFilter()
            }
            .keyboardShortcut("d", modifiers: [.command])
            .disabled(actions == nil)

            Divider()

            Button("Delete Torrent") {
                actions?.removeSelectedTorrent(false)
            }
            .keyboardShortcut(.delete, modifiers: [])
            .disabled(actions?.canRemoveSelectedTorrent != true || isInspectorFileFilterFocused == true)

            Button("Delete Torrent + Data") {
                actions?.removeSelectedTorrent(true)
            }
            .keyboardShortcut(.delete, modifiers: [.command])
            .disabled(actions?.canRemoveSelectedTorrent != true || isInspectorFileFilterFocused == true)
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
            content.title = "Download Complete"
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
