import AppKit
import GlassRemoteServices
import OSLog
import SwiftUI
import UserNotifications

/// Completion delivery and per-download acknowledgement share one owner in the
/// foreground app and worker. Read acknowledgements survive Notification Center replay.
@MainActor
public final class GlassCompletionNotificationCenter: NSObject, TorrentCompletionNotifying, UNUserNotificationCenterDelegate {
    public static let shared = GlassCompletionNotificationCenter()
    nonisolated static let category = "glass-download-completed"
    nonisolated static let openAction = "glass-open-download"
    private let center = UNUserNotificationCenter.current()
    private let deliveries = CompletionDeliveries(defaults: .standard)
    private let acknowledgements = CompletionAcknowledgements(defaults: .standard)
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
        }
        serialize {
            let delivered = await self.center.deliveredNotifications().map(\.request)
            delivered.forEach { self.deliveries.record($0) }
            if !GlassBackgroundService.isWorker { await self.updateBadge(clearAcknowledged: true) }
        }
    }

    public func prepareForNewDownload(sourceID: UUID, hashString: String) {
        configure()
        let key = sourceID.uuidString + ":" + hashString
        serialize {
            self.deliveries.reset(key: key)
            self.acknowledgements.reset(key: key)
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
        notifyTorrentCompleted(name: name, displayName: displayName, fileCount: fileCount, filePath: filePath,
            sourceID: sourceID, hashString: hashString, downloadDirectory: downloadDirectory, completionDate: nil)
    }
    public func notifyTorrentCompleted(name: String, displayName: String, fileCount: Int?, filePath: String?, sourceID: UUID, hashString: String, downloadDirectory: String?, completionDate: Int?) {
        enqueue(title: Self.title(name: name, displayName: displayName, fileCount: fileCount,
            showsExtensions: UserDefaults.standard.bool(forKey: "GlassList.showExtensions")),
            payload: ["name": name, "path": filePath ?? name, "sourceID": sourceID.uuidString, "hashString": hashString,
                      "directory": downloadDirectory ?? "",
                      "completedAt": completionDate.flatMap { $0 > 0 ? String($0) : nil } ?? ""])
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
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
            guard !self.deliveries.contains(request), !self.acknowledgements.contains(request) else {
                await self.updateBadge()
                return
            }
            do {
                try await self.center.add(request)
                self.deliveries.record(request)
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
        acknowledgements.acknowledge(notifications.map(\.request).filter { ids.contains($0.identifier) })
        center.removeDeliveredNotifications(withIdentifiers: ids)
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }
    static func identifiersToClear(requests: [UNNotificationRequest], keys: Set<String>, excluding: Set<String> = []) -> [String] {
        requests.filter {
            !excluding.contains($0.identifier) && (Self.key($0.content.userInfo).map(keys.contains) ?? false)
        }.map(\.identifier)
    }
    static func unreadCount(requests: [UNNotificationRequest], visibleKeys: Set<String>, acknowledgements: CompletionAcknowledgements? = nil) -> Int {
        requests.filter {
            let key = Self.key($0.content.userInfo)
            return ($0.content.categoryIdentifier == Self.category || key != nil) &&
                !(key.map(visibleKeys.contains) ?? false) && !(acknowledgements?.contains($0) ?? false)
        }.count
    }
    private func updateBadge(clearAcknowledged: Bool = false) async {
        let requests = await center.deliveredNotifications().map(\.request)
        if clearAcknowledged {
            let readIDs = requests.filter { acknowledgements.contains($0) }.map(\.identifier)
            center.removeDeliveredNotifications(withIdentifiers: readIDs)
            center.removePendingNotificationRequests(withIdentifiers: readIDs)
        }
        let count = Self.unreadCount(requests: requests, visibleKeys: activeVisibleKeys, acknowledgements: acknowledgements)
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
        let readKey = Self.key(payload)
        let completedAt = CompletionAcknowledgements.completedAt(response.notification.request)
        await MainActor.run {
            self.serialize {
                if let readKey { self.acknowledgements.acknowledge(key: readKey, completedAt: completedAt) }
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
        let completedAt = CompletionAcknowledgements.completedAt(notification.request)
        let seen = await MainActor.run {
            let seen = key.map(self.activeVisibleKeys.contains) ?? false
            if seen, let key { self.acknowledgements.acknowledge(key: key, completedAt: completedAt) }
            return seen
        }
        return Self.presentationOptions(isVisible: seen)
    }
}

/// Persist only source/hash read watermarks, shared by the app and worker.
@MainActor
struct CompletionAcknowledgements {
    let defaults: UserDefaults
    private let storageKey = "GlassCompletion.readThrough"

    func acknowledge(_ requests: [UNNotificationRequest], at date: Date = Date()) {
        for request in requests {
            guard let key = GlassCompletionNotificationCenter.key(request.content.userInfo) else { continue }
            acknowledge(key: key, completedAt: Self.completedAt(request), at: date)
        }
    }

    func acknowledge(key: String, completedAt: Double?, at date: Date = Date()) {
        let preference = storageKey + "." + key
        let watermark = max(defaults.double(forKey: preference), date.timeIntervalSince1970, completedAt ?? 0)
        defaults.set(watermark, forKey: preference)
    }

    func reset(key: String) {
        defaults.removeObject(forKey: storageKey + "." + key)
    }

    nonisolated static func completedAt(_ request: UNNotificationRequest) -> Double? {
        guard let value = request.content.userInfo["completedAt"] as? String,
              let timestamp = Double(value), timestamp.isFinite, timestamp > 0 else { return nil }
        return timestamp
    }

    func contains(_ request: UNNotificationRequest) -> Bool {
        guard let key = GlassCompletionNotificationCenter.key(request.content.userInfo) else { return false }
        // Read preferences on demand so a worker's acknowledgement is visible too.
        let watermark = defaults.double(forKey: storageKey + "." + key)
        guard watermark > 0 else { return false }
        // Older notifications have no event date. A saved read acknowledgement
        // still retires them; newly created requests always carry completedAt.
        return Self.completedAt(request).map { $0 <= watermark } ?? true
    }
}

/// Delivery is independent of read state: an unread alert must not be sent
/// again at every launch. Seed this history from existing delivered requests.
@MainActor
struct CompletionDeliveries {
    let defaults: UserDefaults
    private let prefix = "GlassCompletion.deliveredThrough."

    func contains(_ request: UNNotificationRequest) -> Bool {
        guard let key = GlassCompletionNotificationCenter.key(request.content.userInfo),
              let watermark = defaults.object(forKey: prefix + key) as? Double else { return false }
        return CompletionAcknowledgements.completedAt(request).map { $0 <= watermark } ?? true
    }

    func record(_ request: UNNotificationRequest, at date: Date = Date()) {
        guard let key = GlassCompletionNotificationCenter.key(request.content.userInfo) else { return }
        let timestamp = CompletionAcknowledgements.completedAt(request) ?? date.timeIntervalSince1970
        defaults.set(max(timestamp, defaults.double(forKey: prefix + key)), forKey: prefix + key)
    }

    func reset(key: String) { defaults.removeObject(forKey: prefix + key) }
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
