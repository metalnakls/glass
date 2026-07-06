import GlassRemoteCore
import GlassRemoteServices
import SwiftUI

struct ProfileSidebarView: View {
    @ObservedObject var model: RemoteAppModel
    @Binding var selection: UUID?
    let editProfile: (RemoteProfile) -> Void
    let deleteProfile: (RemoteProfile) -> Void

    var body: some View {
        List(selection: $selection) {
            Section("Local") {
                Label {
                    Text(model.localSourceName)
                } icon: {
                    Image(systemName: model.localSourceSystemImage)
                }
                .tag(model.localSourceID)
            }

            Section("Remote") {
                ForEach(model.profiles) { profile in
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.name)
                            Text(profile.rpcURL.host(percentEncoded: false) ?? profile.rpcURL.absoluteString)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    } icon: {
                        Image(systemName: "server.rack")
                    }
                    .tag(profile.id)
                    .contextMenu {
                        Button("Edit") {
                            editProfile(profile)
                        }
                        Button("Delete", role: .destructive) {
                            deleteProfile(profile)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
    }
}
