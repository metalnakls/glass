import AppKit
import GlassRemoteServices
import OSLog
import SwiftUI
import UserNotifications

/// Completion delivery and per-download acknowledgement share one owner in the
/// foreground app and worker. Notification Center retains unread state across launches.
@MainActor
public final class GlassCompletionNotificationCenter: NSObject, TorrentCompletionNotifying, UNUserNotificationCenterDelegate {
    public static let shared = GlassCompletionNotificationCenter()
    nonisolated static let category = "glass-download-completed"
    nonisolated static let openAction = "glass-open-download"
    private let center = UNUserNotificationCenter.current()
    private var didRequestAuthorization = false
    private var configured = false
    private var visibleRows: [UUID: Set<String>] = [:]
    private var operation: Task<Void, Never>?

    public func configure() {
        guard !configured else { return }
        configured = true
        center.delegate = self
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.category,
            actions: [UNNotificationAction(identifier: Self.openAction, title: "Open", options: [])],
            intentIdentifiers: [], options: [.customDismissAction])])
        if !GlassBackgroundService.isWorker {
            NotificationCenter.default.addObserver(self, selector: #selector(acknowledgeVisible),
                name: NSApplication.didBecomeActiveNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(acknowledgeVisible),
                name: NSWindow.didBecomeKeyNotification, object: nil)
            serialize { await self.updateBadge() }
        }
    }

    public func requestAuthorization() {
        configure()
        guard !didRequestAuthorization else { return }
        didRequestAuthorization = true
        Task { _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge]) }
    }

    static func title(name: String, displayName: String, fileCount: Int?, showsExtensions: Bool) -> String {
        guard !showsExtensions, fileCount.map({ $0 <= 1 }) ?? true else { return displayName }
        return TorrentExtensionPolicy.name(displayName, hiding: TorrentExtensionPolicy.hiddenExtension(paths: [name]))
    }

    public func notifyTorrentCompleted(name: String) { enqueue(title: name, payload: [:]) }
    public func notifyTorrentCompleted(name: String, sourceID: UUID, hashString: String, downloadDirectory: String?) {
        notifyTorrentCompleted(name: name, displayName: name, fileCount: nil, filePath: nil,
            sourceID: sourceID, hashString: hashString, downloadDirectory: downloadDirectory)
    }
    public func notifyTorrentCompleted(name: String, displayName: String, fileCount: Int?, filePath: String?, sourceID: UUID, hashString: String, downloadDirectory: String?) {
        enqueue(title: Self.title(name: name, displayName: displayName, fileCount: fileCount,
            showsExtensions: UserDefaults.standard.bool(forKey: "GlassList.showExtensions")),
            payload: ["name": name, "path": filePath ?? name, "sourceID": sourceID.uuidString, "hashString": hashString,
                      "directory": downloadDirectory ?? ""])
    }

    private func enqueue(title: String, payload: [String: String]) {
        configure()
        serialize {
            let content = UNMutableNotificationContent()
            // Filenames never inherit Tune's lowercase interface-label styling.
            content.title = "Download Complete"
            content.body = title
            content.userInfo = payload
            content.categoryIdentifier = Self.category
            content.sound = .default
            let identifier = Self.key(payload).map { "completed-" + $0 } ?? UUID().uuidString
            do {
                try await self.center.add(.init(identifier: identifier, content: content, trigger: nil))
            } catch {
                Logger(subsystem: "tsmc.glass", category: "notifications")
                    .error("Completion notification delivery failed: \(error.localizedDescription, privacy: .public)")
            }
            // Let the new system alert appear. Seen foreground completions omit
            // Notification Center retention in willPresent instead of retracting it.
            await self.remove(keys: self.activeVisibleKeys, excluding: [identifier])
            await self.updateBadge()
        }
    }

    public func clearBadge() {
        // Kept for protocol compatibility; activation must acknowledge visible items only.
        acknowledgeVisible()
    }

    func setVisible(_ keys: Set<String>, owner: UUID, visible: Bool) {
        configure()
        visibleRows[owner] = visible ? keys : nil
        acknowledgeVisible()
    }

    private var activeVisibleKeys: Set<String> {
        guard NSApp?.isActive == true, NSApp?.keyWindow?.isVisible == true,
              NSApp?.keyWindow?.title == "Glass", NSApp?.keyWindow?.isMiniaturized == false else { return [] }
        return Set(visibleRows.values.flatMap { $0 })
    }
    @objc private func acknowledgeVisible() {
        let keys = activeVisibleKeys
        guard !keys.isEmpty else { return }
        serialize { await self.remove(keys: keys); await self.updateBadge() }
    }
    nonisolated static func key(_ payload: [AnyHashable: Any]) -> String? {
        guard let source = payload["sourceID"] as? String,
              let hash = payload["hashString"] as? String else { return nil }
        return source + ":" + hash
    }
    private func remove(keys: Set<String>, excluding: Set<String> = []) async {
        guard !keys.isEmpty else { return }
        let notifications = await center.deliveredNotifications()
        let ids = Self.identifiersToClear(requests: notifications.map(\.request), keys: keys, excluding: excluding)
        center.removeDeliveredNotifications(withIdentifiers: ids)
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }
    static func identifiersToClear(requests: [UNNotificationRequest], keys: Set<String>, excluding: Set<String> = []) -> [String] {
        requests.filter {
            !excluding.contains($0.identifier) && (Self.key($0.content.userInfo).map(keys.contains) ?? false)
        }.map(\.identifier)
    }
    static func unreadCount(requests: [UNNotificationRequest], visibleKeys: Set<String>) -> Int {
        requests.filter {
            let key = Self.key($0.content.userInfo)
            return ($0.content.categoryIdentifier == Self.category || key != nil) &&
                !(key.map(visibleKeys.contains) ?? false)
        }.count
    }
    private func updateBadge() async {
        let requests = await center.deliveredNotifications().map(\.request)
        let count = Self.unreadCount(requests: requests, visibleKeys: activeVisibleKeys)
        if !GlassBackgroundService.isWorker {
            NSApp?.dockTile.badgeLabel = count == 0 ? nil : count.formatted()
        }
        try? await center.setBadgeCount(count)
    }
    private func serialize(_ work: @escaping @MainActor () async -> Void) {
        let previous = operation
        operation = Task { await previous?.value; await work() }
    }

    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        guard action == Self.openAction || action == UNNotificationDefaultActionIdentifier || action == UNNotificationDismissActionIdentifier else { return }
        let payload = response.notification.request.content.userInfo
        var opened = false
        if action != UNNotificationDismissActionIdentifier,
           let sourceText = payload["sourceID"] as? String, let sourceID = UUID(uuidString: sourceText),
           let name = payload["name"] as? String, let directory = payload["directory"] as? String, !directory.isEmpty {
            opened = await glassOpenCompletedTorrent(sourceID: sourceID, directory: directory, name: payload["path"] as? String ?? name,
                isLocal: sourceText == "00000000-0000-0000-0000-000000000001")
        }
        let identifier = response.notification.request.identifier
        await MainActor.run {
            self.serialize {
                self.center.removeDeliveredNotifications(withIdentifiers: [identifier])
                await self.updateBadge()
            }
            if !opened, action != UNNotificationDismissActionIdentifier {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
            }
        }
    }
    nonisolated static func presentationOptions(isVisible: Bool) -> UNNotificationPresentationOptions {
        isVisible ? [.banner, .sound] : [.banner, .list, .sound]
    }

    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let key = Self.key(notification.request.content.userInfo)
        let seen = await MainActor.run { key.map(self.activeVisibleKeys.contains) ?? false }
        return Self.presentationOptions(isVisible: seen)
    }
}

