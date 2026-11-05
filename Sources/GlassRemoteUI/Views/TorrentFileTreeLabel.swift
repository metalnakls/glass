import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The hierarchy lives only in the name column; wanted and size columns stay fixed.
struct TorrentFileTreeLabel: View {
    let row: TorrentFileTreeRow
    let name: String
    let isExpanded: Bool
    let showsHierarchy: Bool
    let toggleExpanded: () -> Void
    private let layout = TorrentFileListLayout.shared

    var body: some View {
        HStack(spacing: layout.columnGap) {
            if showsHierarchy { Group {
                if row.isFolder {
                    TorrentFileDisclosure(isExpanded: isExpanded, name: name, action: toggleExpanded)
                } else { Color.clear.accessibilityHidden(true) }
            }
            .frame(width: layout.disclosureWidth, height: layout.contentHeight)
            }
            Image(nsImage: TorrentFileIdentityIcons.image(for: row))
                .resizable().scaledToFit()
                .frame(width: layout.identityIconWidth, height: layout.identityIconWidth)
                .accessibilityHidden(true)
            Text(name).textCase(nil)
                .fontWeight(row.isFolder ? .semibold : .regular)
                .lineLimit(1).truncationMode(.middle)
                .help(name)
        }
        .padding(.leading, CGFloat(row.depth) * layout.indent)
    }
}

/// Use AppKit's disclosure control, including its native input and accessibility.
private struct TorrentFileDisclosure: NSViewRepresentable {
    let isExpanded: Bool
    let name: String
    let action: () -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: context.coordinator, action: #selector(Coordinator.toggle))
        button.bezelStyle = .disclosure
        button.setButtonType(.onOff)
        button.controlSize = .small
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.state = isExpanded ? .on : .off
        button.setAccessibilityLabel(glassText("\(isExpanded ? "Collapse" : "Expand") \(name)"))
        button.toolTip = name
    }
    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func toggle() { action() }
    }
}

@MainActor
private enum TorrentFileIdentityIcons {
    private static var images: [String: NSImage] = [:]
    static func image(for row: TorrentFileTreeRow) -> NSImage {
        let type = row.isFolder ? UTType.folder :
            (UTType(filenameExtension: (row.entry?.originalPath as NSString?)?.pathExtension ?? "") ?? .data)
        if let image = images[type.identifier] { return image }
        let image = NSWorkspace.shared.icon(for: type)
        images[type.identifier] = image
        return image
    }
}
