import AppKit
import SwiftUI

/// Website palette: cream surfaces, olive ink, and terracotta accents.
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
    static let canvas = color(0xF6F4EE, 0x1C1D19)
    static let sidebar = color(0xF0F1E9, 0x181A16)
    static let dock = color(0xE9ECDF, 0x23261F)
    static let raised = color(0xFFFEFA, 0x292B24)
    static let selected = color(0xE0E5D8, 0x383D30)
    static let stroke = color(0xDCDED3, 0x424638)
    static let muted = color(0x686C62, 0xB0B5A6)
    static let text = color(0x242820, 0xF6F4EE)
    static let accent = color(0xB74D2E, 0xF0A184)
    static let onAccent = color(0xFFFEFA, 0x291B15)
    static let hover = color(0xE9ECDF, 0x32362B)
    static let code = color(0xF5F5EF, 0x181A16)
    static let warning = color(0x95600E, 0xF3BC61)
    static let danger = color(0xB63E42, 0xFF9297)
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

struct AppButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, quiet }
    var kind: Kind = .secondary
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 12).frame(minHeight: 32)
            .foregroundStyle(kind == .primary ? Surface.onAccent : Surface.text)
            .background(kind == .primary ? Surface.accent : kind == .secondary ? Surface.raised : Color.clear,
                        in: RoundedRectangle(cornerRadius: Design.controlRadius))
            .overlay(RoundedRectangle(cornerRadius: Design.controlRadius).stroke(kind == .secondary ? Surface.stroke : .clear))
            .opacity(enabled ? (configuration.isPressed ? 0.72 : 1) : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: Design.controlRadius))
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
    func body(content: Content) -> some View {
        content.background(Surface.raised, in: RoundedRectangle(cornerRadius: Design.composerRadius))
            .overlay(RoundedRectangle(cornerRadius: Design.composerRadius)
                .stroke(focused ? Surface.accent.opacity(0.65) : Surface.stroke, lineWidth: focused ? 1.5 : 1))
            .shadow(color: Color.black.opacity(0.045), radius: 18, x: 0, y: 6)
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
