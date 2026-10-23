import AppKit
import SwiftUI

enum MotionComparisonTopic: Int, CaseIterable, Identifiable, Codable {
    case keyboard, timing, scrolling, press, reduced
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .keyboard: "Keyboard search"
        case .timing: "Control timing"
        case .scrolling: "Inspector selection"
        case .press: "Press and release"
        case .reduced: "Reduce Motion"
        }
    }
    var instruction: String {
        switch self {
        case .keyboard: "Press ⌘F to expand both searches. Escape closes them."
        case .timing: "Replay the same control change at both speeds."
        case .scrolling: "Scroll both down, then switch torrents to compare the reset."
        case .press: "Press and hold each button, then release."
        case .reduced: "Reduce Motion is simulated on both sides. Compare a snap with a crossfade."
        }
    }
    func caption(after: Bool) -> String {
        switch self {
        case .keyboard: after ? "Immediate keyboard response" : "Animated keyboard response"
        case .timing: after ? "200 ms · ease-out" : "350 ms · smooth"
        case .scrolling: after ? "Immediate scroll reset" : "Animated scroll reset · 350 ms"
        case .press: after ? "160 ms press · 100 ms release" : "120 ms press and release"
        case .reduced: after ? "200 ms crossfade · no movement" : "Immediate change · no movement"
        }
    }
}

struct MotionComparisonChoices: Codable, Equatable {
    enum Preference: String, Codable, CaseIterable { case before = "Before", after = "After", neither = "Neither" }
    var selections: [String: Preference] = [:]
    subscript(_ topic: MotionComparisonTopic) -> Preference? {
        get { selections[String(topic.rawValue)] }
        set { selections[String(topic.rawValue)] = newValue }
    }
    var summary: String {
        MotionComparisonTopic.allCases.map { "\($0.title): \(self[$0]?.rawValue ?? "Not chosen")" }.joined(separator: "\n")
    }
}

/// A standalone sandbox of visual samples. Choices do not change production motion.
public struct MotionComparisonView: View {
    @AppStorage("GlassMotionComparison.choices.v1") private var savedChoices = Data()
    @State private var topic = MotionComparisonTopic.keyboard
    @State private var alternate = false
    @State private var scrollRequest = 0
    @State private var simulateReduced = false
    @Environment(\.accessibilityReduceMotion) private var systemReduced

    public init() {}
    private var reduced: Bool { systemReduced || simulateReduced || topic == .reduced }
    private var choices: MotionComparisonChoices {
        (try? JSONDecoder().decode(MotionComparisonChoices.self, from: savedChoices)) ?? MotionComparisonChoices()
    }

