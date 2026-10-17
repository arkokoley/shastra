import AppKit
import SwiftUI
import ShastraCore

// Name the property-wrapper type explicitly for SDKs that also export a State macro.
typealias ViewState<Value> = SwiftUI.State<Value>

struct CollaborationBar: View {
    @EnvironmentObject private var app: AppModel
    let workspace: String
    var sourceID: UUID?
    var compact = false
    var body: some View {
        Group {
            if compact {
                Menu { actions } label: { Label("Context", systemImage: "books.vertical") }
                    .menuStyle(.borderlessButton).fixedSize().font(.system(size: 11))
                    .help("Project context, annotations, and fork comparison")
            } else {
                HStack(spacing: 10) { actions; Spacer(minLength: 0) }
                    .font(.caption).padding(.horizontal, 16).padding(.vertical, 8)
            }
        }.task(id: workspace) { await app.resolveWorkspace(workspace); await app.refreshCollaboration() }
    }
    @ViewBuilder private var actions: some View {
        Button { app.openProjectContext(workspace) } label: {
            Label(app.projectContext(workspace).isEmpty ? "Project context" : "Project context · v\(app.projectContext(workspace).revision)", systemImage: "books.vertical")
        }.buttonStyle(AppButtonStyle(compact: true)).disabled(workspace.isEmpty)
        if let sourceID, let source = app.chatSource(sourceID) {
            let count = app.collaboration.annotations.filter { $0.anchor.sourceID == sourceID && !$0.resolved }.count
            Button { app.collaborationRoute = .annotations(source) } label: { Label("Annotations · \(count)", systemImage: "text.bubble") }
                .buttonStyle(AppButtonStyle(compact: true))
            if let task = app.agentBoard.snapshot?.tasks.first(where: { $0.id == sourceID }), task.forkOrigin != nil {
                Button("Compare fork") { app.collaborationRoute = .compare(task.id) }.buttonStyle(AppButtonStyle(compact: true))
            }
        }
    }
}

