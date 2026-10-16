import AppKit
import SwiftUI

struct CopyTextButton: View {
    let text: String
    var label = "Copy message"
    @StateObject private var interaction = ViewInteractionModel()
    @ViewState private var copyRevision = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            interaction.copied = NSPasteboard.general.setString(text, forType: .string)
            if interaction.copied { copyRevision += 1 }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: interaction.copied ? "checkmark" : "doc.on.doc")
                    .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
                Text(interaction.copied ? "Copied" : "Copy").contentTransition(.opacity)
            }.font(.system(size: 11)).frame(width: 64, alignment: .leading)
        }
        .buttonStyle(MicroPressStyle())
        .foregroundStyle(interaction.copied ? Surface.accent : Surface.muted)
        .animation(reduceMotion ? nil : MicroMotion.quick, value: interaction.copied)
        .help(interaction.copied ? "Copied to clipboard" : label)
        .accessibilityLabel(interaction.copied ? "Copied to clipboard" : label)
        .disabled(text.isEmpty)
        .task(id: copyRevision) {
            let revision = copyRevision
            guard revision > 0 else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard copyRevision == revision else { return }
            interaction.copied = false
        }
    }
}
