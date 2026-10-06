import GlassRemoteCore
import GlassRemoteServices
import SwiftUI

struct ProfileSidebarView: View {
    let model: RemoteAppModel
    @Binding var selection: UUID?
    let editProfile: (RemoteProfile) -> Void
    let deleteProfile: (RemoteProfile) -> Void

    var body: some View {
        List(selection: sidebarSelection) {
            Section {
                sidebarRow(
                    title: model.localSourceName,
                    subtitle: nil,
                    systemImage: model.localSourceSystemImage
                )
                .tag(model.localSourceID)
                .listRowInsets(sidebarRowInsets)
            } header: {
                Text(glassText("local"))
            }

            Section {
                ForEach(model.profiles) { profile in
                    sidebarRow(
                        title: profile.name,
                        subtitle: profile.rpcURL.host(percentEncoded: false) ?? profile.rpcURL.absoluteString,
                        systemImage: "server.rack"
                    )
                    .tag(profile.id)
                    .listRowInsets(sidebarRowInsets)
                    .contextMenu {
                        Button(glassText("Edit")) {
                            editProfile(profile)
                        }
                        Button(glassText("Delete"), role: .destructive) {
                            deleteProfile(profile)
                        }
                    }
                }
            } header: {
                Text(glassText("remote"))
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 150, ideal: 220, max: 320)
    }

    private func sidebarRow(title: String, subtitle: String?, systemImage: String) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: systemImage)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 8)
        }
        .frame(minHeight: 36)
        .contentShape(Rectangle())
    }

    private var sidebarSelection: Binding<UUID> {
        Binding(
            get: { selection ?? model.localSourceID },
            set: { selection = $0 }
        )
    }

    private var sidebarRowInsets: EdgeInsets {
        EdgeInsets(top: 5, leading: 12, bottom: 5, trailing: 10)
    }
}
