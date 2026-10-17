import AppKit
import SwiftUI

/// Neutral reading surfaces and a restrained graphite control palette.
/// Native controls retain keyboard navigation and system focus treatment.
enum Surface {
    static func color(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((value >> 16) & 255) / 255,
                           green: Double((value >> 8) & 255) / 255,
                           blue: Double(value & 255) / 255, alpha: 1)
        })
    }
    static func adaptive(_ light: Double, _ dark: Double) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            NSColor(white: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light, alpha: 1)
        })
    }
    static let canvas = color(0xF2F2F0, 0x232426)
    static let sidebar = color(0xECECEA, 0x1F2022)
    static let dock = color(0xE8E9E7, 0x26282A)
    static let raised = color(0xFAFAF8, 0x2A2C2F)
    static let selected = color(0xE2E3E2, 0x34373A)
    static let stroke = color(0xD6D7D5, 0x45494D)
    static let muted = color(0x62676C, 0xADB1B5)
    static let text = color(0x2F3235, 0xE3E5E7)
    static let accent = color(0x545D66, 0xAEB8C2)
    static let onAccent = color(0xFAFAF8, 0x23272B)
    static let hover = color(0xE8E9E7, 0x303336)
    static let code = color(0xEFEFEE, 0x202224)
    static let warning = color(0x876A37, 0xC1A878)
    static let success = color(0x417057, 0x8AAF91)
    static let danger = color(0xAC5A5F, 0xD89599)
}

enum Design {
    static let headerHeight: CGFloat = 40
    static let windowControlsInset: CGFloat = 72
    static let sidebarWidth: CGFloat = 252
    static let headerInset: CGFloat = 16
    static let contentInset: CGFloat = 24
    static func age(_ date: Date) -> String {
        let seconds = max(0, Date.now.timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86400))d"
    }
    static let controlRadius: CGFloat = 8
    static let cardRadius: CGFloat = 14
    static let composerRadius: CGFloat = 20
    static let readingWidth: CGFloat = 740
}

struct ShastraMark: View {
    var size: CGFloat = 38
    private static let artwork: NSImage = {
        guard let url = Bundle.module.url(forResource: "ShastraMark", withExtension: "svg"),
              let image = NSImage(contentsOf: url) else {
            preconditionFailure("Shastra logo resource is missing")
        }
        return image
    }()
    var body: some View {
        Image(nsImage: Self.artwork)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct ShastraWordmark: View {
    var size: CGFloat = 18
    var body: some View {
        (Text("shastra").foregroundColor(Surface.text) + Text(".").foregroundColor(Surface.accent))
            .font(.system(size: size, weight: .bold)).tracking(-size * 0.04)
            .accessibilityLabel("Shastra")
    }
}

// Keep refractive Liquid Glass on the control layer. Larger panels use native
// materials so conversations and code remain stable reading surfaces.
private struct GlassSurface: ViewModifier {
    var radius: CGFloat
    var interactive: Bool
    var tint: Color?
    var opaque: Color
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency || contrast == .increased {
            content.background(opaque, in: RoundedRectangle(cornerRadius: radius))
                .overlay(RoundedRectangle(cornerRadius: radius).stroke(Surface.stroke))
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular.tint(tint).interactive(interactive),
                                in: RoundedRectangle(cornerRadius: radius))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius))
                .background(tint ?? Color.clear, in: RoundedRectangle(cornerRadius: radius))
                .overlay(RoundedRectangle(cornerRadius: radius).stroke(Surface.stroke.opacity(0.65)))
        }
    }
}

private struct MaterialPanel: ViewModifier {
    var radius: CGFloat
    var color: Color
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency || contrast == .increased {
            content.background(color, in: RoundedRectangle(cornerRadius: radius))
        } else {
            content.background(color.opacity(0.88), in: RoundedRectangle(cornerRadius: radius))
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius))
        }
    }
}

private struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .withinWindow
        view.state = .followsWindowActiveState
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

private struct GlassSidebar: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency || contrast == .increased {
            content.background(Surface.sidebar)
        } else {
            content.background(Surface.sidebar.opacity(0.85))
                .background(SidebarMaterial())
        }
    }
}

private struct GlassControls: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 0) { content }
        } else { content }
    }
}

