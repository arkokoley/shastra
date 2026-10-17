import AppKit
import SwiftUI
import ShastraCore

@MainActor private final class GitReviewState: ObservableObject {
    @Published var snapshot: ChangeReviewSnapshot?
    @Published var scope = ReviewScope.working
    @Published var path: String?
    @Published var error: String?
    @Published var busy = false
    @Published var trace = false
    private var generation = UUID()
    func refresh(root: URL, base: String?) {
        let id = UUID(); generation = id
        let selectedScope = scope
        busy = true; error = nil
        Task {
            do {
                let result = try await Task.detached(priority: .utility) {
                    try ChangeReview.capture(workspace: root.path, scope: selectedScope, base: base)
                }.value
                guard generation == id else { return }
                snapshot = result
                if !result.files.contains(where: { $0.path == path }) { path = result.files.first?.path }
            } catch { if generation == id { self.error = error.localizedDescription; snapshot = nil } }
            if generation == id { busy = false }
        }
    }
    func apply(_ action: ChangeReview.HunkAction, file: ReviewFile, hunk: ReviewHunk, root: URL, base: String?) {
        guard let snapshot else { return }
        busy = true
        Task {
            do {
                try await Task.detached(priority: .utility) { try ChangeReview.apply(action, hunkID: hunk.id, file: file, snapshot: snapshot) }.value
                refresh(root: root, base: base)
            } catch { self.error = error.localizedDescription; busy = false }
        }
    }
}

