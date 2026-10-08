import AppKit
import SwiftUI
import ShastraCore

struct AgentBoardView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var board: AgentBoardModel
    @StateObject private var ui = BoardViewState()
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                HStack(spacing: 8) {
                    Circle().fill(board.connected ? Surface.accent : Surface.warning).frame(width: 6, height: 6)
                    Text("\((board.snapshot?.tasks ?? []).filter { !$0.archived && $0.status.isActive }.count) active")
                    Text("·")
                    Text("\(board.attentionCount) need attention")
                }.font(.system(size: 11)).foregroundStyle(Surface.muted)
                    .help(board.connected ? "Connected · Agents keep working when you close the window" : "Agent service offline")
                Spacer()
                Button { ui.showWorkspaces.toggle() } label: { Image(systemName: "folder.badge.gearshape") }
                    .buttonStyle(AppButtonStyle()).help("Manage workspaces")
                Picker("Agent layout", selection: $ui.boardMode) {
                    Image(systemName: "list.bullet").tag(false)
                    Image(systemName: "rectangle.split.3x1").tag(true)
                }.pickerStyle(.segmented).frame(width: 78).labelsHidden()
                Button { app.beginNewChat(background: true) } label: { Label("New agent", systemImage: "plus") }
                    .buttonStyle(AppButtonStyle(kind: .primary)).keyboardShortcut("n", modifiers: [.command, .shift])
            }.padding(.horizontal, Design.headerInset).padding(.vertical, 8)
            if !board.connected {
                HStack { Label("Agent service disconnected", systemImage: "wifi.slash"); Spacer(); Button("Reconnect") { Task { do { try await board.client.ensureRunning(); await board.refresh() } catch { board.error = error.localizedDescription } } } }
                    .font(.caption).padding(10).background(Surface.warning.opacity(0.1))
            }
            Divider()
            if ui.boardMode {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(TaskColumn.allCases, id: \.self) { column in
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Circle().fill(columnColor(column)).frame(width: 7, height: 7)
                                    Text(column.rawValue).font(.system(size: 12, weight: .semibold))
                                    Spacer()
                                    Text("\(board.tasks.filter { $0.column == column }.count)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Surface.muted)
                                }.padding(.vertical, 5)
                                if board.tasks.filter({ $0.column == column }).isEmpty {
                                    Text("Nothing here yet").font(.system(size: 11)).foregroundStyle(Surface.muted)
                                        .frame(maxWidth: .infinity).padding(.vertical, 24)
                                }
                                ForEach(board.tasks.filter { $0.column == column }) { task in
                                    Button { board.selectedID = task.id; ui.boardMode = false } label: { taskCard(task) }.buttonStyle(.plain)
                                }
                                Spacer()
                            }.padding(12).frame(width: 235).frame(minHeight: 240)
                                .background(Surface.dock, in: RoundedRectangle(cornerRadius: Design.cardRadius))
                                .overlay(RoundedRectangle(cornerRadius: Design.cardRadius).stroke(Surface.stroke.opacity(0.6)))
                        }
                    }.padding(16)
                }
            } else {
                HSplitView {
                    VStack(spacing: 12) {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass").foregroundStyle(Surface.muted)
                            TextField("Find an agent…", text: $board.search).textFieldStyle(.plain)
                        }.font(.system(size: 12)).padding(10).background(Surface.raised, in: RoundedRectangle(cornerRadius: 8))
                        Picker("Filter", selection: $board.filter) {
                            Text("All").tag("All"); Text("Running").tag("Running"); Text("Needs you").tag("Inbox"); Text("Archived").tag("Archived")
                        }.pickerStyle(.menu).labelsHidden()
                        if board.tasks.isEmpty {
                            WorkspaceEmptyState(title: "No agents here", message: board.search.isEmpty ? "Start an agent to put your next idea in motion." : "Try a different search or filter.", symbol: "person.crop.circle.badge.magnifyingglass")
                        }
                        List(selection: $board.selectedID) {
                            ForEach(board.tasks.sorted { app.experience.organization($0.id).pinned && !app.experience.organization($1.id).pinned }) { task in
                                taskCard(task).tag(task.id).contextMenu { ChatOrganizationMenu(id: task.id, title: task.title, active: task.status.isActive) }
                            }
                        }.listStyle(.sidebar)
                    }.padding(.top, 14).padding(.horizontal, 12).frame(minWidth: 240, idealWidth: 280, maxWidth: 330).background(Surface.dock)
                    if let task = board.selected, board.tasks.contains(where: { $0.id == task.id }) {
                        AgentTaskDetail(board: board, task: task, spawn: { sideChat in ui.parent = task; ui.sideChat = sideChat; ui.showNew = true }).id(task.id)
                    } else {
                        VStack(spacing: 4) {
                            WorkspaceEmptyState(title: "Your next collaborator", message: "Start an agent with a clear task, then follow its progress here.", symbol: "person.2.wave.2")
                            Button("Start an agent") { app.beginNewChat(background: true) }.buttonStyle(AppButtonStyle(kind: .primary))
                        }.frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .onChange(of: board.selectedID) { _, id in if let id { app.organize(id) { $0.unread = false } } }
        .sheet(isPresented: $ui.showNew) { NewAgentSheet(board: board, parent: ui.parent, sideChat: ui.sideChat).environmentObject(app) }
        .sheet(isPresented: $ui.showWorkspaces) { ManagedWorkspacesView(board: board) }
        .alert("Agent workspace", isPresented: Binding(get: { board.error != nil }, set: { if !$0 { board.error = nil } })) {
            Button("OK") { board.error = nil }
        } message: { Text(board.error ?? "") }
    }
    private func columnColor(_ column: TaskColumn) -> Color {
        switch column {
        case .todo: Surface.muted
        case .running: Surface.accent
        case .needsInput: Surface.warning
        case .review: .purple
        case .done: Surface.accent
        }
    }
    private func taskCard(_ task: AgentTask) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 5) {
                if app.experience.organization(task.id).pinned { Image(systemName: "pin.fill").font(.caption2) }
                if app.experience.organization(task.id).unread { Circle().fill(Surface.accent).frame(width: 6, height: 6) }
                Text(app.title(task.id, fallback: task.title)).font(.system(size: 13, weight: .semibold)).foregroundStyle(Surface.text).lineLimit(2)
            }
            HStack(spacing: 6) {
                StatusPill(title: task.status.displayName, symbol: task.status.symbol, color: task.status.color)
                Spacer()
                if !task.approvals.isEmpty { Image(systemName: "exclamationmark.bubble.fill").foregroundStyle(Surface.warning).help("Approval needed") }
            }
            HStack {
                Text(task.provider.title)
                if task.parentID != nil { Image(systemName: "arrow.turn.down.right").help("Worker agent") }
                Spacer()
                Text(Design.age(task.updatedAt)).lineLimit(1)
            }.font(.system(size: 10)).foregroundStyle(Surface.muted)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Surface.raised, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(board.selectedID == task.id ? Surface.accent.opacity(0.6) : Surface.stroke.opacity(0.6)))
            .padding(.vertical, 2)
    }

}

