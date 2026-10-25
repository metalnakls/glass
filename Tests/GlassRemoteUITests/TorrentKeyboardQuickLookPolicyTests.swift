import AppKit
import Foundation
import Testing
@testable import GlassRemoteUI

@MainActor
@Suite("Inspector Space Quick Look policy")
struct TorrentKeyboardQuickLookPolicyTests {
    private let valid = (path: "Movie.mkv", size: UInt64(4), complete: true)

    @Test("native text editing owns Space, including an NSTextView field editor")
    func fieldEditorOwnsSpace() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 100),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let field = NSTextField(frame: CGRect(x: 10, y: 10, width: 200, height: 24))
        field.isEditable = true
        window.contentView?.addSubview(field)
        #expect(TorrentKeyboardQuickLookPolicy.isTextInputFirstResponder(field))
        #expect(window.makeFirstResponder(field))
        let responder = window.firstResponder
        #expect(responder is NSTextView)
        #expect((responder as? NSTextView)?.isFieldEditor == true)
        #expect(!accepts(responder: responder))
    }

    @Test("a normal row responder can request Quick Look")
    func fileRowAllowsSpace() {
        let row = NSView(frame: .zero)
        #expect(accepts(responder: row))
    }

    @Test("root forwarding requires an Inspector action and preserves the originating key window")
    func rootForwardingAndWindowOwnership() {
        _ = NSApplication.shared
        let firstWindow = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: .borderless, backing: .buffered, defer: false)
        let otherWindow = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: .borderless, backing: .buffered, defer: false)
        firstWindow.isReleasedWhenClosed = false
        otherWindow.isReleasedWhenClosed = false
        defer { firstWindow.close(); otherWindow.close() }
        #expect(TorrentKeyboardQuickLookPolicy.mayForwardFromRoot(actionAvailable: true,
            firstResponder: NSView(), keyWindow: firstWindow, applicationIsActive: true))
        #expect(!TorrentKeyboardQuickLookPolicy.mayForwardFromRoot(actionAvailable: false,
            firstResponder: NSView(), keyWindow: firstWindow, applicationIsActive: true))
        #expect(!TorrentKeyboardQuickLookPolicy.mayForwardFromRoot(actionAvailable: true,
            firstResponder: NSTextView(), keyWindow: firstWindow, applicationIsActive: true))
        #expect(TorrentKeyboardQuickLookPolicy.requestStillBelongs(to: firstWindow,
            currentKeyWindow: firstWindow, applicationIsActive: true))
        #expect(!TorrentKeyboardQuickLookPolicy.requestStillBelongs(to: firstWindow,
            currentKeyWindow: otherWindow, applicationIsActive: true))
        #expect(!TorrentKeyboardQuickLookPolicy.requestStillBelongs(to: firstWindow,
            currentKeyWindow: firstWindow, applicationIsActive: false))
    }

    @Test("disabled commands, non-Inspector callers, missing targets, partial files, and multiple selection are ignored")
    func unavailableKeyboardTargetsAreIgnored() {
        #expect(!accepts(context: .inspectorQuickLook, commandsEnabled: false))
        #expect(!accepts(context: .selectionOnly))
        #expect(!accepts(callbackAvailable: false))
        #expect(!accepts(path: nil))
        #expect(!accepts(isComplete: false))
        #expect(!accepts(selectionCount: 0))
        #expect(!accepts(selectionCount: 2))
        #expect(!accepts(path: "Subtitle.srt"))
    }

    @Test("Quick Look file availability rejects missing, partial, and wrong-sized files")
    func fileAvailability() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Movie.mkv")
        #expect(!TorrentKeyboardQuickLookPolicy.fileIsAvailable(at: file, expectedSize: valid.size))
        try Data([1, 2]).write(to: file)
        #expect(!TorrentKeyboardQuickLookPolicy.fileIsAvailable(at: file, expectedSize: valid.size))
        try Data([1, 2, 3, 4, 5]).write(to: file)
        #expect(!TorrentKeyboardQuickLookPolicy.fileIsAvailable(at: file, expectedSize: valid.size))
        try Data([1, 2, 3, 4]).write(to: file)
        #expect(TorrentKeyboardQuickLookPolicy.fileIsAvailable(at: file, expectedSize: valid.size))
    }

    private func accepts(context: TorrentKeyboardQuickLookPolicy.Context = .inspectorQuickLook,
                         callbackAvailable: Bool = true, commandsEnabled: Bool = true,
                         selectionCount: Int = 1, path: String? = "Movie.mkv",
                         isComplete: Bool = true, responder: NSResponder? = nil) -> Bool {
        TorrentKeyboardQuickLookPolicy.acceptsSpace(context: context,
            callbackAvailable: callbackAvailable, commandsEnabled: commandsEnabled,
            selectionCount: selectionCount, path: path, isComplete: isComplete,
            expectedSize: valid.size, firstResponder: responder)
    }
}
