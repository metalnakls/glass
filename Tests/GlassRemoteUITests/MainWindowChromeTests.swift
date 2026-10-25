@testable import GlassRemoteUI
import AppKit
import Testing

@Suite("Main window titlebar drag")
@MainActor
struct MainWindowChromeTests {
    @Test("native titlebar band captures drag while content below passes through")
    func titlebarHitTestingAndDrag() throws {
        try exerciseTitlebarHitTesting(isFlipped: false)
        try exerciseTitlebarHitTesting(isFlipped: true)
    }

    private func exerciseTitlebarHitTesting(isFlipped: Bool) throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let contentView = FixtureContentView(frame: NSRect(x: 0, y: 0, width: 900, height: 600), isFlipped: isFlipped)
        contentView.autoresizingMask = [.width, .height]
        contentView.setBoundsOrigin(NSPoint(x: 17, y: 29))
        window.contentView = contentView
        let anchor = MainWindowChrome.Anchor(frame: contentView.bounds)
        contentView.addSubview(anchor)
        anchor.configureWindow()
        let overlay = try #require(contentView.subviews.compactMap { $0 as? TitlebarDragOverlay }.first)

        let band = overlay.titlebarBand()
        #expect(band.height > 0)
        let titlebarPoint = NSPoint(x: band.midX, y: band.midY)
        let titlebarPointInWindow = overlay.convert(titlebarPoint, to: nil)
        #expect(window.contentView?.hitTest(titlebarPointInWindow) === overlay)
        let contentPoint = NSPoint(x: titlebarPoint.x, y: isFlipped ? band.maxY + 1 : band.minY - 1)
        #expect(window.contentView?.hitTest(overlay.convert(contentPoint, to: nil)) !== overlay)

        var didPerformDrag = false
        overlay.performDrag = { receivedWindow, _ in
            didPerformDrag = receivedWindow === window
        }
        let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: titlebarPointInWindow,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        )!
        overlay.mouseDown(with: event)
        #expect(didPerformDrag)

        window.setFrame(NSRect(x: 0, y: 0, width: 1100, height: 700), display: false)
        NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: window)
        #expect(overlay.frame.size == contentView.bounds.size)
    }

    @Test("fullscreen and sheet windows do not receive the titlebar drag overlay")
    func excludesFullscreenAndSheets() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        #expect(TitlebarDragOverlay.shouldInstall(in: window))
        #expect(!TitlebarDragOverlay.shouldInstall(isSheet: false, isFullscreen: true))
        #expect(!TitlebarDragOverlay.shouldInstall(isSheet: true, isFullscreen: false))

        let sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.beginSheet(sheet, completionHandler: nil)
        #expect(sheet.sheetParent === window)
        #expect(!TitlebarDragOverlay.shouldInstall(in: sheet))
        window.endSheet(sheet)
    }
}

private final class FixtureContentView: NSView {
    let fixtureIsFlipped: Bool

    init(frame: NSRect, isFlipped: Bool) {
        fixtureIsFlipped = isFlipped
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { fixtureIsFlipped }
}
