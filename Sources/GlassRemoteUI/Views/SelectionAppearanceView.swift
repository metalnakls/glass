import AppKit
import SwiftUI

public struct SelectionAppearanceView: View {
    public init() {}

    @AppStorage("GlassList.sidePadding") private var sidePadding = 18.0
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("GlassList.selectionEaseIn") private var selectionEaseIn = 0.25
    @AppStorage("GlassList.selectionEaseOut") private var selectionEaseOut = 0.30
    @AppStorage("GlassList.selectedHDRWhite") private var selectedHDRWhite = 0.0
    @AppStorage("GlassList.selectedHDRSoftness") private var selectedHDRSoftness = 0.0
    @AppStorage("GlassList.selectedHDRSpread") private var selectedHDRSpread = 0.0
    @AppStorage("GlassList.columnLightBrightness") private var columnLightBrightness = 0.955
    @AppStorage("GlassList.columnDarkBrightness") private var columnDarkBrightness = 0.105
    @AppStorage("GlassList.shadowTopStrength") private var shadowTopStrength = 0.12
    @AppStorage("GlassList.shadowTopSoftness") private var shadowTopSoftness = 8.0
    @AppStorage("GlassList.shadowTopLift") private var shadowTopLift = 4.0
    @AppStorage("GlassList.shadowBottomStrength") private var shadowBottomStrength = 0.22
    @AppStorage("GlassList.shadowBottomSoftness") private var shadowBottomSoftness = 12.0
    @AppStorage("GlassList.shadowBottomLift") private var shadowBottomLift = 7.0

    @AppStorage("GlassList.stateGap") private var stateGap = 8.0
    @AppStorage("GlassList.progressGlowBlur") private var progressGlowBlur = 3.0
    @AppStorage("GlassList.progressGlowStrength") private var progressGlowStrength = 0.8
    @AppStorage("GlassList.progressLineWidth") private var progressLineWidth = 2.0
    @AppStorage("GlassList.progressFilled") private var progressFilled = false

    private var columnBrightness: Binding<Double> {
        Binding(get: { colorScheme == .dark ? columnDarkBrightness : columnLightBrightness }, set: {
            if colorScheme == .dark { columnDarkBrightness = $0 } else { columnLightBrightness = $0 }
        })
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Selection Appearance").font(.headline)
                shadowSlider("Side padding", value: $sidePadding, range: 0...160)
                HStack {
                    Text("HDR white")
                    Spacer()
                    Text(selectedHDRWhite, format: .number.precision(.fractionLength(2)))
                        .monospacedDigit().foregroundStyle(.secondary)
                }.font(.caption)
                Slider(value: $selectedHDRWhite, in: 0...3).accessibilityLabel("HDR white")
                shadowSlider("HDR glow softness", value: $selectedHDRSoftness, range: 0...32)
                shadowSlider("HDR glow spread", value: $selectedHDRSpread, range: 0...24)
                shadowSlider("Column brightness", value: columnBrightness, range: 0...1, percent: true)
                Divider()
                Text("State Button").font(.subheadline.weight(.semibold))
                shadowSlider("Size / button spacing", value: $stateGap, range: 0...32)
                shadowSlider("Progress glow blur", value: $progressGlowBlur, range: 0...16)
                shadowSlider("Progress glow strength", value: $progressGlowStrength, range: 0...2)
                shadowSlider("Progress ring width", value: $progressLineWidth, range: 0.5...5)
                Toggle("Fill circle with progress", isOn: $progressFilled)
                Divider()
                Text("Motion").font(.subheadline.weight(.semibold))
                durationSlider("Ease in", value: $selectionEaseIn)
                durationSlider("Ease out", value: $selectionEaseOut)
                Divider()
                Text("Above").font(.subheadline.weight(.semibold))
                shadowSlider("Strength", value: $shadowTopStrength, range: 0...0.65, percent: true)
                shadowSlider("Softness", value: $shadowTopSoftness, range: 0...32)
                shadowSlider("Lift", value: $shadowTopLift, range: 0...24)
                Divider()
                Text("Below").font(.subheadline.weight(.semibold))
                shadowSlider("Strength", value: $shadowBottomStrength, range: 0...0.65, percent: true)
                shadowSlider("Softness", value: $shadowBottomSoftness, range: 0...32)
                shadowSlider("Lift", value: $shadowBottomLift, range: 0...24)
                Button("Reset") {
                    stateGap = 8; progressGlowBlur = 3; progressGlowStrength = 0.8; progressLineWidth = 2; progressFilled = false
                    sidePadding = 18
                    selectionEaseIn = 0.25
                    selectionEaseOut = 0.30
                    selectedHDRWhite = 0
                    selectedHDRSoftness = 0
                    selectedHDRSpread = 0
                    if colorScheme == .dark { columnDarkBrightness = 0.105 } else { columnLightBrightness = 0.955 }
                    shadowTopStrength = 0.12; shadowTopSoftness = 8; shadowTopLift = 4
                    shadowBottomStrength = 0.22; shadowBottomSoftness = 12; shadowBottomLift = 7
                }
            }
            .padding(16)
        }
        .frame(width: 320, height: 640)
    }

    private func durationSlider(_ title: String, value: Binding<Double>) -> some View {
        VStack(spacing: 3) {
            HStack {
                Text(title)
                Spacer()
                Text("\(value.wrappedValue.formatted(.number.precision(.fractionLength(2)))) s")
                    .monospacedDigit().foregroundStyle(.secondary)
            }.font(.caption)
            Slider(value: value, in: 0...1.5).accessibilityLabel(title)
        }
    }

    private func shadowSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, percent: Bool = false) -> some View {
        VStack(spacing: 3) {
            HStack {
                Text(title)
                Spacer()
                Text(percent ? "\(Int((value.wrappedValue * 100).rounded()))%" : "\(Int(value.wrappedValue.rounded()))")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.caption)
            Slider(value: value, in: range).accessibilityLabel(title)
        }
    }

}

@MainActor
public enum SelectionAppearanceWindow {
    private static var window: NSWindow?

    public static func show() {
        guard ProcessInfo.processInfo.arguments.contains("--tune-appearance") else { return }
        if window == nil {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 640),
                                 styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            panel.title = "Selection Appearance"
            panel.contentView = NSHostingView(rootView: SelectionAppearanceView())
            panel.isReleasedWhenClosed = false
            panel.setFrameAutosaveName("GlassSelectionAppearance")
            panel.center()
            window = panel
        }
        window?.makeKeyAndOrderFront(nil)
    }
}
