import AppKit
import SwiftUI

public struct SelectionAppearanceView: View {
    private let externalSection: Binding<TuningSection>?
    private let testSession: TorrentTestSessionState?
    public init(testSession: TorrentTestSessionState? = nil, section: Binding<TuningSection>? = nil) {
        self.testSession = testSession
        self.externalSection = section
    }
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
    @AppearanceStorage("GlassInspector.nativeSelectionHighlight") private var nativeInspectorHighlight = false
    @AppearanceStorage("GlassInspector.fileSideInset") private var inspectorSideInset = 18.0
    @AppearanceStorage("GlassInspector.permanentSearch") private var permanentInspectorSearch = true
    @AppearanceStorage("GlassInspector.showPup") private var showInspectorPup = true
    @AppearanceStorage("GlassAdd.showIcon") private var addIcon = true
    @AppearanceStorage("GlassAdd.titleTopPadding") private var addTitleTopPadding = 20.0
    @AppearanceStorage("GlassAdd.titleLeftPadding") private var addTitleLeftPadding = 20.0
    @AppearanceStorage("GlassAdd.locationColumns") private var locationColumns = 3
    @AppearanceStorage("GlassAdd.recentLocations") private var recentLocations = 4
    @AppearanceStorage("GlassHaptics.enabled") private var hapticsEnabled = true
    @AppearanceStorage("GlassHaptics.playPause") private var stateHaptics = true
    @AppearanceStorage("GlassHaptics.swipe") private var swipeHaptics = true
    @AppearanceStorage("GlassHaptics.drag") private var dragHaptics = true
    @AppearanceStorage("GlassHaptics.selection") private var selectionHaptics = true
    @State private var backgroundEnabled = GlassBackgroundService.isEnabled
    @State private var saveStatus: String?
    @SceneStorage("GlassTune.section") private var sectionName = TuningSection.icons.rawValue
    private var section: TuningSection {
        externalSection?.wrappedValue ?? TuningSection(rawValue: sectionName) ?? .icons
    }
    private func selectSection(_ selection: TuningSection) {
        if let externalSection { externalSection.wrappedValue = selection }
        else { sectionName = selection.rawValue }
    }

    @AppearanceStorage("GlassList.leftPadding") private var leftPadding = UserDefaults.standard.object(forKey: "GlassList.sidePadding") as? Double ?? 18
    @AppearanceStorage("GlassList.rightPadding") private var rightPadding = UserDefaults.standard.object(forKey: "GlassList.sidePadding") as? Double ?? 18
    @AppearanceStorage("GlassList.itemVerticalPadding") private var itemVerticalPadding = 0.0
    @AppearanceStorage("GlassList.sectionSpacing") private var sectionSpacing = 16.0
    @AppearanceStorage("GlassList.initialPadding") private var initialPadding = 16.0
    @AppearanceStorage("GlassList.endPadding") private var endPadding = 68.0
    @AppearanceStorage("GlassList.headerBottomPadding") private var headerBottomPadding = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
    @AppearanceStorage("GlassList.headerTitleOut") private var headerTitleOut = 0.22
    @AppearanceStorage("GlassList.headerPushLead") private var headerPushLead = 0.0
    private func highlightColor(dark: Bool) -> Binding<Color> {
        Binding(get: { Color(nsColor: HeaderFadeColor.decode(dark ? highlightColorDark : highlightColorLight)) }, set: {
            let hex = HeaderFadeColor.encode(NSColor($0))
            if dark { highlightColorDark = hex } else { highlightColorLight = hex }
        })
    }

    @State private var sectionPickerPresented = false

