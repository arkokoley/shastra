import AppKit
import SwiftUI
import ShastraCore

@MainActor final class ViewInteractionModel: ObservableObject {
    @Published var hovered = false
    @Published var copied = false
    @Published var expanded = false
}

@MainActor private final class ChromeModel: ObservableObject {
    @Published var showsSidebar = true
    @Published var showsDock = UserDefaults.standard.bool(forKey: "workspaceDockVisible") {
        didSet { UserDefaults.standard.set(showsDock, forKey: "workspaceDockVisible") }
    }
    @Published var expandedProjects: Set<String> = []
    @Published var allProjectChats: Set<String> = []
    @Published var appearance: ColorScheme? = nil
}

private struct SidebarGroup: Identifiable {
    let location: WorkspaceIdentity
    let conversations: [Conversation]
    var id: String { location.projectID }
    var name: String { location.projectName }
    var count: Int { conversations.count }
    var updatedAt: Date { conversations.first?.updatedAt ?? .distantPast }
}

/// Place native window controls in the same visual band as the app's header.
private struct WindowChrome: NSViewRepresentable {
    final class View: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            window.backgroundColor = .windowBackgroundColor
            window.isMovableByWindowBackground = true
        }
    }
    func makeNSView(context: Context) -> NSView { View() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct WorkspaceView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var tools = WorkspaceToolsModel()
    @StateObject private var chrome = ChromeModel()

    private var groups: [SidebarGroup] {
        let matches = model.filtered.filter {
            let organization = model.experience.organization($0.id)
            let statusMatches = model.chatFilter == "Running" ? [.running, .connecting].contains($0.state) : model.chatFilter == "Needs you" ? $0.state == .waitingForApproval || $0.state == .failed || model.hasUnresolvedDelivery($0) : true
            return (model.chatFilter == "Archived" ? organization.archived : !organization.archived) && statusMatches &&
            model.workspaceIdentities[$0.workingDirectory]?.isGit == true
                && (model.sourceFilter == "All" || ($0.sourceKind ?? "Shastra") == model.sourceFilter)
        }
        let byProject = Dictionary(grouping: matches) { conversation in
            (model.workspaceIdentities[conversation.workingDirectory] ?? .folder(conversation.workingDirectory)).projectID
        }
        return byProject.values.map { conversations in
            let chats = conversations.sorted {
                let a = model.experience.organization($0.id).pinned, b = model.experience.organization($1.id).pinned
                return a != b ? a : $0.updatedAt > $1.updatedAt
            }
            let location = model.workspaceIdentities[chats[0].workingDirectory] ?? .folder(chats[0].workingDirectory)
            return SidebarGroup(location: location, conversations: chats)
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func revealSelected() {
        guard let path = model.selected?.workingDirectory else { return }
        let location = model.workspaceIdentities[path] ?? .folder(path)
        chrome.expandedProjects.insert(location.projectID)
    }

    var body: some View {
        HStack(spacing: 0) {
            if chrome.showsSidebar { sidebar.frame(width: Design.sidebarWidth) }
            HSplitView {
                VStack(spacing: 0) {
                    header
                    Group {
                        if model.showNewConversation {
                            QuickChatView(board: model.agentBoard)
                        } else if model.showAgents {
                            AgentBoardView(board: model.agentBoard)
                        } else if let conversation = model.selected {
                            ConversationPane(conversation: conversation).id(conversation.id)
                        } else { welcome }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }.frame(minWidth: 440, idealWidth: 740, maxWidth: .infinity)
                    .ignoresSafeArea(.container, edges: .top)
                if chrome.showsDock, !model.showNewConversation, !model.showAgents, let conversation = model.selected {
                    WorkspaceToolsView(tools: tools, conversation: conversation)
                        .frame(minWidth: 350, idealWidth: 390, maxWidth: 580)
                        .ignoresSafeArea(.container, edges: .top)
                        .onAppear { tools.setRoot(conversation.workingDirectory) }
                        .onChange(of: conversation.workingDirectory) { _, path in tools.setRoot(path) }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { UsageStatusBar(board: model.agentBoard) }
        .ignoresSafeArea(.container, edges: .top)
        .background(Surface.canvas)
        .background(WindowChrome())
        .tint(Surface.accent)
        .preferredColorScheme(chrome.appearance)
        .sheet(isPresented: $model.showRuntimeLibrary) { RuntimeLibraryView().environmentObject(model) }
        .onReceive(NotificationCenter.default.publisher(for: .shastraOpenChat)) { event in
            if let value = event.object as? String, let id = UUID(uuidString: value) { model.openAgent(id) }
        }
        .onChange(of: model.requestedTool) { _, request in
            guard request != nil else { return }; chrome.showsDock = true; tools.tab = .changes; model.requestedTool = nil
        }
        .onChange(of: model.selectedID) { oldValue, _ in
            if oldValue != nil { model.showAgents = false; model.showNewConversation = false }
            model.loadSelectedHistory()
            if let path = model.selected?.workingDirectory {
                tools.setRoot(path)
                revealSelected()
            }
        }
        .onChange(of: model.workspaceIdentities) { _, _ in revealSelected() }
        .sheet(isPresented: Binding(get: { model.showAccounts || model.showPalette }, set: {
            if !$0 { model.showAccounts = false; model.showPalette = false }
        })) {
            if model.showPalette { CommandPaletteView(tools: tools, showDock: { chrome.showsDock = true }) }
            else { AccountsView() }
        }
        .alert("Shastra", isPresented: Binding(get: { model.notice != nil },
                                              set: { if !$0 { model.notice = nil } })) {
            Button("OK") { model.notice = nil }
        } message: { Text(model.notice ?? "") }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if !chrome.showsSidebar {
                Button { chrome.showsSidebar = true } label: { Image(systemName: "sidebar.left") }
                    .buttonStyle(ChromeButtonStyle()).help("Show sidebar")
            }
            Text(model.showNewConversation ? "New chat" : model.showAgents ? "Agents workspace" : model.selected.map { model.title($0.id, fallback: $0.title) } ?? "New chat")
                .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                .foregroundStyle(Surface.text)
            Spacer(minLength: 10)
            if !model.showNewConversation, !model.showAgents {
            Button { chrome.showsDock.toggle() } label: {
                HStack(spacing: 5) {
                    Text("Workspace")
                    Image(systemName: chrome.showsDock ? "sidebar.right" : "arrow.up.right")
                }.font(.system(size: 12))
            }.buttonStyle(AppButtonStyle(kind: .quiet)).help("Files, changes, terminal and browser")
            }
            Menu {
                Button("New conversation") { model.beginNewChat() }
                Button("Skills & tools…") { model.showRuntimeLibrary = true }
                if !model.showNewConversation, !model.showAgents, let chat = model.selected { ChatOrganizationMenu(id: chat.id, title: chat.title, active: [.running, .connecting, .waitingForApproval].contains(chat.state)) }
                Button("Refresh conversations") { model.refreshCatalog() }
                Divider()
                Button("Use system appearance") { chrome.appearance = nil }
                Button("Light appearance") { chrome.appearance = .light }
                Button("Dark appearance") { chrome.appearance = .dark }
            } label: { Image(systemName: "ellipsis").font(.system(size: 15)) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .frame(width: 25).help("Chat and appearance options")
        }.padding(.horizontal, Design.headerInset)
            .padding(.leading, chrome.showsSidebar ? 0 : Design.windowControlsInset)
            .frame(height: Design.headerHeight)
            .overlay(alignment: .bottom) { Surface.stroke.opacity(0.6).frame(height: 1) }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Shastra").font(.system(size: 14, weight: .semibold)).foregroundStyle(Surface.text)
                Spacer()
                Button { chrome.showsSidebar = false } label: { Image(systemName: "sidebar.left") }
                    .buttonStyle(ChromeButtonStyle()).help("Hide sidebar")
            }.padding(.horizontal, Design.headerInset)
                .padding(.leading, Design.windowControlsInset)
                .frame(height: Design.headerHeight)
                .overlay(alignment: .bottom) { Surface.stroke.opacity(0.6).frame(height: 1) }

            Button { model.beginNewChat() } label: {
                HStack(spacing: 12) {
                    Image(systemName: "square.and.pencil").font(.system(size: 16))
                    Text("New chat")
                    Spacer()
                    Text("⌘N").font(.system(size: 11)).opacity(0.7)
                }.padding(.horizontal, 12).frame(height: 40)
                .foregroundStyle(Surface.onAccent)
                .background(Surface.accent, in: RoundedRectangle(cornerRadius: 10))
            }.buttonStyle(.plain).padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)

            Button { model.showNewConversation = false; model.showAgents.toggle() } label: {
                HStack(spacing: 12) {
                    Image(systemName: "person.3.sequence")
                    Text("Agents workspace")
                    Spacer()
                    if model.showAgents && !model.showNewConversation { Image(systemName: "checkmark.circle.fill").foregroundStyle(Surface.accent) }
                }.padding(.horizontal, 12).frame(height: 40)
                    .background(model.showAgents && !model.showNewConversation ? Surface.selected : .clear, in: RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(SidebarButtonStyle()).padding(.horizontal, 8)

            Button { model.showPalette = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: "command").font(.system(size: 16))
                    Text("Quick Open").lineLimit(1)
                    Spacer()
                    KeyboardHint(text: "⌘K")
                }.padding(.horizontal, 12).frame(height: 36)
            }.buttonStyle(SidebarButtonStyle()).padding(.horizontal, 8)

            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").font(.system(size: 16))
                TextField("Search chats", text: $model.search)
                    .textFieldStyle(.plain).accessibilityLabel("Search conversations")
                if !model.search.isEmpty {
                    Button { model.search = "" } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).font(.system(size: 10))
                }
            }
            .font(.system(size: 13)).foregroundStyle(Surface.muted)
            .padding(.horizontal, 10).frame(height: 34)
            .background(Surface.raised.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Surface.stroke.opacity(0.6)))
            .padding(.horizontal, 14).padding(.top, 12)

            Picker("Chats", selection: $model.chatFilter) {
                ForEach(["All", "Running", "Needs you", "Archived"], id: \.self) { Text($0).tag($0) }
            }.pickerStyle(.menu).padding(.horizontal, 14).padding(.top, 6)
            HStack {
                Menu {
                    ForEach(["All", "Codex", "Cursor Editor", "Cursor CLI", "Claude Code", "Grok", "Shastra"], id: \.self) { source in
                        Button { model.sourceFilter = source } label: {
                            if model.sourceFilter == source { Label(source, systemImage: "checkmark") }
                            else { Text(source) }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(model.sourceFilter == "All" ? "PROJECTS" : model.sourceFilter.uppercased())
                        Image(systemName: "chevron.down").font(.system(size: 8))
                    }.font(.system(size: 12, weight: .medium)).foregroundStyle(Surface.muted)
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                Spacer()
                Button { model.refreshCatalog() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Surface.muted)
                    .help("Refresh conversations")
            }.padding(.horizontal, 20).padding(.top, 22).padding(.bottom, 8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    let sidebarGroups = groups
                    if sidebarGroups.isEmpty {
                        WorkspaceEmptyState(title: "No chats found", message: "Try another search, or start a new chat.", symbol: "magnifyingglass")
                    }
                    let duplicateNames = Set(Dictionary(grouping: sidebarGroups, by: \.name).filter { $0.value.count > 1 }.keys)
                    ForEach(sidebarGroups) { group in
                        let expanded = !model.search.isEmpty || chrome.expandedProjects.contains(group.id)
                        let duplicateName = duplicateNames.contains(group.name)
                        HStack(spacing: 0) {
                        Button {
                            if expanded { chrome.expandedProjects.remove(group.id) }
                            else { chrome.expandedProjects.insert(group.id) }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 9)).frame(width: 9)
                                Image(systemName: "folder").font(.system(size: 14))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(group.name).font(.system(size: 13)).lineLimit(1)
                                    if duplicateName {
                                        Text(URL(fileURLWithPath: group.location.projectPath).deletingLastPathComponent().path)
                                            .font(.system(size: 10)).foregroundStyle(Surface.muted).lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 0)
                                Text("\(group.count)").font(.system(size: 10, design: .monospaced)).foregroundStyle(Surface.muted).padding(.horizontal, 5).padding(.vertical, 2).background(Surface.hover, in: Capsule())
                            }.foregroundStyle(Surface.text.opacity(0.8))
                                .padding(.horizontal, 12).frame(height: duplicateName ? 48 : 38)
                        }.buttonStyle(SidebarButtonStyle())
                            .help(group.location.projectPath)
                            Button { model.beginNewChat(in: group.location.projectPath, background: true) } label: {
                                Image(systemName: "plus").font(.system(size: 14)).frame(width: 26, height: 30)
                            }.buttonStyle(.plain).foregroundStyle(Surface.muted)
                                .help("New Agent in \(group.name)").accessibilityLabel("New Agent in \(group.name)")
                        }.padding(.horizontal, 8)
                        if expanded {
                            projectChatRows(group)
                        }
                    }
                }.padding(.bottom, 20)
            }.scrollIndicators(.hidden).accessibilityLabel("Conversations")

            HStack(spacing: 11) {
                ShastraMark(size: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Shastra").font(.system(size: 13, weight: .medium))
                    Text(model.isScanning ? "Syncing conversations…" : "All agents · \(model.conversations.count) chats")
                        .font(.system(size: 11)).foregroundStyle(Surface.muted)
                }
                Spacer(minLength: 0)
                if model.isScanning { ProgressView().controlSize(.mini) }
                Button { model.showAccounts = true } label: { Image(systemName: "person.crop.circle") }
                    .buttonStyle(.plain).font(.system(size: 17)).foregroundStyle(Surface.muted)
                    .help("Accounts").accessibilityLabel("Accounts")
            }.padding(.horizontal, 18).frame(height: 66)
        }
        .background(Surface.sidebar)
        .overlay(alignment: .trailing) { Surface.stroke.opacity(0.65).frame(width: 1) }
    }

    private func display(_ conversation: Conversation) -> Conversation {
        var copy = conversation; copy.title = model.title(copy.id, fallback: copy.title); return copy
    }
    @ViewBuilder
    private func projectChatRows(_ group: SidebarGroup) -> some View {
        let all = !model.search.isEmpty || chrome.allProjectChats.contains(group.id)
        let recent = Array(group.conversations.prefix(8))
        let selected = group.conversations.filter { chat in
            chat.id == model.selectedID && !recent.contains(where: { $0.id == chat.id })
        }
        let visible = all ? group.conversations : recent + selected
        ForEach(visible) { conversation in
            Button { model.openConversation(conversation.id) } label: {
                HStack(spacing: 3) {
                    if model.experience.organization(conversation.id).pinned { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(Surface.accent) }
                    if model.experience.organization(conversation.id).unread { Circle().fill(Surface.accent).frame(width: 6, height: 6) }
                    ConversationSidebarRow(conversation: display(conversation), selected: model.selectedID == conversation.id)
                }
            }.buttonStyle(SidebarButtonStyle()).padding(.leading, 21).padding(.trailing, 8)
                .contextMenu { ChatOrganizationMenu(id: conversation.id, title: conversation.title, active: [.running, .connecting, .waitingForApproval].contains(conversation.state)) }
        }
        if group.count > 8 && model.search.isEmpty {
            Button(all ? "Show fewer" : "Show all \(group.count) chats") {
                if all { chrome.allProjectChats.remove(group.id) }
                else { chrome.allProjectChats.insert(group.id) }
            }.font(.system(size: 11)).foregroundStyle(Surface.muted).buttonStyle(.plain)
                .padding(.leading, 47).padding(.vertical, 8)
        }
    }

    private var welcome: some View {
        VStack(spacing: 8) {
            ShastraMark(size: 50)
            WorkspaceEmptyState(title: "A space for your best work", message: "Bring your agents, projects, and conversations together. Start with one clear idea.")
            Button { model.beginNewChat() } label: { Label("Start a conversation", systemImage: "plus") }
                .buttonStyle(AppButtonStyle(kind: .primary))
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

}

private struct ChromeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverSurface(content: configuration.label, pressed: configuration.isPressed, radius: 7)
            .frame(width: 30, height: 30)
    }
}

