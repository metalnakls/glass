import AppKit
import Testing
@testable import GlassRemoteUI

@MainActor
struct TorrentHeaderScrollMotionTests {
    @Test("large jumps go directly to the destination header in either direction")
    func skipsCrossedSections() {
        let backdrop = HeaderBackdrop(frame: .init(x: 0, y: 0, width: 500, height: 400))
        backdrop.externallyHosted = true
        let names = ["Queue", "Loading", "Completed"]
        let headers = names.enumerated().map { TorrentStickyHeaders.Header(id: $0.element,
            title: $0.element, index: $0.offset * 10, inset: 16) }
        let hosts = Dictionary(uniqueKeysWithValues: names.map { ($0, TitleHost(title: $0, inset: 16)) })
        let frames = [0, 600, 1200].map { CGRect(x: 0, y: $0, width: 500, height: 47) }
        for (offset, expected) in [(40, "Queue"), (1400, "Completed"), (40, "Queue")] {
            let viewport = CGRect(x: 0, y: offset, width: 500, height: 400)
            let sticky = TorrentStickyHeaders.stickyLayout(frames: frames, viewport: viewport,
                appearance: .init(), releases: [450, 1050, 2400], stickyAllowed: [true, true, true])
            let layout = TorrentStickyHeaderGeometry.displayLayout(frames: frames, viewport: viewport, sticky: sticky)
            backdrop.present(layout: layout, headers: headers, hosts: hosts, viewport: viewport)
            let visible = hosts.filter { $0.value.superview != nil && !$0.value.isHidden }
            #expect(Set(visible.keys) == [expected])
            #expect(visible[expected]?.alphaValue == 1)
            #expect(visible[expected]?.isPinned == true)
            #expect(backdrop.backdropIsActive)
        }
    }

    @Test("scrolling cancels an inline layout animation instead of flying a crossed title into place")
    func interruptsOldLayoutMotion() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .init(x: -2000, y: -2000, width: 500, height: 400),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let backdrop = HeaderBackdrop(frame: .init(x: 0, y: 0, width: 500, height: 400))
        backdrop.externallyHosted = true
        window.contentView = backdrop.pinnedSurface
        window.orderFront(nil)
        let title = TitleHost(title: "Completed", inset: 16)
        let headers = [TorrentStickyHeaders.Header(id: "completed", title: "Completed", index: 0, inset: 16)]
        func present(y: CGFloat, pinned: Bool, animated: Bool) {
            backdrop.present(layout: .init(titles: [.init(index: 0,
                frame: .init(x: 0, y: y, width: 500, height: 47), pinned: pinned)], backdropHeight: 115),
                headers: headers, hosts: ["completed": title], animateInline: animated)
        }
        present(y: 250, pinned: false, animated: false)
        present(y: 150, pinned: false, animated: true)
        try await Task.sleep(for: .milliseconds(30))
        present(y: 20, pinned: true, animated: false)
        try await Task.sleep(for: .milliseconds(20))
        #expect(title.frame.minY == 20)
        #expect(title.alphaValue == 1)
        #expect(title.layer?.animationKeys()?.isEmpty != false)
        #expect(title.layer?.presentation()?.opacity == 1)
    }
}