/// Native List does not emit SwiftUI scroll-visibility callbacks. Measure the
/// existing row's clipped rectangle; the probe never owns layout or input.
struct CompletionVisibility: ViewModifier {
    let keys: Set<String>
    var report: @MainActor (Set<String>, UUID, Bool) -> Void = {
        GlassCompletionNotificationCenter.shared.setVisible($0, owner: $1, visible: $2)
    }
    func body(content: Content) -> some View {
        content.background(CompletionVisibilityProbe(keys: keys, report: report))
    }
}

private struct CompletionVisibilityProbe: NSViewRepresentable {
    let keys: Set<String>
    let report: @MainActor (Set<String>, UUID, Bool) -> Void
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {
        view.keys = keys
        view.report = report
        view.observeViewport()
        view.updateVisibility()
    }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.detach() }

    final class Probe: NSView {
        let owner = UUID()
        var keys: Set<String> = []
        var report: (@MainActor (Set<String>, UUID, Bool) -> Void)?
        private weak var clip: NSClipView?
        private var lastKeys: Set<String> = []
        private var wasVisible = false
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observeViewport()
            updateVisibility()
        }
        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            observeViewport()
            updateVisibility()
        }
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            observeViewport()
            updateVisibility()
        }
        override func setFrameOrigin(_ newOrigin: NSPoint) {
            super.setFrameOrigin(newOrigin)
            updateVisibility()
        }
        func observeViewport() {
            let next = enclosingScrollView?.contentView
            guard clip !== next else { return }
            NotificationCenter.default.removeObserver(self)
            clip = next
            guard let next else { return }
            next.postsBoundsChangedNotifications = true
            next.postsFrameChangedNotifications = true
            for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(updateVisibility), name: name, object: next)
            }
            if let document = next.documentView {
                document.postsFrameChangedNotifications = true
                NotificationCenter.default.addObserver(self, selector: #selector(updateVisibility),
                    name: NSView.frameDidChangeNotification, object: document)
            }
        }
        @objc func updateVisibility() {
            let area = bounds.width * bounds.height
            let rect = clip.map { convert(bounds, to: $0).intersection($0.bounds) } ?? .zero
            let shown = window?.isVisible == true && !isHiddenOrHasHiddenAncestor &&
                area > 0 && rect.width * rect.height >= area * 0.5
            guard shown != wasVisible || keys != lastKeys else { return }
            wasVisible = shown
            lastKeys = keys
            report?(keys, owner, shown)
        }
        func detach() {
            NotificationCenter.default.removeObserver(self)
            report?(keys, owner, false)
            clip = nil
            report = nil
        }
        isolated deinit { NotificationCenter.default.removeObserver(self) }
    }
}
