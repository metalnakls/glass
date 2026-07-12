import GlassRemoteCore
import GlassRemoteServices
import SwiftUI

public struct PreferencesView: View {
    private let model: RemoteAppModel
    @State private var isTorrentCachingEnabled: Bool
    @State private var cachedServerLimit: Int

    public init(model: RemoteAppModel) {
        self.model = model
        _isTorrentCachingEnabled = State(initialValue: model.preferences.isTorrentCachingEnabled)
        _cachedServerLimit = State(initialValue: model.preferences.cachedServerLimit)
    }

    public var body: some View {
        Form {
            Toggle("Cache torrent lists", isOn: $isTorrentCachingEnabled)
            Stepper("Cached servers: \(cachedServerLimit)", value: $cachedServerLimit, in: 1...12)
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .onChange(of: isTorrentCachingEnabled) { _, _ in save() }
        .onChange(of: cachedServerLimit) { _, _ in save() }
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