    public var body: some View {
        VStack(spacing: 20) {
            HStack {
                Button { navigate(-1) } label: { Image(systemName: "chevron.left") }
                    .disabled(topic == .keyboard).accessibilityLabel("Previous comparison")
                Spacer()
                VStack(spacing: 4) {
                    Text("\(topic.rawValue + 1) of 5").font(.caption).foregroundStyle(.secondary)
                    Text(topic.title).font(.title2.weight(.semibold))
                }
                Spacer()
                Button { navigate(1) } label: { Image(systemName: "chevron.right") }
                    .disabled(topic == .reduced).accessibilityLabel("Next comparison")
            }
            Text(topic.instruction).foregroundStyle(.secondary)
            HStack(spacing: 20) {
                sample(after: false)
                sample(after: true)
            }
            .id(topic)
            .frame(maxHeight: .infinity)
            HStack {
                if topic == .keyboard {
                    Button("Expand both (⌘F)") { alternate = true }
                    Button("Close both") { alternate = false }
                } else if topic != .press {
                    if topic == .scrolling { Button("Scroll both down") { scrollRequest += 1 } }
                    Button(topic == .scrolling ? "Switch torrent" : "Replay change") { alternate.toggle() }
                }
                Spacer()
                if topic != .reduced {
                    Toggle("Simulate Reduce Motion", isOn: $simulateReduced)
                        .toggleStyle(.checkbox).disabled(systemReduced)
                }
            }
            Divider()
            HStack {
                Text("I prefer").fontWeight(.medium)
                ForEach(MotionComparisonChoices.Preference.allCases, id: \.self) { preference in
                    Button {
                        var updated = choices
                        updated[topic] = preference
                        if let data = try? JSONEncoder().encode(updated) { savedChoices = data }
                    } label: {
                        Label(preference.rawValue, systemImage: choices[topic] == preference ? "checkmark.circle.fill" : "circle")
                    }
                    .accessibilityAddTraits(choices[topic] == preference ? .isSelected : [])
                }
                Spacer()
                Text("\(choices.selections.count)/5 saved").foregroundStyle(.secondary)
                Button("Copy choices") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(choices.summary, forType: .string)
                }
            }
            Text("Choices are saved locally. These previews do not change Glass’s current animations.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(minWidth: 840, idealWidth: 920, minHeight: 590, idealHeight: 640)
        .focusedSceneValue(\.glassMainListSearchPresented, topic == .keyboard ? $alternate : nil)
        .onExitCommand { alternate = false }
    }

    private func navigate(_ direction: Int) {
        guard let next = MotionComparisonTopic(rawValue: topic.rawValue + direction) else { return }
        // Changing pages is immediate; it must not contaminate the comparison.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { topic = next; alternate = false; scrollRequest = 0 }
    }

    private func sample(after: Bool) -> some View {
        VStack(spacing: 14) {
            Text(after ? "After" : "Before").font(.headline)
            Text(topic.caption(after: after)).font(.caption).foregroundStyle(.secondary)
            MotionComparisonSample(topic: topic, after: after, alternate: alternate,
                scrollRequest: scrollRequest, reduced: reduced)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
                .background(.background, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(.quaternary))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MotionComparisonSample: View {
    let topic: MotionComparisonTopic
    let after: Bool
    let alternate: Bool
    let scrollRequest: Int
    let reduced: Bool
    @State private var query = ""
    private var animation: Animation? {
        if reduced { return after ? GlassMotionCandidate.crossfade : nil }
        if after && (topic == .keyboard || topic == .scrolling) { return nil }
        return after ? GlassMotionCandidate.control : GlassMotion.control
    }

    var body: some View {
        Group {
            switch topic {
            case .keyboard: search
            case .timing, .reduced: changingControl
            case .scrolling: scrollSample
            case .press:
                Button("Press and hold") {}
                    .buttonStyle(ComparisonPressStyle(after: after, reduced: reduced))
            }
        }
    }

    private var search: some View {
        HStack {
            Image(systemName: "magnifyingglass")
            if alternate {
                TextField("Search Files", text: $query)
                    .textFieldStyle(.plain).transition(.opacity)
                Image(systemName: "xmark")
            }
        }
        .padding(12)
        .frame(width: reduced ? 260 : alternate ? 260 : 42, height: 42)
        .glassEffect(.regular.interactive(), in: .capsule)
        .animation(animation, value: alternate)
    }

    private var changingControl: some View {
        ZStack {
            if alternate {
                Label("Search Files", systemImage: "magnifyingglass")
                    .id("search").transition(.opacity)
            } else {
                HStack {
                    ProgressView(value: 0.35).frame(width: 130)
                    Text("56 GB").monospacedDigit()
                }.id("progress").transition(.opacity)
            }
        }
        .padding(14)
        .frame(width: reduced ? 270 : alternate ? 270 : 240, height: 48)
        .glassEffect(.regular.interactive(), in: .capsule)
        .animation(animation, value: alternate)
    }

    private var scrollSample: some View {
        VStack {
            Text(alternate ? "Torrent B" : "Torrent A").font(.headline)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(0..<24) { index in
                            Text("Episode \(index + 1)")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10).id(index)
                            Divider()
                        }
                    }
                }
                .onChange(of: scrollRequest) { _, _ in proxy.scrollTo(18, anchor: .top) }
                .onChange(of: alternate) { _, _ in
                    withAnimation(animation) { proxy.scrollTo(0, anchor: .top) }
                }
            }
        }
    }
}

private struct ComparisonPressStyle: ButtonStyle {
    let after: Bool
    let reduced: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 28).padding(.vertical, 16)
            .glassEffect(.regular.interactive(), in: .capsule)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(reduced ? (after ? GlassMotionCandidate.crossfade : nil) :
                (after ? GlassMotionCandidate.press(down: configuration.isPressed) : GlassMotion.feedback),
                value: configuration.isPressed)
    }
}
