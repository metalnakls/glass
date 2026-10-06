import AppKit
import SwiftUI

public struct SelectionAppearanceView: View {
    private let onClose: () -> Void
    public init(onClose: @escaping () -> Void = {}) { self.onClose = onClose }
    @AppearanceStorage("GlassList.loadingSort") private var loadingSort = "priority"
    @AppearanceStorage("GlassList.completedSort") private var completedSort = "lastDownloaded"
    @AppearanceStorage("GlassList.lowercaseTitles") private var lowercaseTitles = false
    @AppearanceStorage("GlassList.funMode") private var funMode = false
    @AppearanceStorage("GlassList.funScale") private var funScale = 1.5
    @AppearanceStorage("GlassList.funTilt") private var funTilt = 9.0
    @AppearanceStorage("GlassList.posterColoredShadows") private var coloredShadows = true
    @AppStorage("GlassList.enableIconView") private var enableIconView = false
    @AppStorage("GlassList.enableCompactView") private var enableCompactView = false
    @AppearanceStorage("GlassInspector.blurEnabled") private var inspectorBlurEnabled = false
    @AppearanceStorage("GlassInspector.blurRadius") private var inspectorBlurRadius = 6.0
    @AppearanceStorage("GlassInspector.blurEaseIn") private var inspectorBlurEaseIn = 0.25
    @AppearanceStorage("GlassInspector.blurEaseOut") private var inspectorBlurEaseOut = 0.35
    @State private var saveStatus: String?
    @SceneStorage("GlassTune.section") private var sectionName = TuningSection.icons.rawValue
    private var section: TuningSection { TuningSection(rawValue: sectionName) ?? .icons }

    @AppearanceStorage("GlassList.leftPadding") private var leftPadding = UserDefaults.standard.object(forKey: "GlassList.sidePadding") as? Double ?? 18
    @AppearanceStorage("GlassList.rightPadding") private var rightPadding = UserDefaults.standard.object(forKey: "GlassList.sidePadding") as? Double ?? 18
    @AppearanceStorage("GlassList.itemVerticalPadding") private var itemVerticalPadding = 0.0
    @AppearanceStorage("GlassList.sectionSpacing") private var sectionSpacing = 16.0
    @AppearanceStorage("GlassList.headerBottomPadding") private var headerBottomPadding = 0.0
    @Environment(\.colorScheme) private var colorScheme
    @AppearanceStorage("GlassList.selectionEaseIn") private var selectionEaseIn = 0.25
    @AppearanceStorage("GlassList.selectionEaseOut") private var selectionEaseOut = 0.30
    @AppearanceStorage("GlassList.highlightColorLight") private var highlightColorLight = "FFFFFF"
    @AppearanceStorage("GlassList.highlightWidth") private var highlightWidth = 0.0
    @AppearanceStorage("GlassList.highlightColorDark") private var highlightColorDark = "1F1F1F"
    @AppearanceStorage("GlassList.selectedHDRWhiteLight") private var selectedHDRWhiteLight = UserDefaults.standard.object(forKey: "GlassList.selectedHDRWhite") as? Double ?? 0.0
    @AppearanceStorage("GlassList.selectedHDRWhiteDark") private var selectedHDRWhiteDark = 0.0
    @AppearanceStorage("GlassList.selectedHDRSoftness") private var selectedHDRSoftness = 0.0
    @AppearanceStorage("GlassList.selectedHDRSpread") private var selectedHDRSpread = 0.0
    @AppearanceStorage("GlassList.columnLightBrightness") private var columnLightBrightness = 0.955
    @AppearanceStorage("GlassList.columnDarkBrightness") private var columnDarkBrightness = 0.105
    @AppearanceStorage("GlassList.shadowTopStrength") private var shadowTopStrength = 0.12
    @AppearanceStorage("GlassList.shadowTopSoftness") private var shadowTopSoftness = 8.0
    @AppearanceStorage("GlassList.shadowTopLift") private var shadowTopLift = 4.0
    @AppearanceStorage("GlassList.shadowBottomStrength") private var shadowBottomStrength = 0.22
    @AppearanceStorage("GlassList.shadowBottomSoftness") private var shadowBottomSoftness = 12.0
    @AppearanceStorage("GlassList.shadowBottomLift") private var shadowBottomLift = 7.0

