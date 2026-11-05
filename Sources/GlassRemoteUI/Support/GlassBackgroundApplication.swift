import AppKit
import OSLog

/// The launch agent shares Glass's sandbox identity, so Launch Services can send
/// it open/reopen events. It must finish AppKit launch and dispatch those events,
/// even though it never owns windows. A plain RunLoop leaves a half-launched app
/// that Launch Services can promote into an unresponsive foreground registration.
@MainActor
public final class GlassBackgroundApplication: NSObject, NSApplicationDelegate {
    private var pending: [[URL]] = []
    private var forwarding: Task<Void, Never>?
    private let logger = Logger(subsystem: "tsmc.glass", category: "background-launch")

    public static func run(work: @escaping @MainActor () async -> Void) {
        let application = NSApplication.shared
        let delegate = GlassBackgroundApplication()
        application.delegate = delegate
        _ = application.setActivationPolicy(.prohibited)
        Task { await work() }
        // Keep the delegate alive: NSApplication.delegate is weak.
        withExtendedLifetime(delegate) { application.run() }
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        _ = NSApp.setActivationPolicy(.prohibited)
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        forward([])
        return false
    }

    public func application(_ application: NSApplication, open urls: [URL]) {
        forward(urls)
    }

    public func application(_ sender: NSApplication, openFiles filenames: [String]) {
        forward(filenames.map(URL.init(fileURLWithPath:)))
        sender.reply(toOpenOrPrint: .success)
    }

    private func forward(_ urls: [URL]) {
        _ = NSApp.setActivationPolicy(.prohibited)
        pending.append(urls)
        guard forwarding == nil else { return }
        forwarding = Task {
            defer { forwarding = nil }
            while !pending.isEmpty {
                let urls = pending.removeFirst()
                do { try await openForeground(urls) }
                catch { logger.error("Could not open Glass: \(error.localizedDescription, privacy: .public)") }
            }
        }
    }

    private func openForeground(_ urls: [URL]) async throws {
        let identifier = Bundle.main.bundleIdentifier ?? "tsmc.glass"
        if let foreground = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated }) {
            // Target the window-owning process explicitly. Asking Launch Services
            // to select an existing instance can route straight back to this worker.
            func send(eventClass: AEEventClass = AEEventClass(kCoreEventClass),
                      id: AEEventID, payload: NSAppleEventDescriptor? = nil) throws {
                let event = NSAppleEventDescriptor(eventClass: eventClass, eventID: id,
                    targetDescriptor: NSAppleEventDescriptor(processIdentifier: foreground.processIdentifier),
                    returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
                if let payload { event.setParam(payload, forKeyword: AEKeyword(keyDirectObject)) }
                try event.sendEvent(options: .noReply, timeout: 1)
            }
            if urls.isEmpty { try send(id: AEEventID(kAEReopenApplication)) }
            let files = urls.filter(\.isFileURL)
            if !files.isEmpty {
                let documents = NSAppleEventDescriptor.list()
                for (index, url) in files.enumerated() {
                    documents.insert(NSAppleEventDescriptor(fileURL: url), at: index + 1)
                }
                try send(id: AEEventID(kAEOpenDocuments), payload: documents)
            }
            for url in urls where !url.isFileURL {
                try send(eventClass: AEEventClass(kInternetEventClass), id: AEEventID(kAEGetURL),
                         payload: NSAppleEventDescriptor(string: url.absoluteString))
            }
            foreground.activate()
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        // Await startup before forwarding the next request, so a burst of Finder
        // opens cannot create several foreground processes or lose their URLs.
        if urls.isEmpty {
            _ = try await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
        } else {
            _ = try await NSWorkspace.shared.open(urls, withApplicationAt: Bundle.main.bundleURL, configuration: configuration)
        }
    }
}
