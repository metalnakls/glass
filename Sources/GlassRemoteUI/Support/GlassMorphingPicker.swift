import SwiftUI

/// One source shape and effect identity for every pill that expands into choices.
struct GlassMorphingPicker<Label: View, Choices: View>: View {
    @Binding var isPresented: Bool
    var alignment: Alignment = .topLeading
    @ViewBuilder var label: () -> Label
    @ViewBuilder var choices: () -> Choices
    @Namespace private var glass
    @State private var size = CGSize.zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GlassEffectContainer {
            ZStack(alignment: alignment) {
                if isPresented {
                    Color.clear.frame(width: size.width, height: size.height).allowsHitTesting(false)
                } else {
                    GlassPillButton { isPresented = true } label: { label().fontWeight(.semibold) }
                        .fixedSize()
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
                        .glassEffectID("picker", in: glass)
                        .glassEffectTransition(.matchedGeometry)
                        .transition(.blurReplace)
                }
            }
            .overlay(alignment: alignment) {
                if isPresented {
                    choices()
                        .padding()
                        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: GlassModalMetrics.cornerRadius))
                        .glassEffectID("picker", in: glass)
                        .glassEffectTransition(.matchedGeometry)
                        .transition(.blurReplace)
                }
            }
        }
        .animation(reduceMotion ? nil : .smooth, value: isPresented)
        .onExitCommand { isPresented = false }
    }
}
