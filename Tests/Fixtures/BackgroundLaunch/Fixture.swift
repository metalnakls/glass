import AppKit

@MainActor
private func record(_ text: String) {
    let root = Bundle.main.bundleURL.deletingLastPathComponent()
    let url = root.appendingPathComponent("events")
    let previous = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    try! (previous + text + "\n").write(to: url, atomically: true, encoding: .utf8)
}

@MainActor
private final class Foreground: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 320, height: 100),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window?.title = "Glass launch regression fixture"
        window?.makeKeyAndOrderFront(nil)
        record("foreground:\(ProcessInfo.processInfo.processIdentifier)")
    }
    func application(_ app: NSApplication, open urls: [URL]) {
        for url in urls { record("url:\(url.resolvingSymlinksInPath().absoluteString)") }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window?.makeKeyAndOrderFront(nil)
        record("reopen")
        return false
    }
}

@main
private enum Fixture {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--worker") {
            GlassBackgroundApplication.run {
                let file = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("icon-file")
                try! Data("fixture".utf8).write(to: file)
                _ = NSWorkspace.shared.setIcon(NSWorkspace.shared.icon(for: .movie), forFile: file.path, options: [])
                record("worker:\(ProcessInfo.processInfo.processIdentifier)")
            }
        } else {
            let delegate = Foreground()
            NSApplication.shared.delegate = delegate
            withExtendedLifetime(delegate) { NSApplication.shared.run() }
        }
    }
}
