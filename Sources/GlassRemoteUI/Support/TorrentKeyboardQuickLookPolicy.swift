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

extension FocusedValues {
    var glassInspectorQuickLookAction: (@MainActor (NSWindow) -> Void)? {
        get { self[GlassInspectorQuickLookActionKey.self] }
        set { self[GlassInspectorQuickLookActionKey.self] = newValue }
    }
}
