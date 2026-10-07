import SwiftUI

public enum GlassSearchDestination {
    case mainList
    case inspector
}

private struct GlassMainListSearchPresentedKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

private struct GlassSearchDestinationKey: FocusedValueKey {
    typealias Value = GlassSearchDestination
}

public extension FocusedValues {
    var glassMainListSearchPresented: Binding<Bool>? {
        get { self[GlassMainListSearchPresentedKey.self] }
        set { self[GlassMainListSearchPresentedKey.self] = newValue }
    }

    var glassSearchDestination: GlassSearchDestination? {
        get { self[GlassSearchDestinationKey.self] }
        set { self[GlassSearchDestinationKey.self] = newValue }
    }
}
