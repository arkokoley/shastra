import AppKit
import SwiftUI

struct CopyTextButton: View {
    let text: String
    var label = "Copy message"
    @StateObject private var interaction = ViewInteractionModel()

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            interaction.copied = NSPasteboard.general.setString(text, forType: .string)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                interaction.copied = false
            }
        } label: {
            Label(interaction.copied ? "Copied" : "Copy", systemImage: interaction.copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Surface.muted)
        .help(interaction.copied ? "Copied to clipboard" : label)
        .accessibilityLabel(interaction.copied ? "Copied to clipboard" : label)
        .disabled(text.isEmpty)
    }
}
