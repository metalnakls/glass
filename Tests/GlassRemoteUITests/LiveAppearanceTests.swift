import AppKit
import SwiftUI
import Testing
@testable import GlassRemoteUI

@Suite("Live appearance")
struct LiveAppearanceTests {
    @MainActor @Test("native window theme changes publish without reopening or scrolling")
    func themeChanges() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let observer = AppearanceView()
        var received: [ColorScheme] = []
        observer.changed = { received.append($0) }
        window.contentView = observer
        window.appearance = NSAppearance(named: .darkAqua)
        observer.refresh()
        #expect(received.last == .dark)
        window.appearance = NSAppearance(named: .aqua)
        observer.refresh()
        #expect(received.last == .light)
        window.appearance = NSAppearance(named: .darkAqua)
        observer.refresh()
        #expect(received.last == .dark)
        window.close()
    }
}
