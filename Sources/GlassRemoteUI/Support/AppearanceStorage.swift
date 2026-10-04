import Foundation
import Observation
import SwiftUI

/// One observable source for tuning across the main scene and detached AppKit window.
/// Persist every edit, but invalidate all readers immediately in the same process.
@MainActor @Observable
final class AppearancePreferences {
    static let shared = AppearancePreferences(defaults: .standard)
    @ObservationIgnored private let defaults: UserDefaults
    private var revision = 0

    init(defaults: UserDefaults) { self.defaults = defaults }
    func value<Value>(for key: String, fallback: Value) -> Value {
        _ = revision
        return defaults.object(forKey: key) as? Value ?? fallback
    }
    func invalidate() { revision &+= 1 }
    func resetToDefaults() {
        for (key, value) in GlassAppearanceDefaults.effective { set(value, for: key) }
    }
    func set<Value>(_ value: Value, for key: String) {
        defaults.set(value, forKey: key)
        revision &+= 1
    }
}

@MainActor @propertyWrapper
struct AppearanceStorage<Value> {
    private let key: String
    private let fallback: Value
    init(wrappedValue: Value, _ key: String) {
        self.key = key
        self.fallback = wrappedValue
    }
    var wrappedValue: Value {
        get { AppearancePreferences.shared.value(for: key, fallback: fallback) }
        nonmutating set { AppearancePreferences.shared.set(newValue, for: key) }
    }
    var projectedValue: Binding<Value> {
        Binding(get: { wrappedValue }, set: { wrappedValue = $0 })
    }
}