struct MessageActions: View {
    @EnvironmentObject private var app: AppModel
    let sourceID: UUID
    let entry: Entry
    var includeCopy = false
    var body: some View {
        if [.user, .assistant].contains(entry.kind), let source = app.chatSource(sourceID) {
            HStack(spacing: 10) {
                if includeCopy {
                    CopyTextButton(text: entry.text, label: entry.kind == .assistant ? "Copy agent response" : "Copy message", compact: true)
                        .accessibilityIdentifier("copy-message-" + entry.id.uuidString)
                }
                Button { app.collaborationRoute = .annotate(source, entry) } label: { Label("Annotate", systemImage: "text.bubble") }
                Button { app.collaborationRoute = .fork(source, entry) } label: { Label("Fork from here", systemImage: "arrow.triangle.branch") }
                let count = app.collaboration.annotations.filter { $0.anchor.sourceID == sourceID && $0.anchor.entryID == entry.id && !$0.resolved }.count
                if count > 0 { Text("\(count) open").foregroundStyle(Surface.accent) }
                Spacer()
            }.font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(Surface.muted)
                .padding(.top, 2).accessibilityElement(children: .contain)
        }
    }
}
struct CollaborationSheet: View {
    @EnvironmentObject private var app: AppModel
    let route: CollaborationRoute
    var body: some View {
        Group {
            switch route {
            case .project(let workspace): ProjectContextEditor(workspace: workspace, value: app.projectContext(workspace))
            case .annotate(let source, let entry): AnnotationEditor(source: source, entry: entry)
            case .annotations(let source): AnnotationList(source: source)
            case .fork(let source, let entry): ForkEditor(source: source, entry: entry)
            case .compare(let id): ForkComparison(taskID: id)
            case .edit(let annotation): AnnotationCommentEditor(value: annotation)
            case .review(let comment): ReviewCommentEditor(value: comment)
            }
        }.padding(22).frame(minWidth: 650, idealWidth: 800, minHeight: 520, idealHeight: 650)
            .materialPanel(color: Surface.canvas)
    }
}
private struct ProjectContextEditor: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    let workspace: String
    @ViewState private var value: ProjectContext
    @ViewState private var decisions: String
    @ViewState private var error: String?
    @ViewState private var saving = false
    init(workspace: String, value: ProjectContext) {
        self.workspace = workspace; _value = State(initialValue: value); _decisions = State(initialValue: value.decisions.joined(separator: "\n"))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Project context").font(.title2.bold())
            Text("Shared across this project's chats, accounts, providers, and worktrees. Included with each new request.")
                .font(.callout).foregroundStyle(Surface.muted)
            Text(workspace).font(.caption).textSelection(.enabled)
            Text("Instructions").font(.headline)
            TextEditor(text: $value.instructions).font(.body).frame(minHeight: 100).accessibilityLabel("Project instructions")
            HStack {
                Text("Reference files").font(.headline); Spacer()
                Button("Add files…") {
                    let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
                    if panel.runModal() == .OK { for url in panel.urls where !value.references.contains(url.path) { value.references.append(url.path) } }
                }.buttonStyle(AppButtonStyle())
            }
            ScrollView {
                VStack(alignment: .leading) {
                    ForEach(value.references, id: \.self) { file in
                        HStack {
                            Label(file, systemImage: FileManager.default.fileExists(atPath: file) ? "doc" : "exclamationmark.triangle").font(.caption).textSelection(.enabled)
                            Spacer(); Button("Remove") { value.references.removeAll { $0 == file } }.buttonStyle(.plain)
                        }.padding(.vertical, 3)
                    }
                }
            }.frame(maxHeight: 100)
            Text("Recorded decisions · one per line").font(.headline)
            TextEditor(text: $decisions).frame(minHeight: 70).accessibilityLabel("Project decisions")
            if let error { Text(error).font(.caption).foregroundStyle(Surface.danger) }
            HStack {
                Text("Revision \(value.revision). File paths are shared; agents read their contents as needed.").font(.caption).foregroundStyle(Surface.muted)
                Spacer(); Button("Cancel") { dismiss() }.buttonStyle(AppButtonStyle())
                Button("Save context") {
                    saving = true
                    value.decisions = decisions.split(separator: "\n").map(String.init)
                    Task { do { try await app.saveContext(value); dismiss() } catch { self.error = error.localizedDescription }; saving = false }
                }.buttonStyle(AppButtonStyle(kind: .primary)).disabled(saving)
            }
        }
    }
}

