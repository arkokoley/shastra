import AppKit
import SwiftUI
import ShastraCore

/// Shared by new drafts, conversations, and background agents.
struct ComposerWorkspaceBar: View {
    @EnvironmentObject private var app: AppModel
    let path: String
    let isNew: Bool
    let background: Bool
    private var location: WorkspaceIdentity? { app.workspaceIdentities[path] }
    private var siblings: [WorkspaceIdentity] {
        guard let location else { return [] }
        var seen = Set<String>()
        return app.workspaceIdentities.values.filter {
            $0.isGit && $0.isAvailable && $0.projectID == location.projectID && $0.workspacePath != location.workspacePath
                && seen.insert($0.workspacePath).inserted
        }.sorted { $0.workspaceName.localizedStandardCompare($1.workspaceName) == .orderedAscending }
    }

    var body: some View {
        HStack(spacing: 18) {
            if isNew {
                WorkspaceSelector(path: path, paths: app.recentWorkspacePaths, select: app.selectNewChatWorkspace)
                    .frame(maxWidth: 200, alignment: .leading)
            }
            if !isNew || location?.isGit == true {
            Menu {
                Text(path)
                if let branch = location?.branch { Label(branch, systemImage: "checkmark") }
                Button("Reveal workspace in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path) }
                Button("Copy workspace path") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(path, forType: .string)
                }
                Divider()
                if !isNew {
                    Button("New Agent in this workspace") { app.beginNewChat(in: path, background: true) }
                }
                if location?.isGit == true {
                    Button("New isolated worktree…") {
                        if !isNew { app.beginNewChat(in: path, background: true) }
                        app.newChatIsolated = true
                    }
                }
                if !siblings.isEmpty {
                    Text(isNew ? "Choose a workspace / branch" : "New chat in another workspace / branch")
                    ForEach(siblings, id: \.workspacePath) { workspace in
                        Button("\(workspace.branch ?? workspace.workspaceName) · \(workspace.workspaceName)") {
                            if isNew { app.selectNewChatWorkspace(workspace.workspacePath) }
                            else { app.beginNewChat(in: workspace.workspacePath, background: background) }
                        }.disabled(!workspace.isAvailable)
                    }
                }
            } label: {
                Label(isNew && app.newChatIsolated ? "New worktree" : location?.branch ?? (location?.isGit == true ? "Detached HEAD" : URL(fileURLWithPath: path).lastPathComponent),
                      systemImage: location?.isGit == true ? "arrow.triangle.branch" : "folder")
                    .lineLimit(1).truncationMode(.middle)
            }.frame(maxWidth: 280, alignment: .leading)
                .help("\(path)\nCurrent branch and workspace options")
                .accessibilityLabel("Branch and workspace options")
            }
            Menu {
                Label("This Mac", systemImage: "checkmark")
                if isNew {
                    Toggle("Continue in the background", isOn: $app.newChatUsesService)
                    if location?.isGit == true {
                        Toggle("Use an isolated Git worktree", isOn: $app.newChatIsolated)
                    }
                } else {
                    Text(background ? "Background agent" : "Local conversation")
                    Button("New background agent here") { app.beginNewChat(in: path, background: true) }
                }
            } label: { Label("This Mac", systemImage: "laptopcomputer") }.fixedSize()
                .accessibilityLabel("This Mac · execution options")
            Spacer(minLength: 0)
        }.font(.system(size: 12)).foregroundStyle(Surface.muted)
            .menuStyle(.borderlessButton).padding(.horizontal, 8)
            .task(id: path) { await app.resolveWorkspace(path) }
    }
}

/// These actions compose editable agent requests. Sending follows the chat's normal permissions.
struct ComposerActions: View {
    @Binding var draft: String
    var body: some View {
        HStack(spacing: 8) {
            Menu {
                Button("Commit & Push") { compose("Review the changes for this task, commit them with an appropriate message, and push the current branch. Keep unrelated changes out of the commit.") }
                Button("Commit") { compose("Review the changes for this task and commit them with an appropriate message. Keep unrelated changes out of the commit.") }
                Button("Create Pull Request") { compose("Review this task's changes and validation, then create a pull request with a clear title and description. Keep unrelated changes out of the pull request.") }
            } label: {
                HStack(spacing: 6) { Text("Commit & Push"); Image(systemName: "chevron.down").font(.system(size: 9)) }
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Surface.raised, in: Capsule()).overlay(Capsule().stroke(Surface.stroke))
                .help("Compose a commit, push, or pull request action")
            Button("Debug CI Failure") {
                compose("Inspect the failing CI checks for the current branch or pull request, identify the cause, fix it, and run the relevant checks.")
            }.buttonStyle(.plain).padding(.horizontal, 12).padding(.vertical, 7)
                .background(Surface.raised, in: Capsule()).overlay(Capsule().stroke(Surface.stroke))
                .help("Compose a request to debug failing CI")
        }.font(.system(size: 12)).foregroundStyle(Surface.muted)
    }
    private func compose(_ text: String) {
        draft = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? text : draft + "\n\n" + text
    }
}
