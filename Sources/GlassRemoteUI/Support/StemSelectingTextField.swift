import AppKit
import SwiftUI

struct StemSelectingTextField: NSViewRepresentable {
    @Binding var text: String
    let initialSelection: NSRange

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, initialSelection: initialSelection)
    }

    func makeNSView(context: Context) -> NSTextField {
        let textField = NSTextField(string: text)
        textField.delegate = context.coordinator
        textField.bezelStyle = .roundedBezel
        textField.lineBreakMode = .byTruncatingMiddle
        textField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        DispatchQueue.main.async {
            guard !context.coordinator.didApplyInitialSelection else { return }
            context.coordinator.didApplyInitialSelection = true
            textField.window?.makeFirstResponder(textField)
            textField.currentEditor()?.selectedRange = initialSelection
        }
        return textField
    }

    func updateNSView(_ textField: NSTextField, context: Context) {
        if textField.stringValue != text {
            textField.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding var text: String
        let initialSelection: NSRange
        var didApplyInitialSelection = false

        init(text: Binding<String>, initialSelection: NSRange) {
            _text = text
            self.initialSelection = initialSelection
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else { return }
            text = textField.stringValue
        }
    }
}
