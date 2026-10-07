import Observation

@MainActor @Observable
public final class GlassUpdateAvailability {
    public static let shared = GlassUpdateAvailability()

    public private(set) var isAvailable = false
    @ObservationIgnored private var checkForUpdatesHandler: (() -> Void)?

    private init() {}

    public func setAvailable(_ available: Bool) {
        isAvailable = available
    }

    public func setCheckForUpdates(_ handler: (() -> Void)?) {
        checkForUpdatesHandler = handler
    }

    public func checkForUpdates() {
        checkForUpdatesHandler?()
    }
}