private struct SidebarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverSurface(content: configuration.label, pressed: configuration.isPressed, radius: 8)
            .font(.system(size: 13))
    }
}

private struct HoverSurface<Content: View>: View {
    let content: Content
    let pressed: Bool
    let radius: CGFloat
    @StateObject private var interaction = ViewInteractionModel()
    var body: some View {
        content
            .background(Surface.hover.opacity(pressed ? 1 : interaction.hovered ? 0.7 : 0),
                        in: RoundedRectangle(cornerRadius: radius))
            .contentShape(Rectangle())
            .onHover { interaction.hovered = $0 }
    }
}

private struct ConversationSidebarRow: View {
    let conversation: Conversation
    let selected: Bool
    var body: some View {
        HStack(spacing: 9) {
            Text(conversation.title.replacingOccurrences(of: "\n", with: " "))
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Surface.text.opacity(selected ? 1 : 0.8))
                .lineLimit(1)
            Spacer(minLength: 0)
            Text(Design.age(conversation.updatedAt))
                .font(.system(size: 9)).foregroundStyle(Surface.muted).lineLimit(1).frame(maxWidth: 46)
            if conversation.state == .running || conversation.state == .waitingForApproval {
                Circle().fill(conversation.state == .waitingForApproval ? .orange : .green)
                    .frame(width: 5, height: 5)
            }
        }
        .padding(.horizontal, 12).frame(height: 36)
        .background(selected ? Surface.selected : .clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .leading) {
            if selected { Capsule().fill(Surface.accent).frame(width: 3, height: 16).padding(.leading, 3) }
        }
        .help(conversation.sourceKind ?? conversation.provider.title)
    }
}

