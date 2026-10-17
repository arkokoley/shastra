import SwiftUI
import ShastraCore

// Native implementations inspired by the interaction patterns in React Bits Micro.
// No React runtime or component source is bundled. Motion never performs an action.
enum MicroMotion {
    static let settle = Animation.spring(response: 0.32, dampingFraction: 0.76)
    static let quick = Animation.spring(response: 0.22, dampingFraction: 0.8)
    static let hover = Animation.easeOut(duration: 0.1)
}

private struct MicroLift: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled
    @ViewState private var hovered = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(!reduceMotion && enabled && hovered ? 1.018 : 1)
            .animation(reduceMotion ? nil : MicroMotion.hover, value: hovered && enabled)
            .onHover { hovered = $0 }
    }
}
extension View {
    func microLift() -> some View { modifier(MicroLift()) }
}

/// A small press/release spring; activation remains owned by SwiftUI's Button.
struct MicroPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(!reduceMotion && enabled && configuration.isPressed ? 0.96 : 1)
            .offset(y: !reduceMotion && enabled && configuration.isPressed ? 1 : 0)
            .animation(reduceMotion ? nil : MicroMotion.quick, value: configuration.isPressed)
            .microLift()
    }
}

/// Status Mark: the indeterminate arc is never presented as a percentage.
struct MicroStatusMark: View {
    enum Phase: Hashable { case idle, running, done, attention, failed, stopped }
    let phase: Phase
    var size: CGFloat = 13
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        ZStack {
            Circle().stroke(lineWidth: 1.4).opacity(phase == .running ? 0.22 : 0.45)
            if phase == .running {
                TimelineView(.animation(minimumInterval: 1.0 / 24, paused: reduceMotion || scenePhase != .active)) { context in
                    Circle().trim(from: 0, to: 0.62)
                        .stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                        .rotationEffect(.degrees(reduceMotion ? -90 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.15) / 1.15 * 360))
                }
            } else if phase != .idle {
                Image(systemName: symbol).font(.system(size: size * 0.55, weight: .bold))
                    .transition(.scale(scale: reduceMotion ? 1 : 0.6).combined(with: .opacity))
                    .id(phase)
            }
        }.frame(width: size, height: size)
            .animation(reduceMotion ? nil : MicroMotion.settle, value: phase)
            .accessibilityHidden(true)
    }
    private var symbol: String {
        switch phase { case .done: "checkmark"; case .attention: "exclamationmark"; case .failed, .stopped: "xmark"; default: "circle" }
    }
}
struct AgentStatusPill: View {
    let status: AgentTaskStatus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 5) {
            MicroStatusMark(phase: status.microPhase, size: 12)
            Text(status.displayName).contentTransition(.opacity)
        }.font(.system(size: 10, weight: .semibold)).foregroundStyle(status.color)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(status.color.opacity(0.10), in: Capsule())
            .animation(reduceMotion ? nil : MicroMotion.quick, value: status)
            .accessibilityElement(children: .ignore).accessibilityLabel(status.displayName)
    }
}
extension AgentTaskStatus {
    var microPhase: MicroStatusMark.Phase {
        switch self {
        case .queued, .waiting: .idle
        case .starting, .running: .running
        case .completed: .done
        case .needsInput: .attention
        case .failed: .failed
        case .cancelled, .interrupted: .stopped
        }
    }
}

