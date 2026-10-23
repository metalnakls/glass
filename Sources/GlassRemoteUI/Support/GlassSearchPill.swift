import SwiftUI

/// One expanding native glass control used by the inspector and add flow.
struct GlassSearchPill: View {
    @Binding var text: String
    @Binding var isPresented: Bool
    var expandedWidth: CGFloat?
    var transitionNamespace: Namespace.ID?
    var transitionID = "search"
    var prompt = "Search Files"
    var inspectorFocus = true
    var permanentlyExpanded = false
    private var expanded: Bool { isPresented || permanentlyExpanded }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool
    @Namespace private var glassNamespace

    var body: some View {
        Group {
        if !expanded {
            GlassPillButton(iconOnly: true) {
                withAnimation(GlassMotion.animation(.control, reduceMotion: reduceMotion)) { isPresented = true }
                focused = true
            } label: { Image(systemName: "magnifyingglass") }
                .accessibilityLabel(glassText(prompt))
        } else {
        HStack {
            Button { focused = true; withAnimation(GlassMotion.animation(.control, reduceMotion: reduceMotion)) { isPresented = true } } label: { Image(systemName: "magnifyingglass").frame(width: expanded ? nil : InspectorGlassPill.height, height: InspectorGlassPill.height) }
                .buttonStyle(.plain).accessibilityLabel(glassText(prompt))
            if expanded {
                TextField(glassText(prompt), text: $text)
                    .textFieldStyle(.plain).focused($focused)
                    .focusedValue(\.glassInspectorFileFilterFocused, inspectorFocus)
                    .onExitCommand { isPresented = false; focused = false; text = "" }
                if !permanentlyExpanded { Button { withAnimation(GlassMotion.animation(.control, reduceMotion: reduceMotion)) { isPresented = false } } label: { Image(systemName: "xmark").frame(width: 28, height: 28).contentShape(Rectangle()) }
                    .buttonStyle(.plain).accessibilityLabel(glassText("Close search")) }
            }
        }
        .frame(width: expanded ? expandedWidth : nil)
        .frame(maxWidth: expanded && expandedWidth == nil ? .infinity : nil)
        .contentShape(Rectangle())
        .modifier(InspectorGlassPill(interactive: true, iconOnly: !expanded))
        }
        }
        .glassMotion(.control, value: expanded)
        .font(.body)
        .controlSize(GlassControlMetrics.size)
        .glassEffectID(transitionID, in: transitionNamespace ?? glassNamespace)
        .glassEffectTransition(.matchedGeometry)
        .onChange(of: isPresented) { _, presented in focused = presented; if !presented { text = "" } }
    }
}