private struct ProviderMark: View {
    let provider: Provider
    var size: CGFloat = 32
    private var symbol: String {
        switch provider {
        case .codex: "circle.hexagongrid"
        case .cursor: "cursorarrow.rays"
        case .claude: "sparkle"
        case .grok: "xmark"
        case .opencode: "chevron.left.forwardslash.chevron.right"
        case .hermes: "bolt"
        }
    }
    private var tint: Color {
        switch provider {
        case .codex: .mint
        case .cursor: .indigo
        case .claude: .orange
        case .grok: .primary
        case .opencode: .cyan
        case .hermes: .purple
        }
    }
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.43, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: size * 0.28))
            .accessibilityLabel(provider.title)
    }
}

private struct ConversationPane: View {
    @EnvironmentObject private var model: AppModel
    let conversation: Conversation
    @FocusState private var composerFocused: Bool

    private enum TimelineItem: Identifiable {
        case entry(Entry)
        case tools([Entry])
        var id: UUID {
            switch self {
            case .entry(let entry): entry.id
            case .tools(let entries): entries[0].id
            }
        }
    }

    private var timeline: [TimelineItem] {
        var items: [TimelineItem] = []
        var pendingTools: [Entry] = []
        for entry in conversation.entries {
            if entry.kind == .tool { pendingTools.append(entry) }
            else {
                if !pendingTools.isEmpty { items.append(.tools(pendingTools)); pendingTools = [] }
                items.append(.entry(entry))
            }
        }
        if !pendingTools.isEmpty { items.append(.tools(pendingTools)) }
        return items
    }

