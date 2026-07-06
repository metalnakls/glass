import SwiftUI

struct RemovalUndoToast: View {
    let title: String
    let deleteData: Bool
    let undo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: deleteData ? "trash.slash" : "trash")
                .foregroundStyle(.secondary)
            Text(title)
                .lineLimit(1)
            Button("Undo", action: undo)
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .shadow(radius: 18, y: 6)
        .padding(.bottom, 24)
    }
}
