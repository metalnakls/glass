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
                    Text("Couldn’t Add Torrent")
                }
            }

            TextField("Magnet Link", text: $magnet, axis: .vertical)
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
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(isAdding)
                Spacer()
                Button("Add") { Task { await add() } }
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
        let didAdd = await model.addMagnet(
            magnet,
            downloadDirectory: downloadDirectory,
            sourceID: sourceID
        )
        isAdding = false
        if didAdd {
            model.selectedProfileID = sourceID
            dismiss()
        } else {
            addErrorMessage = model.errorMessage ?? "Glass couldn’t add this torrent."
            model.errorMessage = nil
        }
    }
}