extension View {
    func glassSurface(radius: CGFloat = Design.controlRadius, interactive: Bool = false,
                      tint: Color? = nil, opaque: Color = Surface.raised) -> some View {
        modifier(GlassSurface(radius: radius, interactive: interactive, tint: tint, opaque: opaque))
    }
    func materialPanel(radius: CGFloat = 0, color: Color = Surface.raised) -> some View {
        modifier(MaterialPanel(radius: radius, color: color))
    }
    func glassSidebar() -> some View { modifier(GlassSidebar()) }
    func glassControls() -> some View { modifier(GlassControls()) }
}

/// Delegate interaction, focus, disabled state, and rendering to Apple's controls.
struct AppButtonStyle: PrimitiveButtonStyle {
    enum Kind { case primary, secondary, quiet }
    var kind: Kind = .secondary
    var compact = false
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        if #available(macOS 26.0, *), !reduceTransparency, contrast != .increased {
            if kind == .primary {
                button(configuration).buttonStyle(.glassProminent)
            } else {
                button(configuration).buttonStyle(.glass)
            }
        } else if kind == .primary {
            button(configuration).buttonStyle(.borderedProminent)
        } else {
            button(configuration).buttonStyle(.bordered)
        }
    }
    private func button(_ configuration: Configuration) -> some View {
        Button(role: configuration.role, action: configuration.trigger) {
            configuration.label
                .frame(minWidth: 24, minHeight: compact ? 24 : 28)
                .contentShape(Rectangle())
                .foregroundStyle(kind == .primary && activeState == .key ? Surface.onAccent : Surface.text)
        }
            .font(.system(size: 12, weight: .medium))
            .controlSize(compact ? .small : .regular)
            .buttonBorderShape(.capsule)
            .tint(Surface.accent)
            .microLift()
    }
}

struct StatusPill: View {
    let title: String
    var symbol: String = "circle.fill"
    var color: Color = Surface.accent
    var body: some View {
        Label(title, systemImage: symbol).font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color).padding(.horizontal, 8).padding(.vertical, 5)
            .background(color.opacity(0.10), in: Capsule())
            .accessibilityElement(children: .combine)
    }
}

struct KeyboardHint: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(Surface.muted).padding(.horizontal, 5).padding(.vertical, 3)
            .background(Surface.canvas.opacity(0.75), in: RoundedRectangle(cornerRadius: 4))
    }
}

private struct ComposerSurface: ViewModifier {
    let focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.materialPanel(radius: Design.composerRadius)
            .overlay(RoundedRectangle(cornerRadius: Design.composerRadius)
                .stroke(focused ? Surface.accent.opacity(0.65) : Surface.stroke, lineWidth: focused ? 1.5 : 1)
                .allowsHitTesting(false))
            .shadow(color: Color.black.opacity(0.035), radius: 10, x: 0, y: 3)
            .animation(reduceMotion ? nil : MicroMotion.settle, value: focused)
    }
}

extension View {
    func composerSurface(focused: Bool = false) -> some View { modifier(ComposerSurface(focused: focused)) }
}

struct WorkspaceEmptyState: View {
    let title: String
    let message: String
    var symbol: String = "sparkles"
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 26, weight: .light)).foregroundStyle(Surface.accent)
                .frame(width: 64, height: 64).background(Surface.selected, in: RoundedRectangle(cornerRadius: 20))
            Text(title).font(.system(size: 21, weight: .semibold)).foregroundStyle(Surface.text)
            Text(message).font(.system(size: 13)).lineSpacing(3).foregroundStyle(Surface.muted)
                .multilineTextAlignment(.center).frame(maxWidth: 320)
        }.padding(28).frame(maxWidth: .infinity)
    }
}

import ShastraCore

extension AgentTaskStatus {
    var displayName: String {
        switch self {
        case .queued: "Queued"
        case .starting: "Starting"
        case .running: "Working"
        case .needsInput: "Needs you"
        case .waiting: "Waiting"
        case .completed: "Completed"
        case .failed: "Failed"
        case .interrupted: "Interrupted"
        case .cancelled: "Stopped"
        }
    }
    var color: Color {
        switch self {
        case .failed: Surface.danger
        case .needsInput, .interrupted: Surface.warning
        case .running, .starting, .completed: Surface.accent
        default: Surface.muted
        }
    }
    var symbol: String {
        switch self {
        case .completed: "checkmark.circle.fill"
        case .failed, .interrupted: "exclamationmark.circle"
        case .needsInput: "hand.raised.fill"
        case .running, .starting: "circle.dotted"
        case .cancelled: "stop.circle"
        default: "clock"
        }
    }
}
