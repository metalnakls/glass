import AppKit
import Foundation
import SwiftUI

enum TorrentKeyboardQuickLookPolicy {
    enum Context: Equatable {
        case selectionOnly
        case inspectorQuickLook
    }

    static func isTextInputFirstResponder(_ responder: NSResponder?) -> Bool {
        responder is NSTextView || responder is NSTextField
    }

    static func fileIsAvailable(at url: URL, expectedSize: UInt64) -> Bool {
        guard expectedSize > 0,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.uint64Value == expectedSize,
              FileManager.default.isReadableFile(atPath: url.path) else { return false }
        return true
    }

    static func mayForwardFromRoot(actionAvailable: Bool, firstResponder: NSResponder?,
                                   keyWindow: NSWindow?, applicationIsActive: Bool) -> Bool {
        actionAvailable && applicationIsActive && keyWindow != nil
            && !isTextInputFirstResponder(firstResponder)
    }

    static func requestStillBelongs(to originatingWindow: NSWindow, currentKeyWindow: NSWindow?,
                                    applicationIsActive: Bool) -> Bool {
        applicationIsActive && originatingWindow === currentKeyWindow
    }

    static func acceptsSpace(context: Context, callbackAvailable: Bool, commandsEnabled: Bool,
                             selectionCount: Int, path: String?, isComplete: Bool,
                             expectedSize: UInt64, firstResponder: NSResponder?) -> Bool {
        guard context == .inspectorQuickLook, callbackAvailable, commandsEnabled,
              selectionCount == 1, !isTextInputFirstResponder(firstResponder),
              let path, expectedSize > 0, isComplete,
              TorrentThumbnailInput.isPreviewableVideo(path) else { return false }
        return true
    }
}

private struct GlassInspectorQuickLookActionKey: FocusedValueKey {
    typealias Value = @MainActor (NSWindow) -> Void
}

/// Focused values refresh during native scrolling. Keep that dependency on the
/// key handler so it cannot rebuild the workspace, list, and inspector each frame.
struct TorrentRootQuickLookKeyHandler: ViewModifier {
    @FocusedValue(\.glassInspectorQuickLookAction) private var inspectorQuickLookAction

    func body(content: Content) -> some View {
        content.onKeyPress(.space, phases: [.down]) { _ in
            guard let window = NSApp.keyWindow,
                  TorrentKeyboardQuickLookPolicy.mayForwardFromRoot(
                    actionAvailable: inspectorQuickLookAction != nil,
                    firstResponder: window.firstResponder,
                    keyWindow: window,
                    applicationIsActive: NSApp.isActive
                  ),
                  let inspectorQuickLookAction else { return .ignored }
            inspectorQuickLookAction(window)
            return .handled
        }
    }
}

extension FocusedValues {
    var glassInspectorQuickLookAction: (@MainActor (NSWindow) -> Void)? {
        get { self[GlassInspectorQuickLookActionKey.self] }
        set { self[GlassInspectorQuickLookActionKey.self] = newValue }
    }
}
