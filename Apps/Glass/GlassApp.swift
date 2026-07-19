import AppKit
import GlassRemoteCore
import GlassRemoteServices
import GlassRemoteUI
import SwiftUI

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
                .frame(minWidth: 560, minHeight: 260)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 760, height: 460)
        .commands {
            GlassCommands()
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
            }
        )
    }

}

private struct GlassCommands: Commands {
    @FocusedValue(\.glassCommandActions) private var actions

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

            Button("Remove Torrent") {
                actions?.removeSelectedTorrent(false)
            }
            .disabled(actions?.canRemoveSelectedTorrent != true)

            Button("Remove and Delete Data") {
                actions?.removeSelectedTorrent(true)
            }
            .disabled(actions?.canRemoveSelectedTorrent != true)
        }
    }

    private static var pasteboardMagnetLink: String? {
        guard let text = NSPasteboard.general.string(forType: .string) else { return nil }
        return normalizedMagnetLink(from: text)
    }
}

private final class GlassAppDelegate: NSObject, NSApplicationDelegate {
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
        Task { @MainActor in
            GlassOpenURLRouter.shared.open(urls)
            revealMainWindow(in: application)
        }
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map(URL.init(fileURLWithPath:))
        Task { @MainActor in
            GlassOpenURLRouter.shared.open(urls)
            revealMainWindow(in: sender)
        }
        sender.reply(toOpenOrPrint: .success)
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

    @MainActor
    private func revealMainWindow(in application: NSApplication) {
        application.activate()
        application.windows.first(where: { $0.title == "Glass" })?.makeKeyAndOrderFront(nil)
    }
}