    private var canSend: Bool {
        !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        ![.running, .connecting, .waitingForApproval].contains(conversation.state) &&
        !model.hasUnresolvedDelivery(conversation) && conversation.nativeResumeUnavailableReason == nil &&
        conversation.historyLoaded != false &&
        model.availability.first { $0.provider == conversation.provider }?.isReady == true
    }

    var body: some View {
        VStack(spacing: 0) {
            ConversationRunStatus(conversation: conversation)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        if conversation.historyLoaded == false && model.loadingHistoryID == conversation.id {
                            VStack(spacing: 14) {
                                ProgressView().controlSize(.small)
                                Text("Opening your conversation…").font(.system(size: 13, weight: .medium))
                                Text("Restoring messages and context").font(.system(size: 11)).foregroundStyle(Surface.muted)
                            }.foregroundStyle(Surface.text).frame(maxWidth: .infinity).padding(.vertical, 36)
                        }
                        if let failure = model.historyErrors[conversation.id] {
                            VStack(alignment: .leading, spacing: 10) {
                                Label("Couldn't load this conversation", systemImage: "exclamationmark.triangle")
                                    .font(.system(size: 13, weight: .medium))
                                Text(failure).font(.system(size: 12)).foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                Button("Retry") { model.retrySelectedHistory() }
                                    .buttonStyle(.bordered)
                            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                                .background(Surface.raised, in: RoundedRectangle(cornerRadius: 10))
                        }
                        if conversation.entries.isEmpty && conversation.historyLoaded == true {
                            WorkspaceEmptyState(title: "No local messages yet", message: "This conversation is saved, but its messages aren't available on this Mac.", symbol: "bubble.left.and.text.bubble.right")
                        }
                        ForEach(timeline) { item in
                            switch item {
                            case .entry(let entry):
                                MessageRow(entry: entry, provider: conversation.nativeEndpoints.first(where: { $0.id == entry.endpointID })?.provider ?? conversation.sourceEndpoint?.provider ?? conversation.provider).id(item.id)
                                    .padding(4).background(model.jumpToEntryID == entry.id ? Surface.selected : .clear, in: RoundedRectangle(cornerRadius: 8))
                            case .tools(let entries):
                                ToolActivityGroup(entries: entries).id(item.id)
                            }
                        }
                        if conversation.state == .completed {
                            CompletionReview(entries: conversation.entries, result: nil) { model.requestedTool = "changes" }
                        }
                        ForEach(model.approvals.filter { $0.conversationID == conversation.id }) { approval in
                            ApprovalCard(approval: approval).id(approval.id)
                        }
                        ForEach(model.questions.filter { $0.conversationID == conversation.id }) { question in
                            QuestionCard(question: question).id(question.id)
                        }
                    }
                    .frame(maxWidth: Design.readingWidth)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, Design.contentInset).padding(.vertical, Design.contentInset)
                }
                .onAppear { if let target = model.jumpToEntryID { proxy.scrollTo(target, anchor: .center) } }
                .onChange(of: model.jumpToEntryID) { _, target in if let target { proxy.scrollTo(target, anchor: .center) } }
                .defaultScrollAnchor(.bottom)
                .onChange(of: conversation.entries.count) { _, _ in
                    if let target = model.jumpToEntryID { proxy.scrollTo(target, anchor: .center) }
                    else if let last = timeline.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }

