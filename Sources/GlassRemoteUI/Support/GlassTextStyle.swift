import SwiftUI

enum GlassTextCase {
    static func apply(_ text: String, lowercase: Bool) -> String { lowercase ? text.lowercased() : text }
}

/// Native controls, placeholders and dialogs need their string styled before presentation.
@MainActor
public func glassText(_ text: String) -> String {
    GlassTextCase.apply(text, lowercase: AppearancePreferences.shared.value(for: "GlassList.lowercaseTitles", fallback: false))
}

/// Apply the chosen casing at the view boundary, without changing filenames or entered values.
private struct GlassTextStyle: ViewModifier {
    @AppearanceStorage("GlassList.lowercaseTitles") private var lowercase = false
    func body(content: Content) -> some View {
        content.textCase(lowercase ? .lowercase : nil)
    }
}

extension View {
    func glassTextStyle() -> some View { modifier(GlassTextStyle()) }
}
