import GlassRemoteServices
import SwiftUI

struct AddMagnetView: View {
    @ObservedObject var model: RemoteAppModel
    @Environment(\.dismiss) private var dismiss

    @State var magnet: String
    @State private var downloadDirectory = ""
    @State private var isAdding = false

    var body: some View {
        Form {
            TextField("Magnet Link", text: $magnet, axis: .vertical)
                .lineLimit(4...8)

            TextField("Download Directory", text: $downloadDirectory)
            if !model.downloadDirectoriesForSelectedProfile().isEmpty {
                Picker("Recent", selection: $downloadDirectory) {
                    Text("Default").tag("")
                    ForEach(model.downloadDirectoriesForSelectedProfile(), id: \.self) { directory in
                        Text(directory).tag(directory)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 520)
        .navigationTitle("Add Magnet")
        .task {
            if downloadDirectory.isEmpty {
                downloadDirectory = await model.defaultDownloadDirectoryForSelectedProfile() ?? ""
            }
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

    private func add() async {
        guard let magnet = normalizedMagnetLink(from: magnet) else { return }
        isAdding = true
        let didAdd = await model.addMagnet(
            magnet,
            downloadDirectory: downloadDirectory.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )
        isAdding = false
        if didAdd {
            dismiss()
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