            composer
        }
        .background(Surface.canvas)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            ComposerContextBar(key: conversation.id.uuidString, workspace: conversation.workingDirectory, draft: $model.draft)
            if let reason = conversation.nativeResumeUnavailableReason {
                VStack(alignment: .leading, spacing: 8) {
                    Text(reason).font(.system(size: 11)).foregroundStyle(Surface.muted)
                    HStack {
                        Button("Open Cursor") { model.openCursorForContinuation() }.buttonStyle(AppButtonStyle())
                        Button("Copy follow-up") {
                            let text = ComposerContext.prompt(model.draft, files: model.experience.attachments[conversation.id.uuidString] ?? [])
                            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                        }.buttonStyle(AppButtonStyle(kind: .quiet)).disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }.padding(12).background(Surface.selected.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
            }

            if model.workspaceIdentities[conversation.workingDirectory]?.branch != nil {
                ComposerActions(draft: $model.draft)
            }
            VStack(alignment: .leading, spacing: 20) {
                TextField("Plan, build, or ask anything", text: $model.draft, axis: .vertical)
                    .lineLimit(2...8)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .padding(.top, 2)
                    .onSubmit { if canSend { model.send() } }
                    .accessibilityLabel("Message \(conversation.provider.title)")
                    .modifier(ComposerImagePaste(key: conversation.id.uuidString))
                    .focused($composerFocused)
                HStack(spacing: 8) {
                    Menu {
                        Button("Add file reference…") { addFileReference() }
                        Button("Add workspace path") { model.draft += "\nWorkspace: \(conversation.workingDirectory)" }
                    } label: {
                        Image(systemName: "plus").font(.system(size: 16, weight: .light))
                            .frame(width: 27, height: 27).background(Surface.hover, in: Circle())
                    }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .help("Add context")
                    Menu {
                        Text("Keep this provider to resume the same thread")
                        Divider()
                        ForEach(Provider.allCases) { provider in
                            if model.availability.first(where: { $0.provider == provider })?.isReady == true {
                                Button(provider == conversation.provider ? "Continue in this thread" : "Start linked session with \(provider.title)") { model.continueWith(provider) }
                                    .disabled([.running, .connecting, .waitingForApproval].contains(conversation.state)
                                              || conversation.historyLoaded == false || model.hasUnresolvedDelivery(conversation))
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Text(conversation.provider.title)
                            Image(systemName: "chevron.down").font(.system(size: 8))
                        }.font(.system(size: 12))
                    }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    if AccountStore.providers.contains(conversation.provider) { ConversationAccountMenu(conversation: conversation) }
                    Spacer()
                    if [.running, .connecting, .waitingForApproval].contains(conversation.state) {
                        Button { model.cancel() } label: {
                            Image(systemName: "stop.fill").font(.system(size: 12))
                                .foregroundStyle(Surface.canvas)
                                .frame(width: 28, height: 28).background(Surface.text, in: Circle())
                        }.buttonStyle(.plain).help("Stop agent")
                    } else {
                        Button { model.send() } label: {
                            Image(systemName: "arrow.up").font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(canSend ? Surface.onAccent : Surface.muted)
                                .frame(width: 28, height: 28)
                                .background(canSend ? Surface.accent : Surface.hover, in: Circle())
                        }.buttonStyle(.plain).disabled(!canSend).help("Send message")
                    }
                }.foregroundStyle(Surface.muted)
            }
            .padding(14)
            .composerSurface(focused: composerFocused)
            ComposerWorkspaceBar(path: conversation.workingDirectory, isNew: false, background: false)
            if conversation.sourceIdentity != nil, conversation.sourceEndpoint?.workingDirectory == nil,
               conversation.linkedWorkspaceConfirmed != true {
                Button("Choose workspace…") { model.chooseLinkedWorkspace() }.font(.caption)
            }
            Text(model.hasUnresolvedDelivery(conversation)
                 ? "Delivery outcome unknown · Check the originating runtime before retrying"
                 : conversation.continuityLabel)
                .font(.system(size: 10)).foregroundStyle(Surface.muted).padding(.horizontal, 5)
        }
        .frame(maxWidth: Design.readingWidth)
        .padding(.horizontal, Design.contentInset).padding(.top, 12).padding(.bottom, 16)
        .frame(maxWidth: .infinity)
    }

    private func addFileReference() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: conversation.workingDirectory)
        if panel.runModal() == .OK {
            for url in panel.urls { model.draft += "\nFile reference: \(url.path)" }
        }
    }
}

