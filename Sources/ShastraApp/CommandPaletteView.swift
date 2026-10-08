import AppKit
import ShastraCore
import SwiftUI

private enum PaletteCategory: String, CaseIterable {
    case all = "All", messages = "Messages", chats = "Chats", projects = "Projects", files = "Files", actions = "Actions"
}

@MainActor private final class PaletteState: ObservableObject {
    @Published var messages: [HistorySearchResult] = []
    @Published var query = ""
    @Published var category = PaletteCategory.all
    @Published var selection = 0
    @Published var files: [WorkspaceFileMatch] = []
    @Published var searchingFiles = false
}

private struct PaletteResult: Identifiable {
    enum Destination { case message(UUID, UUID), chat(UUID), project(String), file(URL), action(String) }
    let id: String
    let title: String
    let detail: String
    let symbol: String
    let shortcut: String
    let category: PaletteCategory
    let destination: Destination
}

struct CommandPaletteView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var state = PaletteState()
    @ObservedObject var tools: WorkspaceToolsModel
    let showDock: () -> Void

    private var results: [PaletteResult] {
        let query = state.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        var rows: [PaletteResult] = []
        let actions: [(String, String, String, String)] = [
            ("new", "New chat", "square.and.pencil", "⌘N"), ("accounts", "Manage accounts", "person.crop.circle", "⌘,"),
            ("files", "Browse workspace files", "folder", ""), ("terminal", "Open terminal", "terminal", ""),
            ("changes", "Review changes", "arrow.triangle.branch", ""), ("browser", "Open browser", "globe", ""),
            ("refresh", "Refresh imported conversations", "arrow.clockwise", "")
        ]
        rows += actions.filter { model.selected != nil || ["new", "accounts", "refresh"].contains($0.0) }.map { PaletteResult(id: "action:\($0.0)", title: $0.1, detail: "Action", symbol: $0.2, shortcut: $0.3,
            category: .actions, destination: .action($0.0)) }
        rows += model.conversations.sorted { $0.updatedAt > $1.updatedAt }.map { chat in
            let identity = model.workspaceIdentities[chat.workingDirectory] ?? .folder(chat.workingDirectory)
            return PaletteResult(id: chat.id.uuidString, title: model.title(chat.id, fallback: chat.title).replacingOccurrences(of: "\n", with: " "),
                detail: "\(chat.provider.title) · \(identity.projectName)" + (identity.branch.map { " · \($0)" } ?? ""),
                symbol: chat.state == .running ? "circle.dotted" : "bubble.left", shortcut: "", category: .chats, destination: .chat(chat.id))
        }
        rows += state.messages.compactMap { match in
            guard let chat = model.conversations.first(where: { $0.id == match.conversationID }) else { return nil }
            return PaletteResult(id: "message:\(match.id)", title: model.title(chat.id, fallback: chat.title),
                detail: ComposerContext.snippet(match.entry.text, query: query), symbol: "text.bubble", shortcut: "", category: .messages,
                destination: .message(chat.id, match.entry.id))
        }
        var seen = Set<String>()
        for chat in model.conversations.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            let identity = model.workspaceIdentities[chat.workingDirectory] ?? .folder(chat.workingDirectory)
            guard identity.isGit, identity.isAvailable, seen.insert(identity.workspacePath).inserted else { continue }
            rows.append(PaletteResult(id: "workspace:\(identity.workspacePath)", title: identity.isWorktree ? identity.workspaceName : identity.projectName,
                detail: identity.branch.map { "\(identity.projectName) · \($0)" } ?? identity.projectPath,
                symbol: identity.isWorktree ? "arrow.triangle.branch" : "folder", shortcut: "", category: .projects,
                destination: .project(chat.workingDirectory)))
        }
        rows += state.files.map { file in
            PaletteResult(id: file.id, title: file.url.lastPathComponent, detail: file.relativePath,
                symbol: FileIcon.symbol(for: file.url), shortcut: "", category: .files, destination: .file(file.url))
        }
        let matches = rows.filter { row in
            (state.category == .all || state.category == row.category) &&
            (row.category == .messages || terms.allSatisfy { (row.title + " " + row.detail).lowercased().contains($0) })
        }
        if query.isEmpty && state.category == .all {
            return Array(matches.filter { $0.category == .actions }.prefix(3)) + Array(matches.filter { $0.category == .chats }.prefix(9))
        }
        return Array((matches.filter { $0.category == .messages } + matches.filter { $0.category != .messages }).prefix(50))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 13) {
                Image(systemName: "magnifyingglass").font(.system(size: 19)).foregroundStyle(Surface.muted)
                PaletteSearchField(text: $state.query, move: moveSelection, submit: openSelection, dismiss: { model.showPalette = false })
                    .frame(height: 30)
                Button { model.showPalette = false } label: { Text("esc").font(.system(size: 11)).padding(.horizontal, 6).padding(.vertical, 4) }
                    .buttonStyle(.plain).foregroundStyle(Surface.muted).background(Surface.selected, in: RoundedRectangle(cornerRadius: 5))
                    .accessibilityLabel("Close search")
            }.padding(20)
            HStack(spacing: 6) {
                ForEach(PaletteCategory.allCases, id: \.self) { category in
                    Button { state.category = category; state.selection = 0 } label: {
                        Text(category.rawValue).font(.system(size: 12, weight: .medium)).padding(.horizontal, 12).padding(.vertical, 7)
                            .foregroundStyle(state.category == category ? Surface.accent : Surface.muted)
                            .background(state.category == category ? Surface.selected : .clear, in: RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain)
                }
                Spacer()
                if state.searchingFiles { ProgressView().controlSize(.mini) }
            }.padding(.horizontal, 18).padding(.bottom, 12)
            Surface.stroke.frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 3) {
                        let rows = results
                        if rows.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "magnifyingglass").font(.system(size: 24, weight: .light))
                                Text(state.category == .files && state.query.count < 2 ? "Type at least two characters to find a file" : "No results")
                                    .font(.system(size: 13, weight: .medium))
                                Text("Search messages, chat titles, Git workspaces, filenames, or actions.")
                                    .font(.system(size: 11)).multilineTextAlignment(.center)
                            }.foregroundStyle(Surface.muted).frame(maxWidth: .infinity).padding(.top, 80)
                        }
                        ForEach(Array(rows.enumerated()), id: \.element.id) { offset, result in
                            Button { activate(result) } label: {
                                HStack(spacing: 13) {
                                    Image(systemName: result.symbol).font(.system(size: 15)).foregroundStyle(Surface.muted).frame(width: 22)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(result.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                        Text(result.detail).font(.system(size: 11)).foregroundStyle(Surface.muted).lineLimit(1)
                                    }
                                    Spacer()
                                    Text(offset == state.selection && result.shortcut.isEmpty ? "↵" : result.shortcut)
                                        .font(.system(size: 11)).foregroundStyle(Surface.muted)
                                }.foregroundStyle(Surface.text).padding(.horizontal, 12).frame(height: 56)
                                    .background(offset == state.selection ? Surface.selected : .clear, in: RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain).accessibilityLabel("\(result.title), \(result.detail)")
                        }
                    }.padding(10)
                }.onChange(of: state.selection) { _, value in
                    if results.indices.contains(value) { proxy.scrollTo(results[value].id) }
                }
            }
            Surface.stroke.frame(height: 1)
            HStack(spacing: 14) {
                Text("↑ ↓ Navigate"); Text("↵ Open")
                Spacer()
                Text(model.indexingStatus).lineLimit(1)
                Button(model.indexingStatus.hasPrefix("Indexing history") ? "Pause" : "Index history") { model.toggleHistoryIndexing() }.buttonStyle(.plain)
                Text(state.category == .files ? "Files in \(tools.root.lastPathComponent)" : "\(results.count) results")
            }.font(.system(size: 10)).foregroundStyle(Surface.muted).padding(.horizontal, 20).frame(height: 38)
        }.frame(width: 670, height: 560).background(Surface.canvas)
        .task(id: "history:\(state.query):\(model.indexingRevision)") {
            state.messages = []
            guard state.query.count >= 2 else { return }
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            let found = await model.historySearch(state.query)
            guard !Task.isCancelled else { return }; state.messages = found
        }
        .onChange(of: state.query) { _, _ in state.selection = 0 }
        .onChange(of: results.map(\.id)) { _, rows in state.selection = min(state.selection, max(0, rows.count - 1)) }
        .task(id: "\(state.category.rawValue):\(state.query):\(tools.root.path)") {
            state.files = []
            state.searchingFiles = false
            guard [.all, .files].contains(state.category), state.query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2,
                  model.selected != nil else { return }
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            state.searchingFiles = true
            let files = await WorkspaceFileSearch.search(root: tools.root, query: state.query)
            guard !Task.isCancelled else { return }
            state.files = files; state.searchingFiles = false
        }
    }

    private func moveSelection(_ delta: Int) { guard !results.isEmpty else { return }; state.selection = (state.selection + delta + results.count) % results.count }
    private func openSelection() { if results.indices.contains(state.selection) { activate(results[state.selection]) } }
    private func activate(_ result: PaletteResult) {
        model.showPalette = false
        switch result.destination {
        case .message(let id, let entry): model.search = ""; model.openConversation(id); model.jumpToEntryID = entry
        case .chat(let id): model.search = ""; model.sourceFilter = "All"; model.openConversation(id)
        case .project(let path):
            if let chat = model.conversations.filter({ $0.workingDirectory == path }).max(by: { $0.updatedAt < $1.updatedAt }) {
                model.search = ""; model.sourceFilter = "All"; model.openConversation(chat.id)
            } else { model.beginNewChat(in: path) }
        case .file(let url): showDock(); tools.select(url)
        case .action(let action):
            switch action {
            case "new": model.beginNewChat()
            case "accounts": model.showAccounts = true
            case "refresh": model.refreshCatalog()
            case "terminal": if model.selected != nil { showDock(); tools.openTerminal() }
            case "changes": if model.selected != nil { showDock(); tools.tab = .changes }
            case "browser": if model.selected != nil { showDock(); tools.tab = .browser }
            case "files": if model.selected != nil { showDock(); tools.showsExplorer = true; tools.tab = .files }
            default: break
            }
        }
    }
}

private struct PaletteSearchField: NSViewRepresentable {
    @Binding var text: String
    let move: (Int) -> Void
    let submit: () -> Void
    let dismiss: () -> Void
    final class Field: NSTextField {
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if let window { DispatchQueue.main.async { [weak self] in if let self { window.makeFirstResponder(self) } } } }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PaletteSearchField
        init(_ parent: PaletteSearchField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) { if let field = notification.object as? NSTextField { parent.text = field.stringValue } }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch NSStringFromSelector(selector) {
            case "moveDown:": parent.move(1)
            case "moveUp:": parent.move(-1)
            case "insertNewline:": parent.submit()
            case "cancelOperation:": parent.dismiss()
            default: return false
            }
            return true
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSTextField {
        let field = Field(); field.isBordered = false; field.drawsBackground = false; field.focusRingType = .none
        field.font = .systemFont(ofSize: 18); field.placeholderString = "Search or run a command…"; field.delegate = context.coordinator
        field.setAccessibilityLabel("Search or run a command")
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }
}
