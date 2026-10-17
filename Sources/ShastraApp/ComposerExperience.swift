import AppKit
import SwiftUI
import ShastraCore
import UniformTypeIdentifiers

struct ComposerContextBar: View {
    @EnvironmentObject private var app: AppModel
    let key: String
    let workspace: String
    @Binding var draft: String
    var body: some View {
        let files = app.experience.attachments[key] ?? []
        let references = app.contextReferences(key)
        if !files.isEmpty || !references.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(files, id: \.self) { file in
                        chip(title: URL(fileURLWithPath: file).lastPathComponent, symbol: "doc", path: file, detail: file) {
                            app.experience.attachments[key]?.removeAll { $0 == file }
                        }
                    }
                    ForEach(references) { reference in
                        chip(title: reference.title, symbol: reference.kind.symbol, path: reference.location,
                             detail: reference.kind.rawValue.capitalized + " · " + reference.detail + "\n" + reference.location) {
                            app.removeContextReference(reference.id, key: key)
                        }
                    }
                }
            }.accessibilityLabel("Selected context")
        }
    }
    private func chip(title: String, symbol: String, path: String, detail: String, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Button { NSWorkspace.shared.open(URL(fileURLWithPath: path)) } label: { Label(title, systemImage: symbol).lineLimit(1) }
                .buttonStyle(.plain).help(detail + "\nOpen to inspect the selected context")
            Button(action: remove) { Image(systemName: "xmark").frame(width: 24, height: 24) }
                .buttonStyle(.plain).accessibilityLabel("Remove \(title)")
        }.font(.caption).padding(.leading, 9).padding(.trailing, 3).background(Surface.selected, in: Capsule())
    }
}

extension ComposerReference.Kind {
    var symbol: String { switch self { case .project: "folder"; case .chat: "bubble.left.and.bubble.right"; case .skill: "sparkles" } }
}

@MainActor private final class ContextPickerState: ObservableObject {
    @Published var presented = false
    @Published var category = "Files"
    @Published var query = ""
    @Published var files: [WorkspaceFileMatch] = []
    @Published var skills: [RuntimeLibraryItem] = []
    @Published var error: String?
    @Published var busy = false
    @Published var loading = false
}