/// Rubber Segment: equal-width native buttons with a shared spring selection thumb.
/// Buttons retain Tab/Space activation and expose selected state to VoiceOver.
struct MicroSegmentOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    var symbol: String? = nil
    var id: Value { value }
}
private struct MicroPressedKey: EnvironmentKey { static let defaultValue = false }
private extension EnvironmentValues {
    var microPressed: Bool {
        get { self[MicroPressedKey.self] }
        set { self[MicroPressedKey.self] = newValue }
    }
}
private struct SwitchPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.environment(\.microPressed, configuration.isPressed)
    }
}
private typealias MicroNamespace = SwiftUI.Namespace
struct MicroSegment<Value: Hashable>: View {
    let label: String
    @Binding var selection: Value
    let options: [MicroSegmentOption<Value>]
    @MicroNamespace private var thumb
    @FocusState private var focused: Value?
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                Button { selection = option.value } label: {
                    Group {
                        if let symbol = option.symbol { Image(systemName: symbol) }
                        else { Text(option.title).lineLimit(1) }
                    }.font(.system(size: 11, weight: selection == option.value ? .semibold : .regular))
                        .foregroundStyle(selection == option.value ? Surface.text : Surface.muted)
                        .frame(maxWidth: .infinity).frame(minWidth: 28, minHeight: 28)
                        .background {
                            if selection == option.value {
                                RoundedRectangle(cornerRadius: 7).fill(Surface.selected)
                                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Surface.accent.opacity(0.35)))
                                    .matchedGeometryEffect(id: "selection", in: thumb)
                                    .allowsHitTesting(false)
                            }
                        }.contentShape(Rectangle())
                }.buttonStyle(MicroPressStyle())
                    .focused($focused, equals: option.value)
                    .overlay {
                        RoundedRectangle(cornerRadius: 7).stroke(Surface.accent, lineWidth: 2)
                            .opacity(focused == option.value ? 1 : 0).allowsHitTesting(false)
                    }
                    .help(option.title)
                    .accessibilityLabel(option.title)
                    .accessibilityAddTraits(selection == option.value ? [.isSelected] : [])
            }
        }.padding(3).background(Surface.canvas.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
            .animation(reduceMotion ? nil : MicroMotion.settle, value: selection)
            .accessibilityElement(children: .contain).accessibilityLabel(label)
            .onMoveCommand { direction in
                guard enabled, let index = options.firstIndex(where: { $0.value == selection }) else { return }
                let next = direction == .left ? index - 1 : direction == .right ? index + 1 : index
                if options.indices.contains(next) { selection = options[next].value; focused = options[next].value }
            }
    }
}

/// Squish Switch: the thumb compresses on press and springs to the selected side.
struct MicroSwitchStyle: ToggleStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 8) {
                configuration.label
                SwitchThumb(on: configuration.isOn, reduceMotion: reduceMotion)
            }.frame(minHeight: 28).contentShape(Rectangle())
        }.buttonStyle(SwitchPressStyle())
            .foregroundStyle(Surface.text).opacity(enabled ? 1 : 0.5)
            .accessibilityRepresentation {
                Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.switch)
            }
    }
    private struct SwitchThumb: View {
        let on: Bool
        let reduceMotion: Bool
        @Environment(\.microPressed) private var pressed
        var body: some View {
            Capsule().fill(on ? Surface.accent : Surface.stroke)
                .frame(width: 34, height: 20)
                .overlay {
                    Circle().fill(on ? Surface.onAccent : Surface.text).frame(width: 14, height: 14)
                        .scaleEffect(x: !reduceMotion && pressed ? 1.18 : 1, y: !reduceMotion && pressed ? 0.88 : 1)
                        .offset(x: on ? 7 : -7)
                }
                .animation(reduceMotion ? nil : MicroMotion.quick, value: pressed)
                .animation(reduceMotion ? nil : MicroMotion.settle, value: on)
        }
    }
}

/// Spring Check: fill and tick draw together, while the label remains readable.
struct MicroCheckStyle: ToggleStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 4).fill(configuration.isOn ? Surface.accent : Surface.canvas)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(configuration.isOn ? Surface.accent : Surface.muted))
                    .overlay {
                        CheckStroke().trim(from: 0, to: configuration.isOn ? 1 : 0)
                            .stroke(Surface.onAccent, style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round)).padding(3)
                    }.frame(width: 16, height: 16)
                configuration.label
            }.frame(minHeight: 28).contentShape(Rectangle())
        }.buttonStyle(MicroPressStyle())
            .animation(reduceMotion ? nil : MicroMotion.settle, value: configuration.isOn)
            .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.checkbox) }
    }
    private struct CheckStroke: Shape {
        func path(in rect: CGRect) -> Path {
            Path { path in
                path.move(to: CGPoint(x: rect.minX, y: rect.midY))
                path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.37, y: rect.maxY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            }
        }
    }
}