    public var body: some View {
        GlassChromeScrollView {
            VStack(alignment: .leading) {
                controls
            }
            .id(section.rawValue)
            .glassTransition()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
        }
        .glassFloatingChrome(top: {
            HStack {
                GlassMorphingPicker(isPresented: $sectionPickerPresented) {
                    HStack {
                        Label(glassText(section.title), systemImage: section.symbol)
                        Image(systemName: "chevron.down").font(.caption)
                    }
                } choices: {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(TuningSection.allCases) { item in
                            GlassPickerChoice {
                                sectionPickerPresented = false
                                withAnimation(GlassMotion.animation(.control, reduceMotion: reduceMotion)) { selectSection(item) }
                            } label: {
                                Label(glassText(item.title), systemImage: item.symbol)
                            }
                        }
                    }.fixedSize(horizontal: true, vertical: false)
                }
                .accessibilityLabel("Tune section")
                Spacer()
            }
        }, bottom: { footer })
        .glassMotion(.control, value: section)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: .top)
        .glassTextStyle()
        .onDisappear {
            guard let testSession, testSession.isEnabled else { return }
            Task { await testSession.end() }
        }
    }

    @ViewBuilder private var footer: some View {
        VStack(alignment: .leading) {
            HStack {
                if let testSession {
                    footerButton(testSession.isEnabled ? "Stop testing" : "Test Torrents",
                        symbol: testSession.isEnabled ? "stop.fill" : "play.fill") {
                        if testSession.isEnabled { Task { await testSession.end() } }
                        else { testSession.start() }
                    }
                }
                footerButton("Reset appearance", symbol: "arrow.counterclockwise") {
                    AppearancePreferences.shared.resetToDefaults()
                }
                Spacer()
                footerButton("Save", symbol: "square.and.arrow.down") {
                    do {
                        if try GlassAppearanceDefaults.save() { saveStatus = "Appearance defaults saved." }
                    } catch { saveStatus = error.localizedDescription }
                }
            }
            if let saveStatus { Text(saveStatus).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func footerButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        GlassPillButton(iconOnly: true, action: action) { Image(systemName: symbol) }
            .accessibilityLabel(glassText(title))
            .help(glassText(title))
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
                    GlassTuningSlider("Icon scale", value: $funScale, range: 1...1.8, unit: .multiplier)
                    GlassTuningSlider("Icon tilt", value: $funTilt, range: 0...16, unit: .degrees)
                    Toggle(glassText("Coloured poster shadows"), isOn: $coloredShadows)
                }
            }
        case .selection:
            VStack(alignment: .leading, spacing: 12) {
                Text(glassText("Highlight")).font(.subheadline.weight(.semibold))
                ColorPicker("Colour · light", selection: highlightColor(dark: false), supportsOpacity: false)
                ColorPicker("Colour · dark", selection: highlightColor(dark: true), supportsOpacity: false)
                GlassTuningSlider("Width", value: $highlightWidth, range: -80...160)
                GlassTuningSlider("HDR brightness · light", value: $selectedHDRWhiteLight, range: 0...3, unit: .decimal)
                GlassTuningSlider("HDR brightness · dark", value: $selectedHDRWhiteDark, range: 0...3, unit: .decimal)
                GlassTuningSlider("HDR glow softness", value: $selectedHDRSoftness, range: 0...32)
                GlassTuningSlider("HDR glow spread", value: $selectedHDRSpread, range: 0...24)
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text(glassText("Shadow above")).font(.subheadline.weight(.semibold))
                GlassTuningSlider("Strength", value: $shadowTopStrength, range: 0...0.65, unit: .percent)
                GlassTuningSlider("Softness", value: $shadowTopSoftness, range: 0...32)
                GlassTuningSlider("Lift", value: $shadowTopLift, range: 0...24)
            }
            VStack(alignment: .leading, spacing: 12) {
                Text(glassText("Shadow below")).font(.subheadline.weight(.semibold))
                GlassTuningSlider("Strength", value: $shadowBottomStrength, range: 0...0.65, unit: .percent)
                GlassTuningSlider("Softness", value: $shadowBottomSoftness, range: 0...32)
                GlassTuningSlider("Lift", value: $shadowBottomLift, range: 0...24)
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
                GlassTuningSlider("Left padding", value: $leftPadding, range: 0...160)
                GlassTuningSlider("Right padding", value: $rightPadding, range: 0...160)
                GlassTuningSlider("Item vertical padding", value: $itemVerticalPadding, range: -10...30)
                GlassTuningSlider("Between sections", value: $sectionSpacing, range: 0...120)
                GlassTuningSlider("Before first header", value: $initialPadding, range: 0...160)
                GlassTuningSlider("After last item", value: $endPadding, range: 0...160)
                GlassTuningSlider("Below headers", value: $headerBottomPadding, range: 0...120)
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text(glassText("Columns")).font(.subheadline.weight(.semibold))
                GlassTuningSlider("Brightness · light", value: $columnLightBrightness, range: 0...1, unit: .percent)
                GlassTuningSlider("Brightness · dark", value: $columnDarkBrightness, range: 0...1, unit: .percent)
            }
        case .headers:
            VStack(alignment: .leading, spacing: 12) {
                Text(glassText("Header backdrop")).font(.subheadline.weight(.semibold))
                Text(glassText("The native material follows the window appearance and fades as a header leaves."))
                    .font(.caption).foregroundStyle(.secondary)
                GlassTuningSlider("Strength · light", value: $headerFadeStrengthLight, range: 0...1, unit: .percent)
                GlassTuningSlider("Strength · dark", value: $headerFadeStrengthDark, range: 0...1, unit: .percent)
                GlassTuningSlider("Reach below title", value: $headerFadeReach, range: 0...240)
                GlassTuningSlider("Extra push lead", value: $headerPushLead, range: 0...120)
                Text(glassText("Section titles stay visible while scrolling. Large jumps go straight to the current section."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .progress:
            VStack(alignment: .leading, spacing: 12) {
                Text(glassText("State button")).font(.subheadline.weight(.semibold))
                Toggle(glassText("Glass state button"), isOn: $stateGlass)
                GlassTuningSlider("Size / button spacing", value: $stateGap, range: 0...32)
                GlassTuningSlider("File priority spacing", value: $filePriorityGap, range: 0...32)
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text(glassText("Progress ring")).font(.subheadline.weight(.semibold))
                Toggle(glassText("Fill circle with progress"), isOn: $progressFilled)
                GlassTuningSlider("Glow blur", value: $progressGlowBlur, range: 0...16)
                GlassTuningSlider("Glow strength", value: $progressGlowStrength, range: 0...2, unit: .percent)
                GlassTuningSlider("Line width", value: $progressLineWidth, range: 0.5...5)
            }
        case .add:
            Toggle(glassText("Torrent icon"), isOn: $addIcon)
            GlassTuningSlider("Title top padding", value: $addTitleTopPadding, range: 0...80)
            GlassTuningSlider("Title left padding", value: $addTitleLeftPadding, range: 0...80)
            Stepper(glassText("Location icons per row: \(locationColumns)"), value: $locationColumns, in: 1...6)
            Stepper(glassText("Recent folders: \(recentLocations)"), value: $recentLocations, in: 0...12)
        case .haptics:
            Toggle(glassText("Haptics"), isOn: $hapticsEnabled)
            Group {
                Toggle(glassText("Play and pause"), isOn: $stateHaptics)
                Toggle(glassText("Swiping"), isOn: $swipeHaptics)
                Toggle(glassText("Dragging"), isOn: $dragHaptics)
                Toggle(glassText("Selection"), isOn: $selectionHaptics)
            }.disabled(!hapticsEnabled)
        case .background:
            Toggle(glassText("Background worker"), isOn: Binding(get: { backgroundEnabled }, set: { enabled in
                do { try GlassBackgroundService.setEnabled(enabled); backgroundEnabled = enabled }
                catch { saveStatus = error.localizedDescription }
            }))
            Text(glassText("Smart Rename torrent files in Downloads and check saved servers for completed downloads while Glass is closed."))
                .font(.caption).foregroundStyle(.secondary)
            if GlassBackgroundService.requiresApproval {
                Text(glassText("Allow Glass in Login Items to finish enabling the worker.")).font(.caption)
            }
        case .inspector:
            Toggle(glassText("Show pup"), isOn: $showInspectorPup)
                .help(glassText("Show the decorative pup when the Inspector is empty."))
            Toggle(glassText("Permanent full-width search"), isOn: $permanentInspectorSearch)
            Toggle(glassText("Native selection highlight"), isOn: $nativeInspectorHighlight)
            GlassTuningSlider("File side padding", value: $inspectorSideInset, range: 8...40)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Toggle(glassText("Inspector blur enabled"), isOn: $inspectorBlurEnabled)
                GlassTuningSlider("Blur radius", value: $inspectorBlurRadius, range: 0...24)
                GlassTuningSlider("Ease in", value: $inspectorBlurEaseIn, range: 0...1.5, unit: .seconds)
                GlassTuningSlider("Ease out", value: $inspectorBlurEaseOut, range: 0...1.5, unit: .seconds)
            }
        case .motion:
            VStack(alignment: .leading, spacing: 12) {
                Text(glassText("Selection")).font(.subheadline.weight(.semibold))
                GlassTuningSlider("Ease in", value: $selectionEaseIn, range: 0...1.5, unit: .seconds)
                GlassTuningSlider("Ease out", value: $selectionEaseOut, range: 0...1.5, unit: .seconds)
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text(glassText("Header transitions")).font(.subheadline.weight(.semibold))
                GlassTuningSlider("Background fade in", value: $headerBackgroundIn, range: 0...1.5, unit: .seconds)
                GlassTuningSlider("Background fade out", value: $headerBackgroundOut, range: 0...1.5, unit: .seconds)
                GlassTuningSlider("Removed title exit", value: $headerTitleOut, range: 0...1.5, unit: .seconds)
            }
            Divider()
            GlassTuningSlider("Drop blur", value: $dropBlurRadius, range: 0...32)
        }
    }


}

public enum TuningSection: String, CaseIterable, Identifiable {
    case icons, selection, layout, headers, progress, inspector, motion, sorting, add, haptics, background
    public var id: Self { self }
    public var title: String { rawValue.capitalized }
    public var symbol: String {
        switch self {
        case .icons: "folder"
        case .selection: "square.on.square"
        case .layout: "rectangle.split.3x1"
        case .headers: "textformat"
        case .progress: "arrow.down.circle"
        case .inspector: "sidebar.right"
        case .motion: "waveform.path"
        case .sorting: "arrow.up.arrow.down"
        case .add: "plus"
        case .haptics: "hand.tap"
        case .background: "gearshape.2"
        }
    }
}
