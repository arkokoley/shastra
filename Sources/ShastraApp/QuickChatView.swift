import AppKit
import SwiftUI
import ShastraCore

/// A draft has no runtime or conversation until the first message is sent.
struct QuickChatView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var board: AgentBoardModel
    @FocusState private var messageFocused: Bool

    private var canSend: Bool {
        !app.newChatMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && app.hasGitChatWorkspace && !app.verifyingNewChat && !board.busy && app.availability.first { $0.provider == app.selectedProvider }?.isReady == true
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("What will you build next?")
                        .font(.system(size: 24, weight: .semibold, design: .rounded)).tracking(-0.7)
                        .foregroundStyle(Surface.text)
                    Text("A fresh idea, a stubborn bug, or a better way to do things.")
                        .font(.system(size: 14)).foregroundStyle(Surface.muted)
                }.padding(.bottom, 4)
                VStack(alignment: .leading, spacing: 14) {
                    ComposerContextBar(key: "new", workspace: app.workingDirectory, draft: $app.newChatMessage)
                    VStack(alignment: .leading, spacing: 18) {
                        TextField("Describe what you have in mind…", text: $app.newChatMessage, axis: .vertical)
                            .textFieldStyle(.plain).font(.system(size: 15)).lineLimit(3...8)
                            .focused($messageFocused).accessibilityLabel("New chat message")
                    .modifier(ComposerImagePaste(key: "new"))
                            .onSubmit { if canSend { app.sendNewChat() } }
                        HStack(spacing: 12) {
                            Menu {
                                Button("Add file reference…") { addFile() }
                            } label: { Image(systemName: "plus").font(.system(size: 16)).frame(width: 28, height: 28) }
                                .menuIndicator(.hidden).fixedSize().help("Add a file to the conversation")
                            Menu {
                                ForEach(app.availability.filter(\.isReady)) { available in
                                    Button(available.provider.title) {
                                        app.selectedProvider = available.provider
                                        app.newModel = ""
                                        app.newAccountID = app.preferredAccount(for: available.provider)
                                    }
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "sparkle").foregroundStyle(Surface.accent)
                                    Text(app.selectedProvider.title).fontWeight(.medium)
                                }
                            }.fixedSize()
                            Menu {
                                Button("Current provider login") { app.newAccountID = nil }
                                ForEach(app.accounts.filter { $0.provider == app.selectedProvider }) { account in
                                    Button(account.label) { app.newAccountID = account.id }
                                }
                                Divider()
                                Button("Manage accounts…") { app.showAccounts = true }
                            } label: { Image(systemName: "person.crop.circle") }
                                .help(app.accounts.first { $0.id == app.newAccountID }?.label ?? "Current provider login").fixedSize()
                            Spacer()
                            if board.busy { ProgressView().controlSize(.small) }
                            Button { app.sendNewChat() } label: {
                                HStack(spacing: 8) { Text("Start chat"); Image(systemName: "arrow.up") }
                            }.buttonStyle(AppButtonStyle(kind: .primary)).disabled(!canSend)
                                .help("Send · Return").accessibilityLabel("Start chat")
                        }.menuStyle(.borderlessButton).font(.system(size: 12)).foregroundStyle(Surface.muted)
                    }.padding(20).composerSurface(focused: messageFocused)
                    HStack(spacing: 16) {
                        ModelPicker(provider: app.selectedProvider, model: $app.newModel, accountID: app.newAccountID, workspace: app.workingDirectory)
                            .font(.system(size: 12)).foregroundStyle(Surface.muted)
                        Spacer(minLength: 8)
                        Toggle("Keep working when the window closes", isOn: $app.newChatUsesService).font(.caption)
                    }
                    ComposerWorkspaceBar(path: app.workingDirectory, isNew: true, background: app.newChatUsesService)
                    HStack {
                        Label(app.newChatUsesService || app.newChatIsolated ? "Continues in the background" : "Local conversation",
                              systemImage: app.newChatUsesService || app.newChatIsolated ? "bolt.horizontal.circle" : "lock.shield")
                        Spacer()
                        Text("↵ Send · ⇧↵ New line")
                    }.font(.system(size: 10)).foregroundStyle(Surface.muted).padding(.horizontal, 8)
                }
                if app.newChatMessage.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("A PLACE TO START").font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(Surface.muted)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12, alignment: .top)], spacing: 12) {
                            starter("Build a feature", detail: "Turn an idea into working code", symbol: "square.stack.3d.up",
                                    prompt: "Help me build a feature in this project. Start by understanding the code, then help me define and implement the change: ")
                            starter("Fix a problem", detail: "Find the cause, verify the fix", symbol: "ladybug",
                                    prompt: "Help me debug a problem in this project. Trace the root cause and verify the fix. Here is what is happening: ")
                            starter("Explore the code", detail: "Get oriented in this project", symbol: "map",
                                    prompt: "Explore this project and explain its architecture, main entry points, and how to run it. Do not change files.")
                        }
                    }.padding(.top, 6)
                } else if app.workspaceIdentities[app.workingDirectory]?.isGit == true {
                    ComposerActions(draft: $app.newChatMessage)
                }
                if let error = board.error, app.newChatUsesService || app.newChatIsolated {
                    Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Surface.warning)
                        .textSelection(.enabled).padding(12).background(Surface.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }
                HStack { Spacer(); Button("Back to conversation") { app.showNewConversation = false }.buttonStyle(AppButtonStyle(kind: .quiet)) }
            }.frame(maxWidth: Design.readingWidth)
                .padding(Design.contentInset).frame(maxWidth: .infinity)
        }.scrollIndicators(.hidden)
            .onAppear { messageFocused = true }
    }

    private func starter(_ title: String, detail: String, symbol: String, prompt: String) -> some View {
        Button {
            app.newChatMessage = prompt
            messageFocused = true
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: symbol).font(.system(size: 18, weight: .medium)).foregroundStyle(Surface.accent)
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Surface.text)
                Text(detail).font(.system(size: 11)).foregroundStyle(Surface.muted).lineLimit(2)
            }.frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading).padding(16)
                .background(Surface.raised.opacity(0.8), in: RoundedRectangle(cornerRadius: Design.cardRadius))
                .overlay(RoundedRectangle(cornerRadius: Design.cardRadius).stroke(Surface.stroke.opacity(0.8)))
        }.buttonStyle(.plain).help("Add a starting prompt; edit it before sending")
    }
    private func addFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: app.workingDirectory)
        if panel.runModal() == .OK {
            app.addContextFiles(panel.urls, key: "new")
        }
    }

}