/// One entry point for context and secondary actions, shared by every composer.
struct ComposerAddButton: View {
    @EnvironmentObject private var app: AppModel
    @StateObject private var ui = ContextPickerState()
    let key: String
    let workspace: String
    @Binding var draft: String
    private var provider: Provider {
        if key == "new" { return app.selectedProvider }
        return app.agentBoard.snapshot?.tasks.first { $0.id.uuidString == key }?.provider
            ?? app.conversations.first { $0.id.uuidString == key }?.provider ?? app.selectedProvider
    }
    private var projects: [WorkspaceIdentity] {
        var seen = Set<String>()
        return app.workspaceIdentities.values.filter {
            $0.isGit && $0.isAvailable && seen.insert($0.projectID).inserted && matches($0.projectName + " " + $0.workspacePath)
        }.sorted { $0.projectName.localizedStandardCompare($1.projectName) == .orderedAscending }
    }
    private var chats: [ChatSource] {
        var seen = Set<UUID>()
        let ids = (app.agentBoard.snapshot?.tasks.sorted { $0.updatedAt > $1.updatedAt }.map(\.id) ?? []) + app.conversations.sorted { $0.updatedAt > $1.updatedAt }.map(\.id)
        return Array(ids.filter { $0.uuidString != key && seen.insert($0).inserted }.compactMap { app.chatSource($0) }
            .filter { matches($0.title + " " + $0.workspace) }.prefix(60))
    }
    var body: some View {
        Button { ui.presented.toggle() } label: { Label("Add", systemImage: "plus").frame(minHeight: 28) }
            .buttonStyle(AppButtonStyle(kind: .quiet, compact: true)).help("Add context or an action · type @ to open")
            .popover(isPresented: $ui.presented, arrowEdge: .top) { picker }
            .onChange(of: draft) { _, text in
                if text == "@" || text.hasSuffix(" @") || text.hasSuffix("\n@") { ui.query = ""; ui.presented = true }
            }
    }
    private var picker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add context").font(.headline)
            ContextSearchField(text: $ui.query).frame(height: 28)
            Picker("Context type", selection: $ui.category) {
                ForEach(["Files", "Projects", "Chats", "Skills"], id: \.self) { Text($0).tag($0) }
            }.pickerStyle(.segmented)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) { results }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 250)
            if ui.loading || ui.busy { ProgressView(ui.busy ? "Preparing selected context…" : "Finding context…").controlSize(.small) }
            if let error = ui.error { Text(error).font(.caption).foregroundStyle(Surface.warning).textSelection(.enabled) }
            Divider()
            HStack {
                Button("Browse files…", action: browse)
                Button("Paste image") { app.pasteContextImage(key: key); finish() }
                Spacer()
                Menu("Actions") { ComposerActionItems(draft: $draft) { finish() }; Divider(); Button("Skills & tools…") { ui.presented = false; app.showRuntimeLibrary = true } }
                    .fixedSize()
            }.font(.caption)
            Text("Selections appear above the composer. Open a chip to inspect it before sending.")
                .font(.caption).foregroundStyle(Surface.muted)
        }.padding(16).frame(width: 490).background(Surface.canvas)
            .disabled(ui.busy)
            .task(id: "\(ui.category)|\(ui.query)|\(workspace)|\(provider.rawValue)") { await load() }
    }
    @ViewBuilder private var results: some View {
        switch ui.category {
        case "Files":
            ForEach(ui.files) { file in row(file.relativePath, detail: workspace, symbol: "doc") { app.addContextFiles([file.url], key: key); finish() } }
            if ui.files.isEmpty { empty(ui.query.isEmpty ? "Search a filename, or browse files below." : "No matching workspace files.") }
        case "Projects":
            ForEach(projects, id: \.projectID) { project in
                row(project.projectName, detail: project.workspacePath, symbol: "folder") {
                    do { try app.attachProject(project, key: key); finish() } catch { ui.error = error.localizedDescription }
                }
            }
            if projects.isEmpty { empty("No matching known projects. Open a repository from Environment to add it.") }
        case "Chats":
            ForEach(chats) { chat in
                row(chat.title, detail: "\(chat.provider.title) · \(chat.workspace)", symbol: "bubble.left.and.bubble.right") {
                    ui.busy = true; ui.error = nil
                    Task { defer { ui.busy = false }; do { try await app.attachChat(chat.id, key: key); finish() } catch { ui.error = error.localizedDescription } }
                }
            }
            if chats.isEmpty { empty("No matching chats. Search their title or workspace.") }
        default:
            ForEach(ui.skills.filter { matches($0.name) }) { skill in
                row(skill.name, detail: skill.source.path, symbol: "sparkles") {
                    app.addContextReference(.init(kind: .skill, title: skill.name, location: skill.source.appending(path: "SKILL.md").path,
                                                 detail: "Explicit skill file · \(provider.title) user or project library"), key: key); finish()
                }
            }
            if ui.skills.filter({ matches($0.name) }).isEmpty { empty("No matching skill files in this provider’s user or project library.") }
        }
    }
    private func row(_ title: String, detail: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 20).foregroundStyle(Surface.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).fontWeight(.medium).lineLimit(1)
                    Text(detail).font(.caption).foregroundStyle(Surface.muted).lineLimit(1).truncationMode(.middle)
                }
                Spacer(); Image(systemName: "plus").foregroundStyle(Surface.muted)
            }.padding(9).contentShape(Rectangle())
        }.buttonStyle(.plain).help(title + "\n" + detail).accessibilityLabel("Attach \(title)")
    }
    private func empty(_ text: String) -> some View { Text(text).font(.caption).foregroundStyle(Surface.muted).padding(.vertical, 14) }
    private func matches(_ value: String) -> Bool { ui.query.isEmpty || value.localizedCaseInsensitiveContains(ui.query) }
    private func finish() { ui.presented = false; ui.error = nil; if draft.hasSuffix("@") { draft.removeLast() } }
    private func browse() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        if !workspace.isEmpty { panel.directoryURL = URL(fileURLWithPath: workspace) }
        if panel.runModal() == .OK { app.addContextFiles(panel.urls, key: key); finish() }
    }
    private func load() async {
        ui.error = nil; ui.loading = true
        defer { ui.loading = false }
        if ui.category == "Files" {
            let files = workspace.isEmpty ? [] : await WorkspaceFileSearch.search(root: URL(fileURLWithPath: workspace), query: ui.query)
            if !Task.isCancelled { ui.files = files }
        } else if ui.category == "Skills" {
            do {
                let library = RuntimeLibrary()
                let user = try await library.inventory(.init(provider: provider, base: FileManager.default.homeDirectoryForCurrentUser))
                let project = workspace.isEmpty ? [] : try await library.inventory(.init(provider: provider, base: URL(fileURLWithPath: workspace), project: true))
                if !Task.isCancelled { ui.skills = (project + user).filter { $0.kind == .skill } }
            } catch { if !Task.isCancelled { ui.error = error.localizedDescription; ui.skills = [] } }
        }
    }
}

struct ComposerImagePaste: ViewModifier {
    @EnvironmentObject private var app: AppModel
    let key: String
    func body(content: Content) -> some View { content.onPasteCommand(of: [.image]) { _ in app.pasteContextImage(key: key) } }
}
