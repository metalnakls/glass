import Observation

@MainActor @Observable
public final class GlassUpdateAvailability {
    public static let shared = GlassUpdateAvailability()

    public private(set) var isAvailable = false
    @ObservationIgnored private var checkForUpdatesHandler: (() -> Void)?

    @ObservationIgnored private let refreshTuning: () -> Void

    init(refreshTuning: @escaping () -> Void = {
        Task { await GlassTuningUpdates.shared.refresh(force: true) }
    }) {
        self.refreshTuning = refreshTuning
    }

    public func setAvailable(_ available: Bool) {
        isAvailable = available
    }

    public func setCheckForUpdates(_ handler: (() -> Void)?) {
        checkForUpdatesHandler = handler
    }

    public func checkForUpdates() {
        refreshTuning()
        checkForUpdatesHandler?()
    }
}
