import AppKit
import SwiftUI

struct GlassIconAppearanceControls: View {
    @AppearanceStorage("GlassList.iconGlassEnabled") private var glassEnabled = true
    @AppearanceStorage("GlassList.iconGlassRegular") private var regular = false
    @AppearanceStorage("GlassList.iconGlassBlur") private var blur = 0.5
    @AppearanceStorage("GlassList.iconGlassFrost") private var frost = 0.15
    @AppearanceStorage("GlassList.iconGlassOpacity") private var opacity = 1.0
    @AppearanceStorage("GlassList.iconGlassBrightness") private var brightness = 0.0
    @AppearanceStorage("GlassList.iconGlassTint") private var tint = "FFFFFF"
    @AppearanceStorage("GlassList.iconGlassTintStrength") private var tintStrength = 0.0
    @AppearanceStorage("GlassList.iconGlassHDRLight") private var hdrLight = 0.0
    @AppearanceStorage("GlassList.iconGlassHDRDark") private var hdrDark = 0.0
    @AppearanceStorage("GlassList.iconGlassHDRSoftness") private var hdrSoftness = 0.35
    @AppearanceStorage("GlassList.iconGlassHDRWidth") private var hdrWidth = 1.5

    @AppearanceStorage("GlassList.iconShadowStrength") private var shadowStrength = 0.12
    @AppearanceStorage("GlassList.iconShadowSoftness") private var shadowSoftness = 5.0
    @AppearanceStorage("GlassList.iconShadowOffset") private var shadowOffset = 3.0

    private var tintColor: Binding<Color> {
        Binding(get: { Color(nsColor: HeaderFadeColor.decode(tint)) },
                set: { tint = HeaderFadeColor.encode(NSColor($0)) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(glassText("Glass icons"), isOn: $glassEnabled)
            Text(glassText("Turn off to use the original Finder folder and file icons."))
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 36) {
                NativeGlassIcon(image: TorrentFileIconCache.icon(fileName: "", isFolder: true), size: 48, isFolder: true)
                NativeGlassIcon(image: TorrentFileIconCache.icon(fileName: "file.txt", isFolder: false), size: 48)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background {
                LinearGradient(colors: [.indigo.opacity(0.7), .pink.opacity(0.45), .orange.opacity(0.55)],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            Group {
                Picker(glassText("Style"), selection: $regular) {
                    Text(glassText("Clear")).tag(false)
                    Text(glassText("Frosted")).tag(true)
                }.pickerStyle(.segmented)
                slider("Frost blur", value: $blur, range: 0...6)
                slider("Frost", value: $frost, range: 0...1, percent: true)
                slider("Opacity", value: $opacity, range: 0.1...1, percent: true)
                slider("Brightness", value: $brightness, range: 0...1, percent: true)
            }.disabled(!glassEnabled)
            Divider()
            Text(glassText("Icon shadows")).font(.subheadline.weight(.semibold))
            slider("Shadow strength", value: $shadowStrength, range: 0...0.65, percent: true)
            slider("Shadow softness", value: $shadowSoftness, range: 0...32)
            slider("Shadow offset", value: $shadowOffset, range: 0...24)
            Divider()
            Group {
                Text(glassText("Colour")).font(.subheadline.weight(.semibold))
                ColorPicker("Tint", selection: tintColor, supportsOpacity: false)
                slider("Tint strength", value: $tintStrength, range: 0...1, percent: true)
                Divider()
                Text(glassText("HDR reflections")).font(.subheadline.weight(.semibold))
                slider("HDR brightness · light", value: $hdrLight, range: 0...3)
                slider("HDR brightness · dark", value: $hdrDark, range: 0...3)
                slider("HDR highlight softness", value: $hdrSoftness, range: 0...4)
                slider("HDR highlight width", value: $hdrWidth, range: 0.5...3)
                Text(glassText("HDR brightens reflections. Extra brightness depends on your display."))
                    .font(.caption).foregroundStyle(.secondary)
            }.disabled(!glassEnabled)
            Button(glassText("Reset Glass Icons")) {
                for (key, value) in GlassAppearanceDefaults.effective where key.hasPrefix("GlassList.iconGlass") || key.hasPrefix("GlassList.iconShadow") {
                    AppearancePreferences.shared.set(value, for: key)
                }
            }
        }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, percent: Bool = false) -> some View {
        VStack(spacing: 3) {
            HStack {
                Text(title)
                Spacer()
                Text(percent ? "\(Int((value.wrappedValue * 100).rounded()))%" : formatNumber(value.wrappedValue))
                    .monospacedDigit().foregroundStyle(.secondary)
            }.font(.caption)
            Slider(value: value, in: range).accessibilityLabel(title)
        }
    }
}
