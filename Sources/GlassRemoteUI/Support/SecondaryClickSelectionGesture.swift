import AppKit
import SwiftUI

@available(macOS 26.0, *)
struct SecondaryClickSelectionGesture: NSGestureRecognizerRepresentable {
    final class Coordinator: NSObject, NSGestureRecognizerDelegate {
        var action: (NSEvent, NSView) -> Void

        init(action: @escaping (NSEvent, NSView) -> Void) {
            self.action = action
        }

        func gestureRecognizer(
            _ gestureRecognizer: NSGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: NSGestureRecognizer
        ) -> Bool {
            true
        }
    }

    let action: (NSEvent, NSView) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSGestureRecognizer(context: Context) -> SecondaryMouseDownRecognizer {
        let recognizer = SecondaryMouseDownRecognizer()
        recognizer.delegate = context.coordinator
        recognizer.onMouseDown = context.coordinator.action
        return recognizer
    }

    func updateNSGestureRecognizer(_ recognizer: SecondaryMouseDownRecognizer, context: Context) {
        context.coordinator.action = action
        recognizer.onMouseDown = context.coordinator.action
    }
}

@available(macOS 26.0, *)
final class SecondaryMouseDownRecognizer: NSGestureRecognizer {
    var onMouseDown: ((NSEvent, NSView) -> Void)?

    override func rightMouseDown(with event: NSEvent) {
        recognizeMouseDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            recognizeMouseDown(with: event)
        }
    }

    override func reset() {
        state = .possible
    }

    private func recognizeMouseDown(with event: NSEvent) {
        guard let view else { return }
        onMouseDown?(event, view)
        state = .began
        state = .ended
    }
}
