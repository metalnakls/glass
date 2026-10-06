import GlassRemoteServices
import SwiftUI

struct AddMagnetView: View {
    let model: RemoteAppModel
    let platformIntegration: any GlassPlatformIntegrating
    @Environment(\.dismiss) private var dismiss

    @State private var selectedDestinationID: UUID?
    @State var magnet: String
    @State private var downloadDirectory: String?
    @State private var defaultDownloadDirectory: String?
    @State private var isAdding = false
    @State private var addErrorMessage: String?

    var body: some View {
        Form {
            if let addErrorMessage {
                Section {
                    Label(addErrorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                } header: {
                    Text(glassText("Couldn’t Add Torrent"))
                }
            }

            TextField(glassText("Magnet Link"), text: $magnet, axis: .vertical)
                .lineLimit(2...4)
                .disabled(isAdding)

            TorrentDownloadLocationPicker(
                model: model,
                platformIntegration: platformIntegration,
                sourceID: destinationBinding,
                directory: $downloadDirectory,
                defaultDirectory: $defaultDownloadDirectory,
                errorMessage: $addErrorMessage,
                isDisabled: isAdding
            )
        }
        .formStyle(.columns)
        .padding(20)
        .frame(width: 540, height: 240)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Button(glassText("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(isAdding)
                Spacer()
                Button(glassText("Add")) { Task { await add() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(normalizedMagnetLink(from: magnet) == nil || isAdding)
            }
            .controlSize(.large).padding(12).background(.ultraThinMaterial)
        }
    }

    private var destinationID: UUID { selectedDestinationID ?? model.selectedSourceID }
    private var destinationBinding: Binding<UUID> {
        Binding(get: { destinationID }, set: { selectedDestinationID = $0 })
    }

    private func add() async {
        guard let magnet = normalizedMagnetLink(from: magnet) else { return }
        addErrorMessage = nil
        isAdding = true
        let sourceID = destinationID
        model.selectedProfileID = sourceID
        model.selectedTorrentGroup = .all
        // The model persists the submission synchronously before its first RPC wait.
        let request = Task { await model.addMagnet(magnet, downloadDirectory: downloadDirectory, sourceID: sourceID) }
        await Task.yield()
        dismiss()
        _ = await request.value

    }
}