private struct AgentTaskDetail: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var board: AgentBoardModel
    let task: AgentTask
    let spawn: (Bool) -> Void
    @StateObject private var ui = TaskDetailState()
    @StateObject private var workspaceTools = WorkspaceToolsModel()
    private var conversation: Conversation {
        var value = Conversation(provider: task.provider, workingDirectory: task.workspace)
        value.id = task.id; value.title = task.title; value.entries = task.entries; value.vendorSessionID = task.nativeID
        return value
    }
    var body: some View {
        HSplitView {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 7) {
                    Text(app.title(task.id, fallback: task.title)).font(.system(size: 16, weight: .semibold)).lineLimit(2)
                    HStack(spacing: 8) {
                        StatusPill(title: task.status.displayName, symbol: task.status.symbol, color: task.status.color)
                        Text(task.provider.title).font(.caption).foregroundStyle(Surface.muted)
                    }
                }
                Spacer()
                Toggle("Workspace", isOn: $ui.showTools).toggleStyle(.button)
                Menu("Actions") {
                    ChatOrganizationMenu(id: task.id, title: task.title, active: task.status.isActive)
                    Button("Assign a worker…") { spawn(false) }
                    Button("Open a side chat…") { spawn(true) }
                    Button("Save workspace checkpoint") { action("task.checkpoint") }.disabled(task.status.isActive || task.status == .queued)
                    Button("Reveal workspace") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: task.workspace) }
                    Button("Copy task ID") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(task.id.uuidString, forType: .string) }
                    ForEach(TaskColumn.allCases, id: \.self) { column in Button("Move to \(column.rawValue)") { action("task.column", ["column": column.rawValue]) } }
                }
                if task.status.isActive || task.status == .queued { Button("Stop") { action("agents.cancel") } }
            }.padding(16)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if !task.acceptance.isEmpty { Label(task.acceptance, systemImage: "checklist").font(.callout).foregroundStyle(.secondary) }
                    if task.recoveryPending == true {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("The previous runtime must be stopped before resuming.").font(.headline)
                            TextField("Inspection evidence", text: $ui.evidence)
                            Button("I confirmed the previous runtime stopped") { action("task.reconcile", ["evidence": ui.evidence]) }.disabled(ui.evidence.isEmpty)
                        }.padding().background(Surface.selected, in: RoundedRectangle(cornerRadius: 10))
                    }
                    ForEach(task.entries) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Label(entry.kind == .assistant ? task.provider.title : entry.kind == .user ? "You" : entry.kind.rawValue.capitalized,
                                      systemImage: entry.kind == .assistant ? "sparkle" : entry.kind == .user ? "person.crop.circle" : "circle.dotted")
                                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(Surface.muted)
                                Spacer()
                                CopyTextButton(text: entry.text, label: entry.kind == .assistant ? "Copy agent response" : "Copy message")
                                    .accessibilityIdentifier("copy-message-" + entry.id.uuidString)
                            }
                            if entry.kind == .assistant { MarkdownMessage(text: entry.text) }
                            else { Text(entry.text).font(entry.kind == .tool ? .system(.caption, design: .monospaced) : .body).textSelection(.enabled) }
                        }.frame(maxWidth: Design.readingWidth, alignment: .leading)
                            .padding(entry.kind == .user ? 14 : 0)
                            .background(entry.kind == .user ? Surface.selected.opacity(0.5) : .clear, in: RoundedRectangle(cornerRadius: 12))
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    if task.status == .completed {
                        CompletionReview(entries: task.entries, result: task.result) { workspaceTools.setRoot(task.workspace); workspaceTools.tab = .changes; ui.showTools = true }
                    }
                    if [.failed, .interrupted, .cancelled].contains(task.status), task.recoveryPending != true {
                        HStack {
                            Label(task.status.displayName, systemImage: "exclamationmark.circle").foregroundStyle(Surface.warning)
                            Spacer()
                            Button("Prepare follow-up") {
                                if (board.drafts[task.id.uuidString] ?? "").isEmpty { board.drafts[task.id.uuidString] = "Continue from where you stopped. Inspect the current state before changing anything." }
                            }.buttonStyle(AppButtonStyle())
                        }
                    }
                    ForEach(task.approvals) { approval in ServiceApprovalView(board: board, taskID: task.id, approval: approval) }
                    ForEach(task.messages.filter { $0.state == .unknown }) { message in
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Delivery needs inspection", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                            Text(message.text).lineLimit(3)
                            TextField("Evidence from the originating runtime", text: $ui.evidence)
                            HStack {
                                Button("Confirmed accepted") { resolve(message, accepted: true) }
                                Button("Confirmed not accepted") { resolve(message, accepted: false) }
                            }.disabled(ui.evidence.isEmpty)
                            Text("Recording an outcome never resends the prompt.").font(.caption).foregroundStyle(.secondary)
                        }.padding().background(Surface.selected, in: RoundedRectangle(cornerRadius: 10))
                    }
                }.padding(22)
            }
            VStack(alignment: .leading, spacing: 10) {
            ComposerContextBar(key: task.id.uuidString, workspace: task.workspace, draft: Binding(get: { board.drafts[task.id.uuidString] ?? "" }, set: { board.drafts[task.id.uuidString] = $0 }))
            if app.workspaceIdentities[task.workspace]?.branch != nil {
                ComposerActions(draft: Binding(get: { board.drafts[task.id.uuidString] ?? "" }, set: { board.drafts[task.id.uuidString] = $0 }))
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(task.messages.filter { $0.state == .queued }) { message in
                    HStack { Label(message.text, systemImage: "clock").lineLimit(2).font(.caption); Spacer(); Button { action("message.cancel", ["messageID": message.id.uuidString]) } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }
                }
                TextField(task.status.isActive ? "Queue a follow-up…" : "Message this agent…", text: Binding(get: { board.drafts[task.id.uuidString] ?? "" }, set: { board.drafts[task.id.uuidString] = $0 }), axis: .vertical)
                    .lineLimit(2...8).textFieldStyle(.plain)
                    .modifier(ComposerImagePaste(key: task.id.uuidString))
                HStack {
                    Text("\(task.provider.title) · \(task.model ?? "Default model") · \(task.column.rawValue)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(task.status.isActive ? "Queue" : "Send") { board.send(task, files: app.experience.attachments[task.id.uuidString] ?? []) { app.experience.attachments[task.id.uuidString] = [] } }.buttonStyle(AppButtonStyle(kind: .primary)).keyboardShortcut(.return, modifiers: .command)
                        .disabled(board.busy || task.messages.contains { $0.state == .unknown } || (board.drafts[task.id.uuidString] ?? "").isEmpty)
                }
            }.padding(16).composerSurface()
            ComposerWorkspaceBar(path: task.workspace, isNew: false, background: true)
            }.padding(14)
        }.frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
        if ui.showTools {
            WorkspaceToolsView(tools: workspaceTools, conversation: conversation)
                .frame(minWidth: 350, idealWidth: 440)
                .onAppear { workspaceTools.setRoot(task.workspace) }
                .onChange(of: task.workspace) { _, path in workspaceTools.setRoot(path) }
        }
        }
    }
    private func action(_ method: String, _ params: [String: String] = [:]) { board.perform(method, params: params.merging(["taskID": task.id.uuidString]) { _, value in value }) }
    private func resolve(_ message: TaskMessage, accepted: Bool) { action("delivery.resolve", ["messageID": message.id.uuidString, "accepted": String(accepted), "evidence": ui.evidence]); ui.evidence = "" }
}

