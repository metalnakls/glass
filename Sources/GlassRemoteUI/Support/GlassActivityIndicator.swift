import AppKit
import SwiftUI

enum GlassLoadingFeedback {
    static let delay: Duration = .seconds(6)
}

struct GlassActivityIndicator: View {
    enum Presentation { case deferred, alreadyDelayed }
    let label: LocalizedStringKey
    var presentation: Presentation = .deferred
    var controlSize: ControlSize = .small
    @State private var ready = false

    private var placeholderSize: CGSize {
        let indicator = NSProgressIndicator()
        indicator.style = .spinning
        switch controlSize {
        case .mini: indicator.controlSize = .mini
        case .small: indicator.controlSize = .small
        case .regular: indicator.controlSize = .regular
        case .large, .extraLarge: indicator.controlSize = .large
        @unknown default: indicator.controlSize = .regular
        }
        indicator.sizeToFit()
        return indicator.frame.size
    }

    var body: some View {
        Group {
            if presentation == .alreadyDelayed || ready {
                ProgressView().controlSize(controlSize).accessibilityLabel(label)
            } else {
                Color.clear.frame(width: placeholderSize.width, height: placeholderSize.height)
                    .accessibilityHidden(true)
            }
        }
            .task {
                ready = false
                do { try await Task.sleep(for: GlassLoadingFeedback.delay) } catch { return }
                guard !Task.isCancelled else { return }
                ready = true
            }
    }
}