struct GitChangesPane: View {
    @EnvironmentObject private var app: AppModel
    let root: URL
    let sourceID: UUID
    let onPreview: (URL) -> Void
    @StateObject private var state = GitReviewState()
    private var task: AgentTask? { app.agentBoard.snapshot?.tasks.first { $0.id == sourceID } }
    private var base: String? { task?.reviewBase }
    private var file: ReviewFile? { state.snapshot?.files.first { $0.path == state.path } }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Change review", systemImage: "square.stack.3d.up").font(.headline)
                Spacer()
                Button(state.trace ? "Show changes" : "Trace") { state.trace.toggle() }.buttonStyle(AppButtonStyle(compact: true))
                Button { state.refresh(root: root, base: base) } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(AppButtonStyle(compact: true)).disabled(state.busy).accessibilityLabel("Refresh changes").help("Refresh changes")
            }.padding(12)
            MicroSegment(label: "Review scope", selection: $state.scope, options:
                [.init(value: .working, title: "Unstaged"), .init(value: .staged, title: "Staged")]
                + (base == nil ? [] : [.init(value: .task, title: "Task changes")]))
                .padding(.horizontal, 12).padding(.bottom, 10)
            if let error = state.error {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Could not read changes", systemImage: "exclamationmark.triangle").font(.caption.bold()).foregroundStyle(Surface.danger)
                    Text(error).font(.caption).textSelection(.enabled)
                    Button("Retry reading changes") { state.refresh(root: root, base: base) }
                        .buttonStyle(AppButtonStyle(compact: true)).disabled(state.busy)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            if state.trace { trace }
            else if state.busy && state.snapshot == nil { ProgressView("Reading changes…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if let snapshot = state.snapshot {
                if snapshot.files.isEmpty { ContentUnavailableView("No changes in this scope", systemImage: "checkmark.circle", description: Text("Choose another scope or refresh after editing files.")).frame(maxHeight: .infinity) }
                else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(snapshot.files) { item in
                                Button { state.path = item.path } label: {
                                    HStack {
                                        Text(item.path).lineLimit(1)
                                        Spacer()
                                        Text("+\(item.hunks.reduce(0) { $0 + $1.added })").foregroundStyle(Surface.success)
                                        Text("−\(item.hunks.reduce(0) { $0 + $1.removed })").foregroundStyle(Surface.danger)
                                    }.font(.caption).padding(8).background(state.path == item.path ? Surface.selected : .clear, in: RoundedRectangle(cornerRadius: 7))
                                }.buttonStyle(.plain).help(item.path)
                            }
                        }.padding(6)
                    }.frame(maxHeight: 155)
                    Divider()
                    if let file {
                        HStack {
                            Text(file.path).font(.caption.weight(.semibold)).lineLimit(1)
                            Spacer()
                            Button("Preview") { onPreview(URL(fileURLWithPath: snapshot.workspace).appending(path: file.path)) }.buttonStyle(AppButtonStyle(compact: true))
                        }.padding(10)
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 16) {
                                if file.hunks.isEmpty { code(file.diff) }
                                ForEach(file.hunks) { hunk in
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(hunk.header).font(.system(.caption, design: .monospaced)).foregroundStyle(Surface.accent).textSelection(.enabled)
                                        code(hunk.text)
                                        HStack {
                                            Button("Comment / fix") { comment(file: file, hunk: hunk) }.buttonStyle(AppButtonStyle(compact: true))
                                            Spacer()
                                            if state.scope != .task && !file.isUntracked && !file.diff.contains("rename from ") {
                                                Button(state.scope == .staged ? "Unstage hunk" : "Stage hunk") {
                                                    state.apply(state.scope == .staged ? .unstage : .stage, file: file, hunk: hunk, root: root, base: base)
                                                }.buttonStyle(AppButtonStyle(compact: true)).disabled(state.busy)
                                                if state.scope == .working {
                                                    Button("Discard…") { discard(file, hunk: hunk) }.buttonStyle(AppButtonStyle(compact: true)).disabled(state.busy)
                                                }
                                            }
                                        }
                                    }.padding(10).materialPanel(radius: 9)
                                }
                                reviewComments(file)
                            }.padding(10)
                        }
                    }
                }
                Text(state.scope == .task ? "Compared with the task-start snapshot. Review actions are available under Unstaged and Staged." : "Workspace changes may include work from other tools. Actions apply only to the exact hunk shown.")
                    .font(.system(size: 10)).foregroundStyle(Surface.muted).padding(10)
            } else { Spacer() }
        }
        .task(id: sourceID) { state.scope = base == nil ? .working : .task; state.refresh(root: root, base: base); await app.refreshCollaboration() }
        .onChange(of: state.scope) { _, _ in state.refresh(root: root, base: base) }
        .onChange(of: root) { _, _ in state.refresh(root: root, base: base) }
    }
    private func code(_ text: String) -> some View {
        ScrollView(.horizontal) {
            Text(text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func comment(file: ReviewFile, hunk: ReviewHunk) {
        app.collaborationRoute = .review(ReviewComment(projectID: app.projectKey(root.path), sourceID: sourceID, revisionID: file.revisionID, path: file.path, line: max(1, hunk.line), quote: hunk.text, comment: ""))
    }
    private func discard(_ file: ReviewFile, hunk: ReviewHunk) {
        let alert = NSAlert(); alert.messageText = "Discard this hunk?"
        alert.informativeText = "This removes the selected unstaged change from \(file.path).\n\n" + hunk.text
        alert.alertStyle = .warning; alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Discard hunk")
        if alert.runModal() == .alertSecondButtonReturn { state.apply(.discard, file: file, hunk: hunk, root: root, base: base) }
    }
    private func reviewComments(_ file: ReviewFile) -> some View {
        ForEach(app.collaboration.reviews.filter { $0.sourceID == sourceID && $0.path == file.path }) { value in
            VStack(alignment: .leading, spacing: 7) {
                Label(value.resolved ? "Resolved comment" : "Review comment · line \(value.line)", systemImage: "text.bubble").font(.caption.bold())
                Text(value.comment).textSelection(.enabled)
                if value.revisionID != file.revisionID { Text("Diff has changed; comment preserves its original quotation.").font(.caption).foregroundStyle(Surface.warning) }
                HStack {
                    Button("View / edit") { app.collaborationRoute = .review(value) }
                    Button(value.resolved ? "Reopen" : "Resolve") {
                        Task { do { var copy = value; copy.resolved.toggle(); try await app.saveReview(copy) } catch { state.error = error.localizedDescription } }
                    }
                    Button("Add to composer") { app.prepareReviewFeedback(value) }
                }.buttonStyle(AppButtonStyle(compact: true))
            }.padding(10).materialPanel(radius: 9)
        }
    }
    private var trace: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Request → task → changes → evidence").font(.headline)
                if let task {
                    Text(task.objective).textSelection(.enabled)
                    if let parent = task.parentID { Button("Open parent chat") { app.openAgent(parent) }.buttonStyle(AppButtonStyle()) }
                    ForEach(app.collaboration.annotations.filter { task.annotationIDs?.contains($0.id) == true }) { annotation in
                        VStack(alignment: .leading) { Text(annotation.anchor.quote).font(.callout); Text(annotation.comment).font(.headline) }.padding(10).materialPanel(radius: 8)
                    }
                    Text("\(state.snapshot?.files.count ?? 0) changed files in the selected scope").font(.headline)
                    Text("Recorded execution evidence").font(.headline)
                    ForEach(task.entries.filter { $0.kind == .tool }) { entry in code(entry.text) }
                    if !task.entries.contains(where: { $0.kind == .tool }) { Text("No tool output recorded yet.").foregroundStyle(Surface.muted) }
                    if let result = task.result { Text(result).textSelection(.enabled) }
                } else {
                    Text("This chat has no task-start snapshot. Review the staged and unstaged workspace changes, and use message annotations to create linked tasks.").foregroundStyle(Surface.muted)
                }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
