import AppKit
import SwiftUI
import ShastraCore

struct ConversationRunStatus: View {
    @EnvironmentObject private var app: AppModel
    let conversation: Conversation
    private var active: Bool { [.running, .connecting, .waitingForApproval].contains(conversation.state) }
    private var label: String {
        switch conversation.state {
        case .idle: "Ready"
        case .connecting: "Connecting"
        case .running: "Working"
        case .waitingForApproval: "Needs you"
        case .completed: "Finished"
        case .interrupted: "Stopped"
        case .failed: "Failed"
        }
    }
    private var phase: MicroStatusMark.Phase {
        switch conversation.state {
        case .idle: .idle
        case .connecting, .running: .running
        case .waitingForApproval: .attention
        case .completed: .done
        case .interrupted: .stopped
        case .failed: .failed
        }
    }
    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                MicroStatusMark(phase: phase, size: 12)
                Text(label)
            }.font(.system(size: 10, weight: .semibold))
                .foregroundStyle(conversation.state == .failed ? Surface.warning : Surface.accent)
                .padding(.horizontal, 8).padding(.vertical, 5).background(Surface.accent.opacity(0.10), in: Capsule())
            if conversation.state == .running, let start = conversation.entries.last(where: { $0.kind == .user })?.createdAt {
                MicroActivityClock(startedAt: start)
            }
            Text("\(conversation.provider.title) · \(conversation.selectedModel ?? "Default model") · Runs while Shastra is open")
                .font(.system(size: 10)).foregroundStyle(Surface.muted).lineLimit(1)
            Spacer()
            if app.jumpToEntryID != nil { Button("Clear search highlight") { app.jumpToEntryID = nil }.buttonStyle(.plain) }
            if [.failed, .interrupted].contains(conversation.state) {
                Button("Prepare follow-up") { app.prepareRecovery(conversation) }.buttonStyle(AppButtonStyle())
            }
            if !active && conversation.historyLoaded != false && conversation.nativeResumeUnavailableReason == nil {
                Button("Continue in background") { app.continueInBackground(conversation) }.buttonStyle(AppButtonStyle(kind: .quiet))
            }
        }.padding(.horizontal, 16).padding(.vertical, 6)
    }
}

struct CompletionReview: View {
    let entries: [Entry]
    let result: String?
    let review: () -> Void
    private var currentTurn: [Entry] {
        guard let last = entries.lastIndex(where: { $0.kind == .user }) else { return entries }
        return Array(entries[last...])
    }
    private var checks: [Entry] {
        currentTurn.filter { $0.kind == .tool && ["test", "build", "lint", "check", "exit code"].contains(where: $0.text.lowercased().contains) }.suffix(4)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Ready to review", systemImage: "checkmark.circle").font(.headline).foregroundStyle(Surface.accent)
            Text(String((result ?? currentTurn.last(where: { $0.kind == .assistant })?.text ?? "The agent finished this turn.").prefix(800)))
                .font(.system(size: 12)).textSelection(.enabled).lineLimit(8)
            if checks.isEmpty {
                Text("No check output recorded for this turn.").font(.caption).foregroundStyle(Surface.muted)
            } else {
                DisclosureGroup("Recorded check activity (\(checks.count))") {
                    ForEach(checks) { entry in Text(entry.text).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).lineLimit(12) }
                }.font(.caption)
            }
            HStack {
                Button("Review changed files & diffs", action: review).buttonStyle(AppButtonStyle(kind: .primary))
                Text("Workspace changes may include other work.").font(.caption2).foregroundStyle(Surface.muted)
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Surface.raised, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Surface.stroke))
    }
}
