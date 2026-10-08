import AppKit
import SwiftUI
import ShastraCore

@MainActor final class WorkspacePickerState: ObservableObject {
    @Published var presented = false
    @Published var query = ""
}
struct WorkspaceSelector: View {
    @EnvironmentObject private var app: AppModel
    @StateObject private var state = WorkspacePickerState()
    let path: String
    let paths: [String]
    let select: (String) -> Void
    private var choices: [WorkspaceIdentity] {
        var seen = Set<String>()
        let all = (paths + app.experience.favoriteWorkspaces.sorted()).compactMap { app.workspaceIdentities[$0] }
        return all.filter {
            $0.isGit && $0.isAvailable && seen.insert($0.workspacePath).inserted &&
            (state.query.isEmpty || "\($0.projectName) \($0.workspaceName) \($0.branch ?? "Detached HEAD") \($0.workspacePath)".localizedCaseInsensitiveContains(state.query))
        }.sorted { app.experience.favoriteWorkspaces.contains($0.workspacePath) && !app.experience.favoriteWorkspaces.contains($1.workspacePath) }
    }
    var body: some View {
        Button { state.presented.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                Text(app.workspaceIdentities[path]?.projectName ?? (path.isEmpty ? "Choose Git workspace" : URL(fileURLWithPath: path).lastPathComponent)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9))
            }
        }.buttonStyle(.plain).help(path).accessibilityLabel("Choose Git workspace")
            .popover(isPresented: $state.presented, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Search repositories or branches…", text: $state.query).textFieldStyle(.roundedBorder)
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(choices, id: \.workspacePath) { workspace in
                                HStack(spacing: 10) {
                                    Button { select(workspace.workspacePath); state.presented = false } label: {
                                        HStack(spacing: 10) {
                                            Image(systemName: workspace.workspacePath == path ? "checkmark.circle.fill" : workspace.isWorktree ? "arrow.triangle.branch" : "folder")
                                                .foregroundStyle(Surface.accent)
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(workspace.projectName).fontWeight(.medium)
                                                Text((workspace.branch ?? "Detached HEAD") + (workspace.isWorktree ? " · \(workspace.workspaceName)" : " · Main checkout"))
                                                    .font(.caption).foregroundStyle(Surface.muted).lineLimit(1)
                                            }
                                            Spacer()
                                        }.padding(8).contentShape(Rectangle())
                                    }.buttonStyle(.plain).help(workspace.workspacePath)
                                    Button {
                                        if app.experience.favoriteWorkspaces.contains(workspace.workspacePath) { app.experience.favoriteWorkspaces.remove(workspace.workspacePath) }
                                        else { app.experience.favoriteWorkspaces.insert(workspace.workspacePath) }
                                    } label: { Image(systemName: app.experience.favoriteWorkspaces.contains(workspace.workspacePath) ? "star.fill" : "star") }
                                        .buttonStyle(.plain).foregroundStyle(Surface.accent).help("Pin workspace")
                                }.background(workspace.workspacePath == path ? Surface.selected : .clear, in: RoundedRectangle(cornerRadius: 8))
                            }
                            if choices.isEmpty { Text("No matching Git workspaces").foregroundStyle(Surface.muted).padding() }
                        }
                    }.frame(maxHeight: 320)
                    Divider()
                    Button("Open another Git repository…") { browse() }.buttonStyle(AppButtonStyle())
                }.padding(16).frame(width: 440).background(Surface.canvas)
            }
    }
    private func browse() {
        state.presented = false
        let panel = NSOpenPanel(); panel.title = "Choose a Git repository or worktree"
        panel.message = "A subfolder will use its Git checkout root."
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        if !path.isEmpty { panel.directoryURL = URL(fileURLWithPath: path) }
        if panel.runModal() == .OK, let url = panel.url { select(url.path) }
    }
}