private struct ServiceApprovalView: View {
    @ObservedObject var board: AgentBoardModel
    let taskID: UUID
    let approval: TaskApproval
    @StateObject private var ui = ServiceApprovalState()
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(approval.detail, systemImage: "hand.raised").textSelection(.enabled)
            if let questions = approval.questions {
                ForEach(questions, id: \.prompt) { question in
                    Text(question.prompt)
                    TextField(question.multiSelect ? "Answers, separated by newlines" : "Your answer", text: Binding(get: { ui.answers[question.prompt] ?? "" }, set: { ui.answers[question.prompt] = $0 }), axis: .vertical)
                    ForEach(question.options, id: \.self) { option in Button(option) { ui.answers[question.prompt] = question.multiSelect && ui.answers[question.prompt]?.isEmpty == false ? ui.answers[question.prompt]! + "\n" + option : option } }
                }
                Button("Submit answers") {
                    let data = try? JSONEncoder().encode(ui.answers.mapValues { $0.components(separatedBy: "\n").filter { !$0.isEmpty } })
                    board.perform("approval.answer", params: ["taskID": taskID.uuidString, "requestID": approval.id, "answers": String(decoding: data ?? Data(), as: UTF8.self)])
                }.disabled(questions.contains { (ui.answers[$0.prompt] ?? "").isEmpty })
            } else {
                HStack { ForEach(approval.options, id: \.self) { option in Button(option) { board.perform("approval.answer", params: ["taskID": taskID.uuidString, "requestID": approval.id, "choice": option]) } } }
            }
        }.padding(16).background(Surface.selected, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct NewAgentSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var board: AgentBoardModel
    let parent: AgentTask?
    let sideChat: Bool
    @StateObject private var ui = NewAgentState()
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(sideChat ? "Side chat" : parent == nil ? "New agent" : "Assign a worker").font(.title2.bold())
            if let parent { Text("Parent: \(parent.title)").foregroundStyle(.secondary) }
            TextField("Task title", text: $ui.title).textFieldStyle(.roundedBorder)
            TextField("What should this agent accomplish?", text: $ui.objective, axis: .vertical).lineLimit(4...10).textFieldStyle(.roundedBorder)
            TextField("Acceptance criteria and required checks", text: $ui.acceptance, axis: .vertical).lineLimit(2...4).textFieldStyle(.roundedBorder)
            HStack {
                Picker("Provider", selection: Binding(get: { ui.provider }, set: { ui.provider = $0; ui.accountID = ""; ui.model = "" })) { ForEach(Provider.allCases.filter(\.supportedInMVP)) { Text($0.title).tag($0) } }
                Picker("Account", selection: $ui.accountID) { Text("Current provider login").tag(""); ForEach(app.accounts.filter { $0.provider == ui.provider }) { Text($0.label).tag($0.id.uuidString) } }
            }
            ModelPicker(provider: ui.provider, model: $ui.model, accountID: UUID(uuidString: ui.accountID), workspace: ui.workspace)
            WorkspaceSelector(path: ui.workspace, paths: app.recentWorkspacePaths) { path in
                ui.workspace = path
                ui.workspaceError = nil
            }.disabled(parent != nil)
            if let error = ui.workspaceError {
                Text(error).font(.caption).foregroundStyle(Surface.warning)
            }
            if let checkpoints = parent?.checkpoints, !checkpoints.isEmpty {
                Picker("Start from", selection: $ui.checkpointID) {
                    Text("Current workspace").tag("")
                    ForEach(checkpoints) { Text($0.createdAt.formatted()).tag($0.id.uuidString) }
                }
                Text("A checkpoint starts in a new worktree; the current workspace is preserved.").font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Use an isolated Git worktree", isOn: $ui.isolate).disabled(!ui.checkpointID.isEmpty)
            Text(ui.isolate ? "Copies committed, staged, unstaged, and eligible untracked files. Requires a Git commit." : "Uses the selected folder. Shastra serializes its own agents sharing this workspace.").font(.caption).foregroundStyle(.secondary)
            if parent != nil { Toggle("Queue the worker’s result to its parent", isOn: $ui.report) }
            DisclosureGroup("Dependencies") {
                ScrollView { ForEach((board.snapshot?.tasks ?? []).filter { !$0.archived }) { task in Toggle(task.title, isOn: Binding(get: { ui.dependencies.contains(task.id) }, set: { if $0 { ui.dependencies.insert(task.id) } else { ui.dependencies.remove(task.id) } })) } }.frame(maxHeight: 100)
            }
            HStack { Button("Cancel") { dismiss() }; Spacer(); Button("Start agent") { create() }.buttonStyle(.borderedProminent).disabled(ui.objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || ui.workspace.isEmpty || board.busy || ui.validatingWorkspace) }
        }.padding(24).frame(width: 580).onAppear { ui.workspace = parent?.workspace ?? app.selected?.workingDirectory ?? app.workingDirectory; ui.provider = parent?.provider ?? .codex; ui.accountID = parent?.accountID?.uuidString ?? ""; ui.model = parent?.model ?? ""; if sideChat { ui.isolate = false; ui.report = false } }
    }
    private func create() {
        guard !ui.validatingWorkspace else { return }
        ui.validatingWorkspace = true
        Task {
            defer { ui.validatingWorkspace = false }
            guard let root = await app.validatedGitWorkspace(ui.workspace) else {
                ui.workspaceError = "Choose an existing Git repository or worktree."; return
            }
            ui.workspace = root
            spawn()
        }
    }
    private func spawn() {
        var params = ["objective": ui.objective, "title": ui.title.isEmpty ? String(ui.objective.prefix(60)) : ui.title, "acceptance": ui.acceptance, "provider": ui.provider.rawValue, "workspace": ui.workspace, "isolate": String(ui.isolate), "notifyParent": String(ui.report), "dependencies": ui.dependencies.map(\.uuidString).joined(separator: ",")]
        if let parent { params["parentID"] = parent.id.uuidString; params["includeParentContext"] = sideChat ? "true" : "false" }; if !ui.model.isEmpty { params["model"] = ui.model }; if !ui.accountID.isEmpty { params["accountID"] = ui.accountID }
        if !ui.checkpointID.isEmpty { params["checkpointID"] = ui.checkpointID }
        board.perform("agents.spawn", params: params, selectResult: true) { dismiss() }
    }
}