    @AppearanceStorage("GlassList.stateGap") private var stateGap = 8.0
    @AppearanceStorage("GlassList.filePriorityGap") private var filePriorityGap = 4.0
    @AppearanceStorage("GlassList.progressGlowBlur") private var progressGlowBlur = 3.0
    @AppearanceStorage("GlassList.progressGlowStrength") private var progressGlowStrength = 0.8
    @AppearanceStorage("GlassList.progressLineWidth") private var progressLineWidth = 2.0
    @AppearanceStorage("GlassList.dropBlurRadius") private var dropBlurRadius = 8.0
    @AppearanceStorage("GlassList.stateGlass") private var stateGlass = true
    @AppearanceStorage("GlassList.progressFilled") private var progressFilled = false
    @AppearanceStorage("GlassList.headerFadeStrengthLight") private var headerFadeStrengthLight = UserDefaults.standard.object(forKey: "GlassList.headerFadeStrength") as? Double ?? 0.75
    @AppearanceStorage("GlassList.headerFadeStrengthDark") private var headerFadeStrengthDark = UserDefaults.standard.object(forKey: "GlassList.headerFadeStrength") as? Double ?? 0.75
    @AppearanceStorage("GlassList.headerFadeReach") private var headerFadeReach = 48.0
    @AppearanceStorage("GlassList.headerBackgroundIn") private var headerBackgroundIn = 0.22
    @AppearanceStorage("GlassList.headerBackgroundOut") private var headerBackgroundOut = 0.28
    @AppearanceStorage("GlassList.headerTitleIn") private var headerTitleIn = 0.18
    @AppearanceStorage("GlassList.headerTitleOut") private var headerTitleOut = 0.22
    @AppearanceStorage("GlassList.headerPushLead") private var headerPushLead = 0.0
    @AppearanceStorage("GlassList.headerFadeColorLight") private var headerFadeColorLight = "FFFFFF"
    @AppearanceStorage("GlassList.headerFadeColorDark") private var headerFadeColorDark = "0C0C0C"
    private func highlightColor(dark: Bool) -> Binding<Color> {
        Binding(get: { Color(nsColor: HeaderFadeColor.decode(dark ? highlightColorDark : highlightColorLight)) }, set: {
            let hex = HeaderFadeColor.encode(NSColor($0))
            if dark { highlightColorDark = hex } else { highlightColorLight = hex }
        })
    }
    private func headerColor(dark: Bool) -> Binding<Color> {
        Binding(get: { Color(nsColor: HeaderFadeColor.decode(dark ? headerFadeColorDark : headerFadeColorLight)) }, set: {
            let hex = HeaderFadeColor.encode(NSColor($0))
            if dark { headerFadeColorDark = hex } else { headerFadeColorLight = hex }
        })
    }