private struct ToolActivityGroup: View {
    let entries: [Entry]
    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(entries) { entry in
                    Text(entry.text)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Surface.muted)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if entry.id != entries.last?.id { Surface.stroke.frame(height: 1) }
                }
            }.padding(.top, 12)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                Text(entries.count == 1 ? "Tool activity" : "\(entries.count) tool actions")
            }
            .font(.system(size: 12))
            .foregroundStyle(Surface.muted)
        }
        .padding(.vertical, 3)
    }
}

private struct MessageRow: View {
    let entry: Entry
    let provider: Provider
    @StateObject private var interaction = ViewInteractionModel()
    private var isLongMessage: Bool {
        entry.text.count > 700 || entry.text.components(separatedBy: "\n").count > 8
    }
    var body: some View {
        Group {
            switch entry.kind {
            case .user:
                VStack(alignment: .leading, spacing: 10) {
                    Text(entry.text)
                        .textSelection(.enabled)
                        .font(.system(size: 13)).lineSpacing(4)
                        .foregroundStyle(Surface.text)
                        .lineLimit(isLongMessage && !interaction.expanded ? 8 : nil)
                    CopyTextButton(text: entry.text)
                    if isLongMessage {
                        Button(interaction.expanded ? "Show less" : "Show full message") { interaction.expanded.toggle() }
                            .font(.system(size: 11, weight: .medium)).buttonStyle(.plain)
                            .foregroundStyle(Surface.muted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(13)
                .background(Surface.selected.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
            case .assistant:
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 7) {
                        ProviderMark(provider: provider, size: 22)
                        Text(provider.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Surface.muted)
                    }
                    MarkdownMessage(text: entry.text)
                    CopyTextButton(text: entry.text, label: "Copy agent response")
                        .accessibilityIdentifier("copy-message-" + entry.id.uuidString)
                }.onHover { interaction.hovered = $0 }
            case .tool:
                ToolActivityGroup(entries: [entry])
            case .status, .continuation:
                HStack(spacing: 6) {
                    Image(systemName: entry.kind == .continuation ? "arrow.triangle.branch" : "checkmark")
                    Text(entry.text).lineLimit(2)
                }
                .font(.system(size: 11)).foregroundStyle(Surface.muted)
                .frame(maxWidth: .infinity)
            case .error:
                Label(entry.text, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 13)).foregroundStyle(.red)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ApprovalCard: View {
    @EnvironmentObject private var model: AppModel
    let approval: PendingApproval
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Label("Approval required", systemImage: "hand.raised")
                .font(.system(size: 13, weight: .semibold))
            Text(approval.detail).font(.caption).textSelection(.enabled)
            HStack {
                ForEach(approval.options, id: \.self) { choice in
                    if choice.contains("reject") || choice.contains("deny") || choice == "decline" {
                        Button(choice.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ").capitalized) {
                            model.answer(approval, choice: choice)
                        }.buttonStyle(.bordered)
                    } else {
                        Button(choice.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ").capitalized) {
                            model.answer(approval, choice: choice)
                        }.buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.orange.opacity(0.2)))
    }
}

struct InspectorPane: View {
    @EnvironmentObject private var model: AppModel
    let conversation: Conversation
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 23) {
                HStack {
                    Text("Inspector").font(.system(size: 17, weight: .semibold))
                    Spacer()
                }
                InspectorSection(title: "SOURCE") {
                    InspectorValue(label: "App", value: conversation.sourceKind ?? "Shastra")
                    InspectorValue(label: "Agent", value: conversation.provider.title)
                    InspectorValue(label: "Status", value: conversation.state.rawValue.capitalized)
                }
                InspectorSection(title: "WORKSPACE") {
                    Text(conversation.workingDirectory)
                        .font(.caption).textSelection(.enabled)
                        .foregroundStyle(.secondary)
                    if FileManager.default.fileExists(atPath: conversation.workingDirectory) {
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: conversation.workingDirectory)
                        }.font(.caption)
                    }
                }
                InspectorSection(title: "SESSION") {
                    InspectorValue(label: "Account", value: model.accountLabel(for: conversation))
                    if let id = conversation.vendorSessionID {
                        Text(id).font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if conversation.sourceIdentity != nil {
                        Text("Source history is read-only. Select Continue with to start a linked runtime. Desktop sending is not yet verified.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                InspectorSection(title: "NATIVE ENDPOINTS") {
                    ForEach(conversation.nativeEndpoints) { endpoint in
                        VStack(alignment: .leading, spacing: 5) {
                            Text("\(endpoint.provider.title) · \(endpoint.surface.rawValue)").font(.caption)
                            Text(endpoint.nativeThreadID).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                            Text("\(endpoint.ownership.rawValue) · History \(endpoint.completeness.rawValue)")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    if conversation.entries.contains(where: { $0.provenance == nil }) {
                        Text("Legacy timeline entries retain unknown provenance.").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                InspectorSection(title: "USAGE") {
                    Text("No quota data reported by this session")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
        .background(Surface.dock)
    }
}

private struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            content
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct InspectorValue: View {
    let label: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }.font(.caption)
    }
}

