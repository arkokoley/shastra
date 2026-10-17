import AppKit
import SwiftUI
import ShastraCore

private enum ComposerEnvironmentMode: String, CaseIterable {
    case local = "This folder", background = "Background", isolated = "Isolated worktree"
    var symbol: String { switch self { case .local: "folder"; case .background: "bolt.horizontal.circle"; case .isolated: "arrow.triangle.branch" } }
    var detail: String {
        switch self {
        case .local: "Work in the selected checkout while Shastra is open."
        case .background: "Work in the selected checkout; continue when the window closes."
        case .isolated: "Create a separate Git worktree on first send and run in the background."
        }
    }
}

/// A single, explicit execution summary. Existing chats never move workspaces implicitly.
struct ComposerWorkspaceBar: View {
    @EnvironmentObject private var app: AppModel
    @ViewState private var presented = false
    @ViewState private var query = ""
    let path: String
    let isNew: Bool
    let background: Bool
    private var location: WorkspaceIdentity? { app.workspaceIdentities[path] }
    private var mode: ComposerEnvironmentMode {
        if isNew { return app.newChatIsolated ? .isolated : app.newChatUsesService ? .background : .local }
        return location?.isWorktree == true ? .isolated : background ? .background : .local
    }
    private var choices: [WorkspaceIdentity] {
        app.recentWorkspacePaths.compactMap { app.workspaceIdentities[$0] }.filter {
            query.isEmpty || "\($0.projectName) \($0.workspacePath) \($0.branch ?? "")".localizedCaseInsensitiveContains(query)
        }.sorted { app.experience.favoriteWorkspaces.contains($0.workspacePath) && !app.experience.favoriteWorkspaces.contains($1.workspacePath) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button { presented.toggle() } label: {
                HStack(spacing: 6) {
                    Label(isNew ? mode.rawValue : (background ? "Background" : "This Mac") + (location?.isWorktree == true ? " · Worktree" : " · Folder"), systemImage: mode.symbol)
                    Text("· " + (location?.projectName ?? (path.isEmpty ? "Choose a Git folder" : URL(fileURLWithPath: path).lastPathComponent)))
                        .lineLimit(1).truncationMode(.middle)
                    if let branch = location?.branch { Text("· " + branch).lineLimit(1).truncationMode(.middle) }
                    Image(systemName: "chevron.down").font(.system(size: 9))
                }.frame(minHeight: 28)
            }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Surface.muted)
                .accessibilityLabel("Execution environment").accessibilityValue(mode.rawValue + ", " + path)
                .help(path + "\n" + (isNew ? mode.detail : "This chat keeps its current workspace. Start a new chat to choose another."))
                .popover(isPresented: $presented, arrowEdge: .top) { environmentPicker }
            if !isNew && location?.isAvailable == false {
                Label("Folder unavailable", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Surface.warning)
            }
            if isNew {
                Text(app.resolvingNewChatWorkspace ? "Checking folder…" : path.isEmpty ? "Select an existing Git repository before sending." : (app.newChatIsolated ? "New worktree from " : "") + path)
                    .font(.system(size: 10)).foregroundStyle(Surface.muted).lineLimit(1).truncationMode(.middle).help(path)
            }
        }.padding(.horizontal, 8).task(id: path) { await app.resolveWorkspace(path) }
    }
    private var environmentPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Execution environment").font(.headline)
            Text(path.isEmpty ? "No folder selected" : path).font(.caption).textSelection(.enabled).foregroundStyle(Surface.muted)
            if isNew {
                ForEach(ComposerEnvironmentMode.allCases, id: \.self) { choice in
                    Button {
                        app.newChatIsolated = choice == .isolated
                        app.newChatUsesService = choice != .local
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: mode == choice ? "checkmark.circle.fill" : choice.symbol).frame(width: 20)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(choice.rawValue).fontWeight(.medium)
                                Text(choice.detail).font(.caption).foregroundStyle(Surface.muted).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                        }.padding(8).contentShape(Rectangle()).background(mode == choice ? Surface.selected : .clear, in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain).disabled(app.resolvingNewChatWorkspace || (choice == .isolated && !app.hasGitChatWorkspace))
                }
            } else {
                Text("This chat runs \(background ? "in the background" : "while Shastra is open") in the folder above. Choosing another folder starts a new chat.")
                    .font(.caption).foregroundStyle(Surface.muted)
                Button("New isolated chat from this folder") { app.beginNewChat(in: path, background: true, isolated: true); presented = false }
                    .disabled(location?.isGit != true || location?.isAvailable != true)
            }
            Divider()
            Text(isNew ? "Choose a repository or existing worktree" : "Start a new chat in another folder").font(.caption.bold())
            TextField("Search folders or enter an absolute path…", text: $query).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Find environment folder").onSubmit { useTypedPath() }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(choices, id: \.workspacePath) { workspace in
                        HStack {
                        Button { choose(workspace.workspacePath) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(workspace.projectName + " · " + (workspace.branch ?? "Detached HEAD")).fontWeight(.medium)
                                Text(workspace.workspacePath).font(.caption).foregroundStyle(Surface.muted).lineLimit(1).truncationMode(.middle)
                            }.padding(8).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).help(workspace.workspacePath)
                        Button {
                            if app.experience.favoriteWorkspaces.contains(workspace.workspacePath) { app.experience.favoriteWorkspaces.remove(workspace.workspacePath) }
                            else { app.experience.favoriteWorkspaces.insert(workspace.workspacePath) }
                        } label: { Image(systemName: app.experience.favoriteWorkspaces.contains(workspace.workspacePath) ? "star.fill" : "star").frame(width: 28, height: 28) }
                            .buttonStyle(.plain).help("Pin workspace").accessibilityLabel("Pin \(workspace.projectName)")
                        }
                    }
                    if choices.isEmpty { Text("No matching known folders. Browse or enter a path.").font(.caption).foregroundStyle(Surface.muted).padding(8) }
                }
            }.frame(maxHeight: 150)
            HStack {
                Button("Browse…", action: browse)
                if expandedQuery.hasPrefix("/") { Button("Use this path", action: useTypedPath) }
                Spacer()
                if !path.isEmpty { Button("Reveal in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path) } }
            }.font(.caption).disabled(app.resolvingNewChatWorkspace)
        }.padding(16).frame(width: 470).background(Surface.canvas)
    }
    private var expandedQuery: String { (query.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath }
    private func useTypedPath() { if expandedQuery.hasPrefix("/") { choose(expandedQuery) } }
    private func choose(_ selectedPath: String) {
        if isNew { app.selectNewChatWorkspace(selectedPath) }
        else { app.beginNewChat(in: selectedPath, background: background) }
        query = ""; presented = false
    }
    private func browse() {
        let panel = NSOpenPanel(); panel.title = "Choose a Git repository or worktree"
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        if !path.isEmpty { panel.directoryURL = URL(fileURLWithPath: path) }
        if panel.runModal() == .OK, let folder = panel.url { choose(folder.path) }
    }
}