/// Thought Line / Call Chip: a stable header that reveals recorded tool details.
/// These are historical tool events, not fabricated live progress or success states.
struct MicroToolTrace: View {
    let entries: [Entry]
    @ViewState private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var duration: String {
        let seconds = max(0, Int((entries.last?.createdAt ?? .now).timeIntervalSince(entries.first?.createdAt ?? .now)))
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "terminal").foregroundStyle(Surface.accent)
                    Text(entries.count == 1 ? "Tool activity" : "\(entries.count) tool actions")
                    Spacer()
                    if entries.count > 1 { Text(duration).monospacedDigit().font(.system(size: 10)).foregroundStyle(Surface.muted) }
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }.font(.system(size: 12)).foregroundStyle(Surface.muted).padding(.horizontal, 10).padding(.vertical, 8)
                    .background(Surface.selected.opacity(expanded ? 0.8 : 0.25), in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
            }.buttonStyle(MicroPressStyle())
                .accessibilityLabel("\(entries.count) recorded tool actions")
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                .accessibilityHint("Show or hide recorded tool output")
            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(entries) { entry in
                        Text(entry.text).font(.system(size: 11, design: .monospaced)).foregroundStyle(Surface.muted)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        if entry.id != entries.last?.id { Divider() }
                    }
                }.padding(12).transition(reduceMotion ? .identity : .asymmetric(
                    insertion: .opacity.combined(with: .offset(y: -6)), removal: .opacity))
            }
        }.animation(reduceMotion ? nil : MicroMotion.settle, value: expanded).padding(.vertical, 3)
    }
}

/// Folder Float's small paper lift is attached to the existing file-tree control.
struct MicroFolderIcon: View {
    let expanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 1.5).fill(Surface.accent.opacity(0.65)).frame(width: 8, height: 10)
                .rotationEffect(.degrees(expanded && !reduceMotion ? -12 : 0))
                .offset(x: expanded && !reduceMotion ? 2 : 0, y: expanded && !reduceMotion ? -4 : 0)
                .opacity(expanded ? 1 : 0)
            Image(systemName: expanded ? "folder.fill" : "folder").foregroundStyle(Surface.accent)
        }.frame(width: 16, height: 18)
            .animation(reduceMotion ? nil : MicroMotion.settle, value: expanded).accessibilityHidden(true)
    }
}

/// Lattice Loader: shown only while a real native turn is running.
struct MicroActivityClock: View {
    let startedAt: Date
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        HStack(spacing: 7) {
            TimelineView(.animation(minimumInterval: 0.1, paused: reduceMotion || scenePhase != .active)) { context in
                let step = context.date.timeIntervalSinceReferenceDate * 3
                HStack(spacing: 2) {
                    ForEach(0..<3) { column in
                        VStack(spacing: 2) {
                            ForEach(0..<3) { row in
                                RoundedRectangle(cornerRadius: 0.8).fill(Surface.accent)
                                    .frame(width: 3, height: 3)
                                    .opacity(reduceMotion ? 0.65 : 0.25 + 0.75 * (sin(step - Double(column + row) * 0.7) + 1) / 2)
                            }
                        }
                    }
                }
            }.frame(width: 13, height: 13).accessibilityHidden(true)
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                let seconds = max(0, Int(context.date.timeIntervalSince(startedAt)))
                Text("\(seconds / 60):\(String(format: "%02d", seconds % 60))").monospacedDigit()
            }.font(.system(size: 10)).foregroundStyle(Surface.muted)
        }.accessibilityLabel("Elapsed turn time")
    }
}
