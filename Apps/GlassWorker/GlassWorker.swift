import AppKit
import GlassRemoteUI

@main
enum GlassWorker {
    @MainActor static func main() {
        guard GlassBackgroundService.isAvailable else { return }
        let application = NSApplication.shared
        Task { await GlassBackgroundService.run() }
        application.run()
    }
}
