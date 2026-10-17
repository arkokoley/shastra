import AppKit
import SwiftUI

/// Glass surfaces, strong ink, and one forest-green action accent.
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
    static let canvas = color(0xF1F6F1, 0x1B231E)
    static let sidebar = color(0xEDF0EC, 0x15171B)
    static let dock = color(0xE5EBE5, 0x26282A)
    static let raised = color(0xF8FCF8, 0x253029)
    static let glassTint = color(0xC9E2D0, 0x3E654D)
    static let selected = color(0xDDEBE1, 0x263D31)
    static let stroke = color(0xC5CEC6, 0x45494D)
    static let muted = color(0x4C584F, 0xBBC6BD)
    static let text = color(0x1A251E, 0xF1F4F8)
    static let accent = color(0x24583D, 0x98CEAA)
    static let onAccent = color(0xFFFFFF, 0x142A1D)
    static let hover = color(0xE5EBE5, 0x2D3830)
    static let code = color(0xEFF2EE, 0x202224)
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
    static let readingWidth: CGFloat = 820
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
            content.background(color.opacity(0.78), in: RoundedRectangle(cornerRadius: radius))
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius))
        }
    }
}

private struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .active
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
            content.background(Surface.glassTint.opacity(0.10))
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
                      tint: Color? = Surface.glassTint.opacity(0.22), opaque: Color = Surface.raised) -> some View {
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
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        if kind == .primary {
            button(configuration).buttonStyle(TintedActionStyle())
        } else if #available(macOS 26.0, *), !reduceTransparency, contrast != .increased {
            button(configuration).buttonStyle(.glass)
        } else {
            button(configuration).buttonStyle(.bordered)
        }
    }
    private func button(_ configuration: Configuration) -> some View {
        Button(role: configuration.role, action: configuration.trigger) {
            configuration.label
                .frame(minWidth: 24, minHeight: compact ? 24 : 28)
                .contentShape(Rectangle())
                .foregroundStyle(kind == .primary ? (enabled ? Surface.accent : Surface.muted) : Surface.text)
        }
            .font(.system(size: 13, weight: .medium))
            .controlSize(compact ? .small : .regular)
            .buttonBorderShape(.capsule)
            .tint(Surface.glassTint.opacity(0.22))
            .microLift()
    }
}

/// Green-tinted glass uses dark ink rather than white labels on a solid fill.
private struct TintedActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(enabled ? Surface.accent : Surface.muted)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .glassSurface(radius: 9, interactive: enabled,
                          tint: Surface.glassTint.opacity(enabled ? 0.55 : 0.18), opaque: Surface.selected)
            .overlay(RoundedRectangle(cornerRadius: 9)
                .stroke(enabled ? Surface.accent.opacity(0.35) : Surface.stroke, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

extension View {
    func composerPlaceholder(_ text: String, visible: Bool) -> some View {
        overlay(alignment: .topLeading) {
            if visible {
                Text(text).font(.system(size: 16)).foregroundStyle(Surface.muted)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
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
                .stroke(focused ? Surface.accent : Surface.stroke, lineWidth: focused ? 1.5 : 1)
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
