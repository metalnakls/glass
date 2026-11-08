import AppKit
import GlassRemoteUI

@main
enum GlassWorker {
    @MainActor static func main() {
        guard GlassBackgroundService.isAvailable else { return }
        let application = NSApplication.shared
        let observer = DistributedNotificationCenter.default().addObserver(
            forName: .init("tsmc.glass.worker.enabled"), object: nil, queue: .main) { note in
                guard let value = note.object as? String, ["true", "false"].contains(value) else { return }
                UserDefaults.standard.set(value == "true", forKey: "GlassWorker.enabled")
            }
        defer { DistributedNotificationCenter.default().removeObserver(observer) }
        Task { await GlassBackgroundService.run() }
        application.run()
    }
}