    public var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text(glassText("Tune")).font(.headline)
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close Tune")
                    .help("Return to the torrent inspector")
            }
            Picker(glassText("Section"), selection: $sectionName) {
                ForEach(TuningSection.allCases) { section in
                    Label(glassText(section.title), systemImage: section.symbol).tag(section.rawValue)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .accessibilityLabel("Tune section")
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) { controls }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            }
            .id(sectionName)
            .scrollEdgeEffectHidden(true, for: .top)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button(glassText("Test Torrents…")) { TorrentTestWindow.show() }
                    Spacer(minLength: 4)
                    Button(glassText("Reset")) { AppearancePreferences.shared.resetToDefaults() }
                    Button(glassText("Save…")) {
                        do {
                            if try GlassAppearanceDefaults.save() { saveStatus = "Appearance defaults saved." }
                        } catch { saveStatus = error.localizedDescription }
                    }
                    .help("Save appearance values and the main window size as defaults.")
                }.controlSize(.small)
                if let saveStatus { Text(saveStatus).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: .top)
        .glassTextStyle()
    }

    @ViewBuilder private var controls: some View {
        switch section {
        case .sorting:
            VStack(alignment: .leading, spacing: 12) {
                Text(glassText("Loading")).font(.subheadline.weight(.semibold))
                Picker(glassText("Sort by"), selection: $loadingSort) {
                    ForEach([TorrentListSorting.Rule.priority, .oldestAdded, .newestAdded, .name, .transmission]) { rule in
                        Text(glassText(rule.title)).tag(rule.rawValue)
                    }
                }
                if loadingSort == "priority" {
                    Text(glassText("High, normal, then low priority. New additions go to the bottom of their priority.")).font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                Text(glassText("Completed")).font(.subheadline.weight(.semibold))
                Picker(glassText("Sort by"), selection: $completedSort) {
                    ForEach([TorrentListSorting.Rule.lastDownloaded, .newestAdded, .oldestAdded, .name, .transmission]) { rule in
                        Text(glassText(rule.title)).tag(rule.rawValue)
                    }
                }
                if completedSort == "lastDownloaded" {
                    Text(glassText("Most recently finished first. Seeding does not change the order.")).font(.caption).foregroundStyle(.secondary)
                }
                Text(glassText("Choose Transmission order to arrange items by dragging.")).font(.caption).foregroundStyle(.secondary)
            }
        case .icons:
            GlassIconAppearanceControls()
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text(glassText("Personality")).font(.subheadline.weight(.semibold))
                Toggle(glassText("Fun mode"), isOn: $funMode)
                if funMode {
                    shadowSlider("Icon scale", value: $funScale, range: 1...1.8, decimal: true)
                    shadowSlider("Icon tilt", value: $funTilt, range: 0...16)
                    Toggle(glassText("Coloured poster shadows"), isOn: $coloredShadows)
                }
            }
        case .selection:
            VStack(alignment: .leading, spacing: 12) {
                Text(glassText("Highlight")).font(.subheadline.weight(.semibold))
                ColorPicker("Colour · light", selection: highlightColor(dark: false), supportsOpacity: false)
                ColorPicker("Colour · dark", selection: highlightColor(dark: true), supportsOpacity: false)
                shadowSlider("Width", value: $highlightWidth, range: -80...160)
                hdrSlider("HDR brightness · light", value: $selectedHDRWhiteLight)
                hdrSlider("HDR brightness · dark", value: $selectedHDRWhiteDark)
                shadowSlider("HDR glow softness", value: $selectedHDRSoftness, range: 0...32)
                shadowSlider("HDR glow spread", value: $selectedHDRSpread, range: 0...24)
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text(glassText("Shadow above")).font(.subheadline.weight(.semibold))
                shadowSlider("Strength", value: $shadowTopStrength, range: 0...0.65, percent: true)
                shadowSlider("Softness", value: $shadowTopSoftness, range: 0...32)
                shadowSlider("Lift", value: $shadowTopLift, range: 0...24)
            }
            VStack(alignment: .leading, spacing: 12) {
                Text(glassText("Shadow below")).font(.subheadline.weight(.semibold))
                shadowSlider("Strength", value: $shadowBottomStrength, range: 0...0.65, percent: true)
                shadowSlider("Softness", value: $shadowBottomSoftness, range: 0...32)
                shadowSlider("Lift", value: $shadowBottomLift, range: 0...24)
            }
        case .layout:
            VStack(alignment: .leading, spacing: 12) {
                Text(glassText("Views")).font(.subheadline.weight(.semibold))
                Toggle(glassText("Enable icon view (⌘1)"), isOn: $enableIconView)
                Toggle(glassText("Enable compact list"), isOn: $enableCompactView)
                Toggle(glassText("Lowercase style"), isOn: $lowercaseTitles)
                LocaleOverrideControl()
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text(glassText("Spacing")).font(.subheadline.weight(.semibold))
                shadowSlider("Left padding", value: $leftPadding, range: 0...160)
                shadowSlider("Right padding", value: $rightPadding, range: 0...160)
                shadowSlider("Item vertical padding", value: $itemVerticalPadding, range: -10...30)
                shadowSlider("Between sections", value: $sectionSpacing, range: 0...120)
                shadowSlider("Below headers", value: $headerBottomPadding, range: 0...120)
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text(glassText("Columns")).font(.subheadline.weight(.semibold))
                shadowSlider("Brightness · light", value: $columnLightBrightness, range: 0...1, percent: true)
                shadowSlider("Brightness · dark", value: $columnDarkBrightness, range: 0...1, percent: true)
            }
        case .headers:
            VStack(alignment: .leading, spacing: 12) {
                Text(glassText("Fade")).font(.subheadline.weight(.semibold))
                ColorPicker("Colour · light", selection: headerColor(dark: false), supportsOpacity: false)
                ColorPicker("Colour · dark", selection: headerColor(dark: true), supportsOpacity: false)
                shadowSlider("Strength · light", value: $headerFadeStrengthLight, range: 0...1, percent: true)
                shadowSlider("Strength · dark", value: $headerFadeStrengthDark, range: 0...1, percent: true)
                shadowSlider("Reach below title", value: $headerFadeReach, range: 0...240)
                shadowSlider("Extra push lead", value: $headerPushLead, range: 0...120)
            }
        case .progress:
            VStack(alignment: .leading, spacing: 12) {
                Text(glassText("State button")).font(.subheadline.weight(.semibold))
                Toggle(glassText("Glass state button"), isOn: $stateGlass)
                shadowSlider("Size / button spacing", value: $stateGap, range: 0...32)
                shadowSlider("File priority spacing", value: $filePriorityGap, range: 0...32)
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text(glassText("Progress ring")).font(.subheadline.weight(.semibold))
                Toggle(glassText("Fill circle with progress"), isOn: $progressFilled)
                shadowSlider("Glow blur", value: $progressGlowBlur, range: 0...16)
                shadowSlider("Glow strength", value: $progressGlowStrength, range: 0...2)
                shadowSlider("Line width", value: $progressLineWidth, range: 0.5...5)
            }
        case .inspector:
            VStack(alignment: .leading, spacing: 12) {
                Toggle(glassText("Inspector blur enabled"), isOn: $inspectorBlurEnabled)
                shadowSlider("Blur radius", value: $inspectorBlurRadius, range: 0...24)
                durationSlider("Ease in", value: $inspectorBlurEaseIn)
                durationSlider("Ease out", value: $inspectorBlurEaseOut)
            }
        case .motion:
            VStack(alignment: .leading, spacing: 12) {
                Text(glassText("Selection")).font(.subheadline.weight(.semibold))
                durationSlider("Ease in", value: $selectionEaseIn)
                durationSlider("Ease out", value: $selectionEaseOut)
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text(glassText("Header transitions")).font(.subheadline.weight(.semibold))
                durationSlider("Background fade in", value: $headerBackgroundIn)
                durationSlider("Background fade out", value: $headerBackgroundOut)
                durationSlider("Title fade in", value: $headerTitleIn)
                durationSlider("Title fade out", value: $headerTitleOut)
            }
            Divider()
            shadowSlider("Drop blur", value: $dropBlurRadius, range: 0...32)
        }
    }

    private func hdrSlider(_ title: String, value: Binding<Double>) -> some View {
        VStack(spacing: 3) {
            HStack {
                Text(title)
                Spacer()
                Text(value.wrappedValue, format: .number.precision(.fractionLength(2))).monospacedDigit().foregroundStyle(.secondary)
            }.font(.caption)
            Slider(value: value, in: 0...3).accessibilityLabel(title)
        }
    }

    private func durationSlider(_ title: String, value: Binding<Double>) -> some View {
        VStack(spacing: 3) {
            HStack {
                Text(title)
                Spacer()
                Text("\(formatNumber(value.wrappedValue)) s")
                    .monospacedDigit().foregroundStyle(.secondary)
            }.font(.caption)
            Slider(value: value, in: 0...1.5).accessibilityLabel(title)
        }
    }

    private func shadowSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, percent: Bool = false, decimal: Bool = false) -> some View {
        VStack(spacing: 3) {
            HStack {
                Text(title)
                Spacer()
                Text(percent ? "\(Int((value.wrappedValue * 100).rounded()))%" : decimal ? formatNumber(value.wrappedValue) : "\(Int(value.wrappedValue.rounded()))")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.caption)
            Slider(value: value, in: range).accessibilityLabel(title)
        }
    }

}

private enum TuningSection: String, CaseIterable, Identifiable {
    case icons, selection, layout, headers, progress, inspector, motion, sorting
    var id: Self { self }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .icons: "folder"
        case .selection: "square.on.square"
        case .layout: "rectangle.split.3x1"
        case .headers: "textformat"
        case .progress: "arrow.down.circle"
        case .inspector: "sidebar.right"
        case .motion: "waveform.path"
        case .sorting: "arrow.up.arrow.down"
        }
    }
}