/// Display the original message verbatim while selecting an exact AppKit range.
private struct AnnotationSelection: NSViewRepresentable {
    let text: String
    @Binding var range: NSRange
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AnnotationSelection
        init(_ parent: AnnotationSelection) { self.parent = parent }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            let selected = view.selectedRange()
            guard selected != parent.range else { return }
            DispatchQueue.main.async { self.parent.range = selected }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let view = NSTextView()
        view.isEditable = false; view.isSelectable = true; view.isRichText = false
        view.font = .systemFont(ofSize: 13); view.textColor = .labelColor; view.backgroundColor = .textBackgroundColor
        view.textContainerInset = NSSize(width: 12, height: 12)
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = true
        view.delegate = context.coordinator; view.string = text
        view.setAccessibilityLabel("Select the message passage to annotate")
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) { context.coordinator.parent = self }
}
private struct AnnotationEditor: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    let source: ChatSource
    let entry: Entry
    @ViewState private var range = NSRange(location: 0, length: 0)
    @ViewState private var comment = ""
    @ViewState private var error: String?
    @ViewState private var saving = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Annotate message").font(.title2.bold())
            Text("Select the exact passage below, then add your feedback. The quotation stays attached to this message revision.").foregroundStyle(Surface.muted)
            AnnotationSelection(text: entry.text, range: $range).frame(minHeight: 220)
            Text("Selected: \(range.length) characters").font(.caption).foregroundStyle(Surface.muted)
            TextField("Your comment…", text: $comment, axis: .vertical).lineLimit(3...6).textFieldStyle(.roundedBorder).accessibilityLabel("Annotation comment")
            if let error { Text(error).foregroundStyle(Surface.danger) }
            HStack {
                Button("Cancel") { dismiss() }.buttonStyle(AppButtonStyle()); Spacer()
                Button("Save annotation") {
                    saving = true
                    Task {
                        do {
                            let anchor = try MessageAnchor(sourceID: source.id, entry: entry, range: range)
                            let value = ChatAnnotation(projectID: app.projectKey(source.workspace), anchor: anchor, comment: comment)
                            try await app.saveAnnotation(value); dismiss()
                        } catch { self.error = error.localizedDescription }
                        saving = false
                    }
                }.buttonStyle(AppButtonStyle(kind: .primary)).disabled(saving || range.length == 0 || comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}
private struct AnnotationList: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    let source: ChatSource
    @ViewState private var selected: Set<UUID> = []
    @ViewState private var error: String?
    @ViewState private var busy = false
    private var items: [ChatAnnotation] { app.collaboration.annotations.filter { $0.anchor.sourceID == source.id }.sorted { $0.createdAt < $1.createdAt } }
    private var chosen: [ChatAnnotation] { items.filter { selected.contains($0.id) && !$0.resolved } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Chat annotations").font(.title2.bold()); Spacer(); Button("Done") { dismiss() }.buttonStyle(AppButtonStyle()) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if items.isEmpty { Text("Use Annotate beneath any message to select a passage and leave feedback.").foregroundStyle(Surface.muted).padding(20) }
                    ForEach(items) { value in
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle(isOn: Binding(get: { selected.contains(value.id) }, set: { if $0 { selected.insert(value.id) } else { selected.remove(value.id) } })) {
                                Text(value.resolved ? "Resolved" : "Open comment").font(.headline)
                            }.toggleStyle(MicroCheckStyle()).disabled(value.resolved)
                            Text(value.anchor.quote).font(.callout).textSelection(.enabled).padding(10).background(Surface.selected, in: RoundedRectangle(cornerRadius: 8))
                            Text(value.comment).textSelection(.enabled)
                            if let entry = app.chatSource(source.id)?.entries.first(where: { $0.id == value.anchor.entryID }), !value.anchor.matches(entry) {
                                Label("Source message changed; this quotation is preserved from its original revision.", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Surface.warning)
                            }
                            HStack {
                                Button(value.resolved ? "Reopen" : "Resolve") { mutate { var copy = value; copy.resolved.toggle(); try await app.saveAnnotation(copy) } }
                                Button("Edit") { app.collaborationRoute = .edit(value) }
                                Button("Remember for project") { mutate { try await app.rememberAnnotation(value) } }
                                if let id = value.taskID { Button("Open task") { dismiss(); app.openAgent(id) } }
                            }.buttonStyle(AppButtonStyle(compact: true))
                        }.padding(14).materialPanel(radius: 12)
                    }
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(Surface.danger) }
            HStack {
                Text("\(chosen.count) selected").font(.caption); Spacer()
                Button("Add feedback to composer") { app.prepareFeedback(chosen, source: source) }.buttonStyle(AppButtonStyle()).disabled(chosen.isEmpty)
                Button("Run selected in parallel") { mutate { try await app.runAnnotations(chosen.filter { $0.taskID == nil }, source: source) } }
                    .buttonStyle(AppButtonStyle(kind: .primary)).disabled(busy || chosen.filter { $0.taskID == nil }.isEmpty)
            }
        }.task { await app.refreshCollaboration(); selected = Set(items.filter { !$0.resolved }.map(\.id)) }
    }
    private func mutate(_ action: @escaping @MainActor () async throws -> Void) {
        busy = true; Task { do { try await action() } catch { self.error = error.localizedDescription }; busy = false }
    }
}
private struct AnnotationCommentEditor: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @ViewState var value: ChatAnnotation
    @ViewState private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit annotation").font(.title2.bold()); Text(value.anchor.quote).textSelection(.enabled)
            TextEditor(text: $value.comment).accessibilityLabel("Annotation comment")
            if let error { Text(error).foregroundStyle(Surface.danger) }
            HStack { Button("Cancel") { dismiss() }; Spacer(); Button("Save") { Task { do { try await app.saveAnnotation(value); dismiss() } catch { self.error = error.localizedDescription } } }.disabled(value.comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }.buttonStyle(AppButtonStyle())
        }
    }
}
private struct ForkEditor: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    let source: ChatSource
    let entry: Entry
    @ViewState private var provider: Provider
    @ViewState private var account = ""
    @ViewState private var model = ""
    @ViewState private var request = ""
    @ViewState private var operationID = UUID().uuidString
    @ViewState private var isolated = true
    @ViewState private var busy = false
    @ViewState private var error: String?
    init(source: ChatSource, entry: Entry) { self.source = source; self.entry = entry; _provider = State(initialValue: source.provider); _account = State(initialValue: source.accountID?.uuidString ?? ""); _model = State(initialValue: source.model ?? "") }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Fork from this message").font(.title2.bold())
            Text("The original chat stays intact. The fork receives history through this message only and starts a fresh provider session.").foregroundStyle(Surface.muted)
            ScrollView { Text(entry.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 130)
            Picker("Provider", selection: $provider) { ForEach(app.availability.filter(\.isReady)) { available in Text(available.provider.title).tag(available.provider) } }
            Picker("Account", selection: $account) {
                Text("Current provider login").tag("")
                ForEach(app.accounts.filter { $0.provider == provider }) { value in Text(value.label).tag(value.id.uuidString) }
            }
            ModelPicker(provider: provider, model: $model, accountID: UUID(uuidString: account), workspace: source.workspace)
            Toggle("Create an isolated worktree", isOn: $isolated)
            Text("Files start from the workspace's current state, not its state when this message was written. A shared workspace waits for other Shastra writers.").font(.caption).foregroundStyle(Surface.muted)
            TextField("What should this fork explore?", text: $request, axis: .vertical).lineLimit(3...7).textFieldStyle(.roundedBorder)
            if let error { Text(error).foregroundStyle(Surface.danger) }
            HStack { Button("Cancel") { dismiss() }.buttonStyle(AppButtonStyle()); Spacer(); Button("Fork and start") {
                busy = true
                Task { do { try await app.fork(source: source, entry: entry, provider: provider, accountID: UUID(uuidString: account), model: model, request: request, isolated: isolated, operationID: operationID) } catch { self.error = error.localizedDescription }; busy = false }
            }.buttonStyle(AppButtonStyle(kind: .primary)).disabled(busy || request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || app.availability.first(where: { $0.provider == provider })?.isReady != true) }
        }.onChange(of: provider) { _, _ in account = ""; model = "" }
    }
}
private struct ForkComparison: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    let taskID: UUID
    var body: some View {
        if let task = app.agentBoard.snapshot?.tasks.first(where: { $0.id == taskID }), let origin = task.forkOrigin {
            VStack(alignment: .leading, spacing: 14) {
                HStack { Text("Compare fork").font(.title2.bold()); Spacer(); Button("Done") { dismiss() }.buttonStyle(AppButtonStyle()) }
                HSplitView {
                    column("Original · \(origin.sourceTitle)", entries: originalEntries(origin, task: task))
                    column("Fork · \(task.provider.title)", entries: Array(task.entries.dropFirst(origin.inheritedCount)))
                }
                HStack { Text("Bringing a result back fills the original composer's draft. It sends nothing automatically.").font(.caption).foregroundStyle(Surface.muted); Spacer(); Button("Bring result back") { app.bringBack(task) }.buttonStyle(AppButtonStyle(kind: .primary)).disabled(task.result == nil && !task.entries.dropFirst(origin.inheritedCount).contains { $0.kind == .assistant }) }
            }
        } else { Text("This fork is unavailable.") }
    }
    private func originalEntries(_ origin: ForkOrigin, task: AgentTask) -> [Entry] {
        guard let source = app.chatSource(origin.sourceID), let boundary = source.entries.firstIndex(where: { $0.id == origin.entryID }) else {
            return Array(task.entries.prefix(origin.inheritedCount))
        }
        return Array(source.entries[boundary...])
    }
    private func column(_ title: String, entries: [Entry]) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.headline)
            ScrollView { LazyVStack(alignment: .leading, spacing: 16) { ForEach(entries) { entry in VStack(alignment: .leading, spacing: 4) { Text(entry.kind.rawValue.capitalized).font(.caption).foregroundStyle(Surface.muted); Text(entry.text).textSelection(.enabled) } } } }
        }.padding(12).frame(minWidth: 280, maxWidth: .infinity)
    }
}
private struct ReviewCommentEditor: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @ViewState var value: ReviewComment
    @ViewState private var error: String?
    @ViewState private var busy = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Review comment").font(.title2.bold()); Text("\(value.path):\(value.line)").font(.headline)
            Text("Anchored to review revision \(value.revisionID)").font(.caption).textSelection(.enabled)
            ScrollView { Text(value.quote).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(minHeight: 170)
            TextField("What should change?", text: $value.comment, axis: .vertical).lineLimit(3...7).textFieldStyle(.roundedBorder)
            if let error { Text(error).foregroundStyle(Surface.danger) }
            HStack {
                Button("Cancel") { dismiss() }.buttonStyle(AppButtonStyle()); Spacer()
                Button("Save comment") { save(send: false) }.buttonStyle(AppButtonStyle()).disabled(busy || value.comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Add feedback to agent") { save(send: true) }.buttonStyle(AppButtonStyle(kind: .primary)).disabled(busy || value.comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
    private func save(send: Bool) {
        busy = true; Task { do { try await app.saveReview(value); if send { app.prepareReviewFeedback(value) } else { dismiss() } } catch { self.error = error.localizedDescription }; busy = false }
    }
}

struct MultitaskControls: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var board: AgentBoardModel
    let task: AgentTask
    private var children: [AgentTask] { (board.snapshot?.tasks ?? []).filter { $0.parentID == task.id && !$0.archived } }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("Multitask", isOn: Binding(get: { task.multitasking == true }, set: { enabled in
                    board.perform("task.multitask", params: ["taskID": task.id.uuidString, "enabled": String(enabled)])
                })).toggleStyle(MicroSwitchStyle()).controlSize(.small).disabled(board.busy)
                Text("\(children.filter { $0.status.isActive }.count) working · \(children.filter { $0.status == .queued }.count) waiting")
                    .font(.caption).foregroundStyle(Surface.muted)
                Spacer()
            }
            if task.multitasking == true {
                Text("Independent requests run as focused workers and report back here. Existing queued requests are delegated when this is enabled. Parallel edits use isolated worktrees.")
                    .font(.caption).foregroundStyle(Surface.muted)
            }
            if !children.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(children) { child in
                            Button { app.openAgent(child.id) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Label(child.title, systemImage: child.status.symbol).lineLimit(1)
                                    Text("\(child.provider.title) · \(child.status.displayName)").font(.system(size: 10)).foregroundStyle(Surface.muted)
                                }.frame(maxWidth: 180, alignment: .leading)
                            }.buttonStyle(AppButtonStyle(compact: true))
                        }
                    }
                }
            }
            if let parentID = task.parentID { Button("Back to main chat") { app.openAgent(parentID) }.font(.caption).buttonStyle(.plain) }
        }.padding(.horizontal, 16).padding(.vertical, 8)
    }
}
