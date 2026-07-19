import AppKit
import GlassRemoteCore
import SwiftUI

struct RenameTorrentView: View {
    let torrent: TorrentSummary
    let submit: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var isExtensionWarningPresented = false

    init(torrent: TorrentSummary, submit: @escaping (String) -> Void) {
        self.torrent = torrent
        self.submit = submit
        _name = State(initialValue: torrent.name)
    }

    var body: some View {
        Form {
            LabeledContent("Name") {
                StemSelectingTextField(text: $name, initialSelection: initialSelection)
                    .frame(minWidth: 340)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Rename Torrent")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            ToolbarItem(placement: .confirmationAction) {
                Button("Rename") { requestRename() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canRename)
            }
        }
        .frame(minWidth: 480, minHeight: 150)
        .containerBackground(.thinMaterial, for: .window)
        .alert("Change File Extension?", isPresented: $isExtensionWarningPresented) {
            Button(keepExtensionTitle, role: .cancel) {}
            Button(useNewExtensionTitle) { performRename() }
        } message: {
            Text(extensionWarningMessage)
        }
    }

    private var normalizedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canRename: Bool {
        !normalizedName.isEmpty && normalizedName != torrent.name
    }

    private var originalExtension: String {
        if let fileCount = torrent.fileCount, fileCount != 1 { return "" }
        return URL(fileURLWithPath: torrent.name).pathExtension
    }

    private var newExtension: String {
        URL(fileURLWithPath: normalizedName).pathExtension
    }

    private var changesExtension: Bool {
        !originalExtension.isEmpty && originalExtension.caseInsensitiveCompare(newExtension) != .orderedSame
    }

    private var initialSelection: NSRange {
        let fullLength = (torrent.name as NSString).length
        guard !originalExtension.isEmpty else { return NSRange(location: 0, length: fullLength) }
        let extensionLength = (originalExtension as NSString).length
        return NSRange(location: 0, length: max(0, fullLength - extensionLength - 1))
    }

    private var keepExtensionTitle: String {
        "Keep .\(originalExtension)"
    }

    private var useNewExtensionTitle: String {
        newExtension.isEmpty ? "Use Without Extension" : "Use .\(newExtension)"
    }

    private var extensionWarningMessage: String {
        if newExtension.isEmpty {
            return "If you remove the extension, the file may open in a different application."
        }
        return "If you change the extension from “\(originalExtension)” to “\(newExtension)”, the file may open in a different application."
    }

    private func requestRename() {
        guard canRename else { return }
        if changesExtension {
            isExtensionWarningPresented = true
        } else {
            performRename()
        }
    }

    private func performRename() {
        submit(normalizedName)
        dismiss()
    }
}

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
