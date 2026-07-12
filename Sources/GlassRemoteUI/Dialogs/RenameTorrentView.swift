import GlassRemoteCore
import GlassRemoteServices
import SwiftUI

struct RenameTorrentView: View {
    let model: RemoteAppModel
    @Environment(\.dismiss) private var dismiss
    let torrent: TorrentSummary
    @State private var name: String

    init(model: RemoteAppModel, torrent: TorrentSummary) {
        self.model = model
        self.torrent = torrent
        _name = State(initialValue: torrent.name)
    }

    var body: some View {
        Form {
            TextField("Name", text: $name)
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 420)
        .navigationTitle("Rename")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Rename") {
                    Task {
                        await model.rename(torrent, to: name)
                        dismiss()
                    }
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}
