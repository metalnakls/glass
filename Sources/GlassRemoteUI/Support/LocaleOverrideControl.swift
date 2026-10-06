import SwiftUI

/// Settings and Tune edit the same observable policy, with the same positive toggle.
struct LocaleOverrideControl: View {
    @Bindable private var formatting = GlassFormatting.shared
    var body: some View {
        Toggle(glassText("Override Mac locale with en-US"), isOn: Binding(
            get: { !formatting.usesSystemLocale },
            set: { enabled in
                if enabled { formatting.overrideIdentifier = "en_US" }
                formatting.usesSystemLocale = !enabled
            }
        ))
        .help("Use dots in numbers and US date formats. Turn off to follow your Mac’s settings.")
    }
}
