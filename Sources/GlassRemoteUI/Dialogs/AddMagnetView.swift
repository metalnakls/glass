import GlassRemoteServices
import SwiftUI

struct AddMagnetView: View {
    let model: RemoteAppModel
    let platformIntegration: any GlassPlatformIntegrating
    @Environment(\.dismiss) private var dismiss

    @State private var selectedDestinationID: UUID?
    @State var magnet: String
    @State private var downloadDirectory = ""
    @State private var isAdding = false
    @State private var isChoosingDownloadDirectory = false
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

            Picker("Destination", selection: destinationBinding) {
                Text(model.localSourceName).tag(model.localSourceID)
                ForEach(model.profiles) { profile in
                    Text(profile.name).tag(profile.id)
                }
            }
            .disabled(isAdding)

            TextField("Magnet Link", text: $magnet, axis: .vertical)
                .lineLimit(4...8)

            if isLocalDestination {
                LabeledContent("Download Directory") {
                    HStack(spacing: 8) {
                        Text(downloadDirectory.isEmpty ? "Default" : downloadDirectory)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Button("Choose...") {
                            Task { await chooseDownloadDirectory() }
                        }
                        .disabled(isChoosingDownloadDirectory || isAdding)
                    }
                }
            } else {
                TextField("Download Directory", text: $downloadDirectory)
            }

            if !isLocalDestination, !model.downloadDirectories(for: destinationID).isEmpty {
                Picker("Recent", selection: $downloadDirectory) {
                    Text("Default").tag("")
                    ForEach(model.downloadDirectories(for: destinationID), id: \.self) { directory in
                        Text(directory).tag(directory)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Add Magnet")
        .task(id: destinationID) {
            let sourceID = destinationID
            let directory = await model.defaultDownloadDirectory(for: sourceID) ?? ""
            guard !Task.isCancelled else { return }
            downloadDirectory = directory
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") {
                    Task { await add() }
                }
                .disabled(normalizedMagnetLink(from: magnet) == nil || isAdding)
            }
        }
    }

    private var destinationID: UUID { selectedDestinationID ?? model.selectedSourceID }
    private var isLocalDestination: Bool { destinationID == model.localSourceID }
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
            downloadDirectory: downloadDirectory.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
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

    private func chooseDownloadDirectory() async {
        isChoosingDownloadDirectory = true
        defer { isChoosingDownloadDirectory = false }

        do {
            if let path = try await platformIntegration.chooseLocalDownloadDirectory(
                startingAt: downloadDirectory.nilIfEmpty
            ) {
                downloadDirectory = path
            }
        } catch {
            addErrorMessage = error.localizedDescription
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