private struct ManagedWorkspacesView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var board: AgentBoardModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Managed workspaces").font(.title2.bold()); Spacer(); Button("Done") { dismiss() } }
            Picker("Parallel agents", selection: Binding(get: { board.snapshot?.maxParallel ?? 4 }, set: { board.perform("service.settings", params: ["maxParallel": String($0)]) })) {
                ForEach(1...10, id: \.self) { Text(String($0)).tag($0) }
            }
            Text("Up to two turns per provider account. Shared workspaces run one Shastra writer at a time.").font(.caption).foregroundStyle(.secondary)
            List(board.snapshot?.workspaces ?? []) { workspace in
                VStack(alignment: .leading, spacing: 8) {
                    Text(workspace.branch).font(.headline)
                    Text(workspace.path).font(.caption).textSelection(.enabled)
                    Text(workspace.archived ? "Archived · snapshot preserved" : "Active · \(workspace.snapshot.untracked.count) untracked files in snapshot").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button(workspace.archived ? "Restore" : "Archive") { board.perform(workspace.archived ? "workspaces.restore" : "workspaces.archive", params: ["workspaceID": workspace.id.uuidString]) }
                        if !workspace.archived { Button("Reveal") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: workspace.path) } }
                    }
                }.padding(8)
            }
        }.padding(20).frame(width: 660, height: 460)
    }
}

@MainActor private final class BoardViewState: ObservableObject {
    @Published var sideChat = false
    @Published var showNew: Bool = false
    @Published var parent: AgentTask? = nil
    @Published var boardMode: Bool = false
    @Published var showWorkspaces: Bool = false
}

@MainActor private final class TaskDetailState: ObservableObject {
    @Published var showTools = false
    @Published var evidence: String = ""
}

@MainActor private final class ServiceApprovalState: ObservableObject {
    @Published var answers: [String: String] = [:]
}

@MainActor private final class NewAgentState: ObservableObject {
    @Published var title: String = ""
    @Published var objective: String = ""
    @Published var acceptance: String = ""
    @Published var provider: Provider = .codex
    @Published var accountID: String = ""
    @Published var model: String = ""
    @Published var workspaceError: String?
    @Published var validatingWorkspace = false
    @Published var workspace: String = ""
    @Published var isolate: Bool = true
    @Published var report: Bool = true
    @Published var checkpointID = ""
    @Published var dependencies: Set<UUID> = []
}
