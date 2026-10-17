import AppKit
import SwiftUI
import ShastraCore

/// These actions only prepare an editable draft.
struct ComposerActionItems: View {
    @Binding var draft: String
    var onCompose: () -> Void = {}
    var body: some View {
        Button("Commit & push") { compose("Review the changes for this task, commit them with an appropriate message, and push the current branch. Keep unrelated changes out of the commit.") }
        Button("Commit") { compose("Review the changes for this task and commit them with an appropriate message. Keep unrelated changes out of the commit.") }
        Button("Create pull request") { compose("Review this task's changes and validation, then create a pull request with a clear title and description. Keep unrelated changes out of the pull request.") }
        Button("Debug CI failure") { compose("Inspect the failing CI checks for the current branch or pull request, identify the cause, fix it, and run the relevant checks.") }
    }
    private func compose(_ text: String) { onCompose(); draft = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? text : draft + "\n\n" + text }
}
