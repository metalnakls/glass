import GlassRemoteCore
import GlassRemoteServices
import SwiftUI

public struct PreferencesView: View {
    private let model: RemoteAppModel
    @State private var isTorrentCachingEnabled: Bool
    @State private var cachedServerLimit: Int
    @State private var profileEditor: ProfileEditorRequest?
    @State private var pendingDeletion: RemoteProfile?

    public init(model: RemoteAppModel) {
        self.model = model
        _isTorrentCachingEnabled = State(initialValue: model.preferences.isTorrentCachingEnabled)
        _cachedServerLimit = State(initialValue: model.preferences.cachedServerLimit)
    }

    public var body: some View {
        Form {
            Section("Servers") {
                ForEach(model.profiles) { profile in
                    LabeledContent(profile.name) {
                        Button("Edit…") { profileEditor = ProfileEditorRequest(profile: profile) }
                        Button("Remove…", role: .destructive) { pendingDeletion = profile }
                    }
                }
                Button("Add Server…") { profileEditor = ProfileEditorRequest(profile: nil) }
            }
            Section("Torrent Cache") {
                Toggle("Cache torrent lists", isOn: $isTorrentCachingEnabled)
                Stepper("Cached servers: \(cachedServerLimit)", value: $cachedServerLimit, in: 1...12)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .onChange(of: isTorrentCachingEnabled) { _, _ in save() }
        .onChange(of: cachedServerLimit) { _, _ in save() }
        .sheet(item: $profileEditor) { request in
            NavigationStack { ProfileEditorView(model: model, profile: request.profile) }
                .presentationSizing(.form)
        }
        .alert("Remove Server?", isPresented: Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )) {
            Button("Remove", role: .destructive) {
                if let profile = pendingDeletion { model.deleteProfile(profile) }
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("Remove this server from Glass. Its torrents and downloaded files are preserved.")
        }
    }

    private func save() {
        model.updatePreferences(
            GlassRemotePreferences(
                isTorrentCachingEnabled: isTorrentCachingEnabled,
                cachedServerLimit: cachedServerLimit
            )
        )
    }
}

private struct ProfileEditorRequest: Identifiable {
    let id = UUID()
    let profile: RemoteProfile?
}
