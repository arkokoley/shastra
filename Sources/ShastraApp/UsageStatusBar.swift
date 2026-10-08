import SwiftUI
import ShastraCore

private struct UsageContext: Equatable {
    let provider: Provider
    let accountID: UUID?
    let profile: String?
}

@MainActor private final class UsageStatusModel: ObservableObject {
    @Published var limits: AccountUsageLimits?
    @Published var loading = false
    @Published var error: String?
    @Published var updatedAt: Date?
    @Published var expanded = false
    private var context: UsageContext?
    private var generation = UUID()

    func refresh(_ next: UsageContext, store: AccountStore) async {
        if context != next {
            limits = nil; error = nil; updatedAt = nil
            context = next
        }
        let request = UUID(); generation = request
        guard next.provider == .codex else {
            loading = false
            error = "\(next.provider.title) account limits are not available through this integration."
            return
        }
        loading = true
        do {
            let configuration: AccountLaunchConfiguration?
            if let id = next.accountID { configuration = try await store.configuration(for: id, provider: next.provider) }
            else { configuration = nil }
            let result = try await UsageLimitReader.readCodex(profileDirectory: next.profile, configuration: configuration)
            guard generation == request, !Task.isCancelled else { return }
            limits = result; updatedAt = .now; error = nil; loading = false
        } catch {
            guard generation == request, !Task.isCancelled else { return }
            self.error = "Could not refresh limits: \(error.localizedDescription)"
            loading = false
        }
    }
}

struct UsageStatusBar: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var board: AgentBoardModel
    @StateObject private var usage = UsageStatusModel()
    private var context: UsageContext {
        if app.showNewConversation { return .init(provider: app.selectedProvider, accountID: app.newAccountID, profile: nil) }
        if app.showAgents, let task = board.selected { return .init(provider: task.provider, accountID: task.accountID, profile: nil) }
        if let chat = app.selected { return .init(provider: chat.provider, accountID: chat.accountID, profile: chat.profileDirectory) }
        return .init(provider: app.selectedProvider, accountID: app.preferredAccount(for: app.selectedProvider), profile: nil)
    }
    private var accountLabel: String {
        if let id = context.accountID { return app.accounts.first { $0.id == id }?.label ?? "Account unavailable" }
        return context.profile == nil ? "Current provider login" : "Custom profile"
    }
    private var windows: [UsageWindow] { usage.limits?.buckets.first?.windows ?? [] }
    var body: some View {
        HStack(spacing: 12) {
            Button { app.showNewConversation = false; app.showAgents = true } label: {
                HStack(spacing: 6) {
                    Circle().fill(board.connected ? Surface.accent : Surface.warning).frame(width: 5, height: 5)
                    Text(board.connected ? "Agents ready" : "Agents offline")
                }
            }.buttonStyle(.plain).foregroundStyle(Surface.muted).help("Open Agents workspace")
            Spacer(minLength: 0)
            Button { usage.expanded.toggle() } label: {
                HStack(spacing: 12) {
                    Label(context.provider.title, systemImage: "gauge.with.dots.needle.50percent")
                    if windows.isEmpty {
                        Text(usage.loading ? "Loading limits…" : "Limits unavailable").foregroundStyle(Surface.muted)
                    } else {
                        ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
                            HStack(spacing: 5) {
                                Text("\(window.label) · \(window.remainingPercent)% left")
                                ProgressView(value: Double(window.remainingPercent), total: 100)
                                    .progressViewStyle(.linear).frame(width: 44)
                                    .tint(window.remainingPercent <= 10 ? .orange : Surface.accent)
                            }
                        }
                        if usage.error != nil { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }
                    }
                    Image(systemName: "chevron.up").font(.system(size: 8))
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).help("Account usage · \(accountLabel)")
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("\(context.provider.title) usage limits")
                .accessibilityValue(windows.isEmpty ? (usage.loading ? "Loading limits" : "Limits unavailable") : windows.map { "\($0.label) \($0.remainingPercent)% remaining" }.joined(separator: ", "))
                .popover(isPresented: $usage.expanded, arrowEdge: .top) { details }
        }.font(.system(size: 11)).padding(.horizontal, 14).frame(height: 30)
            .background(Surface.sidebar).overlay(alignment: .top) { Surface.stroke.opacity(0.7).frame(height: 1) }
            .task(id: context) {
                while !Task.isCancelled {
                    await usage.refresh(context, store: app.accountStore)
                    do { try await Task.sleep(for: .seconds(60)) } catch { break }
                }
            }
    }
    private var details: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("\(context.provider.title) usage limits").font(.headline)
                Spacer()
                Button { Task { await usage.refresh(context, store: app.accountStore) } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(usage.loading).help("Refresh limits")
            }
            Text(accountLabel).font(.caption).foregroundStyle(.secondary)
            if let limits = usage.limits {
                ForEach(Array(limits.buckets.enumerated()), id: \.offset) { _, bucket in
                    if limits.buckets.count > 1 { Text(bucket.limitName ?? bucket.limitId ?? "Usage").font(.subheadline.bold()) }
                    ForEach(Array(bucket.windows.enumerated()), id: \.offset) { _, window in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack { Text(window.label); Spacer(); Text("\(window.remainingPercent)% remaining") }
                            ProgressView(value: Double(window.remainingPercent), total: 100)
                            if let reset = window.resetsAt {
                                Text("Resets \(Date(timeIntervalSince1970: reset).formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if limits.buckets.allSatisfy({ $0.windows.isEmpty }) {
                    Text("This account did not report usage windows.").foregroundStyle(.secondary)
                }
            }
            if let error = usage.error { Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            if usage.loading { ProgressView().controlSize(.small) }
            if let updatedAt = usage.updatedAt {
                Text("\(usage.error == nil ? "Updated" : "Last successful update") \(updatedAt.formatted(date: .omitted, time: .shortened)) · Refreshes every minute")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Text("Shared across this provider account, including other chats and apps.").font(.caption).foregroundStyle(.secondary)
        }.padding(18).frame(width: 340)
    }
}
