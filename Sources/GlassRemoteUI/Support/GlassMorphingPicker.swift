import SwiftUI

/// One shared glass pill for every control that opens a list of choices.
/// The system popover owns dismissal, focus return and the opening transition;
/// the glass container owns only the choice surface.
struct GlassMorphingPicker<Label: View, Choices: View>: View {
    @Binding var isPresented: Bool
    @ViewBuilder var label: () -> Label
    @ViewBuilder var choices: () -> Choices

    var body: some View {
        GlassPillButton { isPresented = true } label: {
            label().fontWeight(.semibold)
        }
        .fixedSize()
        .popover(isPresented: $isPresented, attachmentAnchor: .rect(.bounds), arrowEdge: nil) {
            GlassEffectContainer {
                choices()
                    .padding()
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: GlassModalMetrics.cornerRadius))
            }
            .presentationBackground(.clear)
        }
        .onExitCommand { isPresented = false }
    }
}

/// Picker choices use the environment's native row height, not a text-only hit target.
struct GlassPickerChoice<Label: View>: View {
    let action: () -> Void
    @ViewBuilder var label: () -> Label
    @Environment(\.defaultMinListRowHeight) private var minimumRowHeight

    var body: some View {
        Button(action: action) {
            label()
                .labelStyle(GlassPickerLabelStyle())
                .frame(maxWidth: .infinity, minHeight: minimumRowHeight, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Symbols occupy one system-sized column even when their intrinsic widths differ.
private struct GlassPickerLabelStyle: LabelStyle {
    @Environment(\.defaultMinListRowHeight) private var rowHeight
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.icon.frame(width: rowHeight, height: rowHeight)
            configuration.title
        }
    }
}
