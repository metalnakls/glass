import Foundation
@testable import GlassRemoteUI
import Testing

@MainActor @Suite("Reversible locale override")
struct GlassFormattingTests {
    @Test func defaultsAndRestoration() {
        let name = "GlassFormattingTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let policy = GlassFormatting(defaults: defaults)
        #expect(!policy.usesSystemLocale)
        #expect(policy.locale.identifier == "en_US")
        #expect(Int64(79_400_000_000).formatted(.byteCount(style: .file).locale(policy.locale)).contains("79.4"))
        policy.usesSystemLocale = true
        #expect(policy.locale == Locale.autoupdatingCurrent)
        #expect(GlassFormatting(defaults: defaults).usesSystemLocale)
        policy.usesSystemLocale = false
        policy.overrideIdentifier = "de_DE"
        let restored = GlassFormatting(defaults: defaults)
        #expect(restored.locale.identifier == "de_DE")
        #expect(Int64(79_400_000_000).formatted(.byteCount(style: .file).locale(restored.locale)).contains("79,4"))
    }
}
