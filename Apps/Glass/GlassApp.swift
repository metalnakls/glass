import AppKit
import GlassRemoteCore
import GlassRemoteServices
import GlassRemoteUI
import SwiftUI

@main
struct GlassApp: App {
    @NSApplicationDelegateAdaptor(GlassAppDelegate.self) private var appDelegate
    @StateObject private var model = Self.makeModel()

    var body: some Scene {
        WindowGroup("Glass", id: "main") {
            GlassRootView(model: model)
                .frame(minWidth: 960, minHeight: 620)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1280, height: 780)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add Magnet...") {
                    NotificationCenter.default.post(name: .glassCommandAddMagnet, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])

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
                Button("Refresh") {
                    NotificationCenter.default.post(name: .glassCommandRefresh, object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command])

                Button("Show Downloading Torrents") {
                    NotificationCenter.default.post(name: .glassCommandToggleDownloadingFilter, object: nil)
                }
                .keyboardShortcut("d", modifiers: [.command])
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
            credentialStore: KeychainCredentialStore()
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
        NotificationCenter.default.post(name: .glassOpenURLs, object: [url])
    }
}

private final class GlassAppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        NotificationCenter.default.post(name: .glassOpenURLs, object: urls)
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map(URL.init(fileURLWithPath:))
        NotificationCenter.default.post(name: .glassOpenURLs, object: urls)
        sender.reply(toOpenOrPrint: .success)
    }
}
