import SwiftUI

/// One native slider presentation for Tune, including its icon controls.
/// Units describe stored values; formatting never changes their ranges or meaning.
struct GlassTuningSlider: View {
    enum Unit {
        case points, seconds, percent, multiplier, degrees, decimal
        func text(_ value: Double) -> String {
            let number = value.formatted(.number.precision(.fractionLength(0...2)))
            switch self {
            case .points: return "\(number) pt"
            case .seconds: return "\(number) s"
            case .percent: return value.formatted(.percent.precision(.fractionLength(0...1)))
            case .multiplier: return "\(number)×"
            case .degrees: return "\(number)°"
            case .decimal: return number
            }
        }
    }
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var unit: Unit = .points

    init(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, unit: Unit = .points) {
        self.title = title
        _value = value
        self.range = range
        self.unit = unit
    }

    var body: some View {
        VStack(alignment: .leading) {
            HStack(alignment: .firstTextBaseline) {
                Text(glassText(title)).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Text(unit.text(value)).monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.caption)
            .accessibilityHidden(true)
            Slider(value: $value, in: range) { Text(glassText(title)) }
                .labelsHidden()
                .accessibilityValue(unit.text(value))
        }
    }
}
