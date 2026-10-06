import GlassRemoteCore
import GlassRemoteServices
import SwiftUI

public struct PreferencesView: View {
    private let model: RemoteAppModel
    private let platformIntegration: any GlassPlatformIntegrating
    @State private var isTorrentCachingEnabled: Bool
    @State private var cachedServerLimit: Int
    @State private var profileEditor: ProfileEditorRequest?
    @State private var pendingDeletion: RemoteProfile?

    public init(model: RemoteAppModel, platformIntegration: any GlassPlatformIntegrating = UnavailableGlassPlatformIntegration.shared) {
        self.model = model
        self.platformIntegration = platformIntegration
        _isTorrentCachingEnabled = State(initialValue: model.preferences.isTorrentCachingEnabled)
        _cachedServerLimit = State(initialValue: model.preferences.cachedServerLimit)
    }

    public var body: some View {
        Form {
            Section(glassText("Servers")) {
                ForEach(model.profiles) { profile in
                    LabeledContent(profile.name) {
                        Button(glassText("Edit…")) { profileEditor = ProfileEditorRequest(profile: profile) }
                        Button(glassText("Remove…"), role: .destructive) { pendingDeletion = profile }
                    }
                }
                Button(glassText("Add Server…")) { profileEditor = ProfileEditorRequest(profile: nil) }
            }
            Section(glassText("Numbers and Dates")) {
                LocaleOverrideControl()
            }
            Section(glassText("Torrent Cache")) {
                Toggle(glassText("Cache torrent lists"), isOn: $isTorrentCachingEnabled)
                Stepper("Cached servers: \(cachedServerLimit)", value: $cachedServerLimit, in: 1...12)
            }
        }
        .formStyle(.grouped)
        .glassTextStyle()
        .frame(width: 420)
        .onChange(of: isTorrentCachingEnabled) { _, _ in save() }
        .onChange(of: cachedServerLimit) { _, _ in save() }
        .sheet(item: $profileEditor) { request in
            NavigationStack { ProfileEditorView(model: model, platformIntegration: platformIntegration, profile: request.profile) }
                .presentationSizing(.form)
        }
        .alert(glassText("Remove Server?"), isPresented: Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )) {
            Button(glassText("Remove"), role: .destructive) {
                if let profile = pendingDeletion { model.deleteProfile(profile) }
                pendingDeletion = nil
            }
            Button(glassText("Cancel"), role: .cancel) { pendingDeletion = nil }
        } message: {
            Text(glassText("Remove this server from Glass. Its torrents and downloaded files are preserved."))
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
