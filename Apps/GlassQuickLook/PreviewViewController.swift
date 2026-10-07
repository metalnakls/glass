import AppKit
import GlassRemoteUI
import Quartz
import SwiftUI

@MainActor
final class PreviewViewController: NSViewController, QLPreviewingController {
    override func loadView() { view = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 560)) }
    nonisolated func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        let completion = PreviewCompletion(call: handler)
        Task { @MainActor [weak self] in
        guard let self else { completion.call(CocoaError(.userCancelled)); return }
        let host = NSHostingView(rootView: GlassTorrentQuickLookView(url: url))
        host.frame = view.bounds
        host.autoresizingMask = [.width, .height]
        view.subviews.forEach { $0.removeFromSuperview() }
        view.addSubview(host)
        preferredContentSize = NSSize(width: 720, height: 560)
        completion.call(nil)
        }
    }
}

private struct PreviewCompletion: @unchecked Sendable { let call: (Error?) -> Void }
