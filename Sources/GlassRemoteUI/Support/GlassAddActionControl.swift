import Foundation
import GlassRemoteServices
import SwiftUI

/// Tune-selectable arrangements for the Add action and its destination.
enum GlassAddActionLayout: String, CaseIterable, Identifiable, Equatable {
    case beside
    case wide
    case stacked

    var id: String { rawValue }

    var title: String {
        switch self {
        case .beside: "Side by side"
        case .wide: "Add to location"
        case .stacked: "Two-line"
        }
    }
}

/// Owns the glass surface shared by the Add action and the location picker.
/// The Add button always performs the import; the trailing chevron changes the
/// destination in place.
struct GlassAddActionControl: View {
    let model: RemoteAppModel
    let platformIntegration: any GlassPlatformIntegrating
    @Binding var sourceID: UUID
    @Binding var directory: String?
    @Binding var defaultDirectory: String?
    @Binding var errorMessage: String?
    var title: String
    var isEnabled = true
    var isLocationDisabled = false
    var prefersMacDownloads = false
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppearanceStorage("GlassAdd.actionLayout") private var layoutName = GlassAddActionLayout.wide.rawValue

    private var layout: GlassAddActionLayout {
        GlassAddActionLayout(rawValue: layoutName) ?? .wide
    }

    var body: some View {
        Group {
            switch layout {
            case .beside:
                besideControl
            case .wide:
                wideControl
            case .stacked:
                stackedControl
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.22), value: layout)
    }

    private var besideControl: some View {
        HStack(spacing: 8) {
            locationPicker
            GlassPillButton(action: action) {
                Text(glassText(title)).id(title).transition(.blurReplace)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!isEnabled)
            .animation(reduceMotion ? nil : .smooth, value: title)
        }
    }

    private var wideControl: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: 4) {
                    Text(widePrefix).fixedSize()
                    Text(locationName).textCase(nil)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .lineLimit(1)
                .padding(.leading, 14)
                .padding(.trailing, 10)
                .frame(minWidth: 150, alignment: .leading)
                .frame(height: GlassControlMetrics.height)
                .contentShape(Rectangle())
            }
            .buttonStyle(GlassAddActionPressStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(!isEnabled)
            .opacity(isEnabled ? 1 : 0.45)
            .accessibilityLabel(Text(widePrefix + " " + locationName))

            Divider().frame(height: 18).opacity(0.3)
            compactLocationPicker
        }
        .frame(height: GlassControlMetrics.height)
        .glassEffect(.regular.interactive(), in: Capsule())
    }

    private var stackedControl: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(glassText(title)).font(.subheadline.weight(.semibold))
                    Text(locationName).textCase(nil).font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.leading, 14)
                .padding(.trailing, 10)
                .frame(minWidth: 150, alignment: .leading)
                .frame(height: GlassControlMetrics.height)
                .contentShape(Rectangle())
            }
            .buttonStyle(GlassAddActionPressStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(!isEnabled)
            .opacity(isEnabled ? 1 : 0.45)
            .accessibilityLabel(Text(glassText(title) + ", " + locationName))

            Divider().frame(height: 18).opacity(0.3)
            compactLocationPicker
        }
        .frame(height: GlassControlMetrics.height)
        .glassEffect(.regular.interactive(), in: Capsule())
    }

    private var locationPicker: TorrentDownloadLocationPicker {
        TorrentDownloadLocationPicker(
            model: model,
            platformIntegration: platformIntegration,
            sourceID: $sourceID,
            directory: $directory,
            defaultDirectory: $defaultDirectory,
            errorMessage: $errorMessage,
            isDisabled: isLocationDisabled,
            prefersMacDownloads: prefersMacDownloads,
            trigger: .full,
            showsFreeSpace: false
        )
    }

    private var compactLocationPicker: some View {
        TorrentDownloadLocationPicker(
            model: model,
            platformIntegration: platformIntegration,
            sourceID: $sourceID,
            directory: $directory,
            defaultDirectory: $defaultDirectory,
            errorMessage: $errorMessage,
            isDisabled: isLocationDisabled,
            prefersMacDownloads: prefersMacDownloads,
            trigger: .compact,
            showsFreeSpace: false
        )
    }

    private var locationName: String { locationPicker.resolvedLocationName }

    private var widePrefix: String {
        title == "Stall" ? glassText("Stall in") : glassText("Add to")
    }
}

/// Press feedback belongs to the part of the capsule that performs the add.
private struct GlassAddActionPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
