import SwiftUI

/// One expanding native glass control used by the inspector and add flow.
struct GlassSearchPill: View {
    @Binding var text: String
    @Binding var isPresented: Bool
    var expandedWidth: CGFloat?
    var prompt = "Search Files"
    var inspectorFocus = true
    @FocusState private var focused: Bool
    @Namespace private var glassNamespace

    var body: some View {
        HStack(spacing: 8) {
            Button { isPresented = true } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.plain).accessibilityLabel(glassText(prompt))
            if isPresented {
                TextField(glassText(prompt), text: $text)
                    .textFieldStyle(.plain).focused($focused)
                    .focusedValue(\.glassInspectorFileFilterFocused, inspectorFocus)
                    .onExitCommand { isPresented = false }
                Button { isPresented = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel(glassText("Close search"))
            }
        }
        .frame(width: isPresented ? expandedWidth : nil)
        .frame(maxWidth: isPresented && expandedWidth == nil ? .infinity : nil)
        .modifier(InspectorGlassPill(interactive: true, iconOnly: !isPresented))
        .glassEffectID("search", in: glassNamespace)
        .onChange(of: isPresented) { _, presented in focused = presented; if !presented { text = "" } }
    }
}
