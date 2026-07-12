import AppKit
import GlassRemoteCore
import GlassRemoteServices
import GlassRemoteUI
import SwiftUI

@main
struct GlassApp: App {
    @NSApplicationDelegateAdaptor(GlassAppDelegate.self) private var appDelegate
    @State private var model = Self.makeModel()

    var body: some Scene {
        WindowGroup("Glass", id: "main") {
            GlassRootView(model: model)
                .frame(minWidth: 560, minHeight: 260)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 760, height: 460)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Server...") {
                    NotificationCenter.default.post(name: .glassCommandAddServer, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Divider()

                Button("Add Magnet...") {
                    NotificationCenter.default.post(name: .glassCommandAddMagnet, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command])

                Button("Add Torrent File...") {
                    NotificationCenter.default.post(name: .glassCommandAddTorrentFile, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command])
            }

            CommandGroup(replacing: .pasteboard) {
                Button("Paste Magnet Link") {
                    pasteMagnetLink()
                }
                .keyboardShortcut("v", modifiers: [.command])
            }

            CommandMenu("Torrent") {
                Button("Show Downloading Torrents") {
                    NotificationCenter.default.post(name: .glassCommandToggleDownloadingFilter, object: nil)
                }
                .keyboardShortcut("d", modifiers: [.command])

                Divider()

                Button("Remove Torrent") {
                    NotificationCenter.default.post(name: .glassCommandRemoveSelectedTorrent, object: nil)
                }
                .keyboardShortcut(.delete, modifiers: [])

                Button("Remove and Delete Data") {
                    NotificationCenter.default.post(name: .glassCommandRemoveSelectedTorrentAndData, object: nil)
                }
                .keyboardShortcut(.delete, modifiers: [.command])
            }
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

    private func pasteMagnetLink() {
        guard
            let text = NSPasteboard.general.string(forType: .string)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            text.range(of: "magnet:?", options: [.anchored, .caseInsensitive]) != nil,
            let url = URL(string: text)
        else {
            return
        }
        Task { @MainActor in
            GlassOpenURLRouter.shared.open([url])
        }
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
        }
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map(URL.init(fileURLWithPath:))
        Task { @MainActor in
            GlassOpenURLRouter.shared.open(urls)
        }
        sender.reply(toOpenOrPrint: .success)
    }
}
