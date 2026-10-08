import AppKit
import ShastraCore
import SwiftUI

@MainActor private final class AccountEditingState: ObservableObject {
    @Published var renaming: AgentAccount?
    @Published var renameText = ""
    @Published var removing: AgentAccount?
}

struct AccountsView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var editing = AccountEditingState()
    private var accounts: [AgentAccount] { model.accounts.filter { $0.provider == model.accountProvider } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle").font(.system(size: 25, weight: .light)).foregroundStyle(Surface.accent)
                    .frame(width: 48, height: 48).background(Surface.selected, in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 5) {
                    Text("Accounts").font(.system(size: 23, weight: .semibold))
                    Text("Keep work and personal ready. Choose an account in each chat.")
                        .font(.system(size: 12)).foregroundStyle(Surface.muted)
                }
                Spacer()
                Button { model.showAccounts = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).help("Close accounts").accessibilityLabel("Close accounts")
            }.padding(24)
            Picker("Agent", selection: $model.accountProvider) {
                ForEach(AccountStore.providers) { provider in Text(provider.title).tag(provider) }
            }.pickerStyle(.segmented).padding(.horizontal, 24).padding(.bottom, 18)
                .disabled(model.isAccountBusy)
            Surface.stroke.frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    defaultLoginRow
                    if accounts.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "person.badge.plus").font(.system(size: 26, weight: .light))
                            Text("Add your first \(model.accountProvider.title) account")
                                .font(.system(size: 14, weight: .medium))
                            Text("Sign in below, or save the account already signed in on this Mac.")
                                .font(.system(size: 12)).multilineTextAlignment(.center).foregroundStyle(Surface.muted)
                        }.frame(maxWidth: .infinity).padding(.vertical, 35).foregroundStyle(Surface.muted)
                    } else {
                        ForEach(accounts) { account in accountRow(account) }
                    }
                }.padding(20)
            }.frame(maxHeight: .infinity)
            Surface.stroke.frame(height: 1)
            VStack(alignment: .leading, spacing: 13) {
                if let error = model.accountError {
                    Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                } else if let status = model.accountStatus {
                    Label(status, systemImage: "checkmark.circle").font(.system(size: 12)).foregroundStyle(Surface.accent)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if model.isSigningIn {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Finish signing in in your browser").font(.system(size: 13, weight: .medium))
                            Text("Choose the account you want to add. Your other sign-ins stay available.")
                                .font(.system(size: 11)).foregroundStyle(Surface.muted)
                        }
                        Spacer()
                        Button("Cancel") { model.cancelAccountSignIn() }.buttonStyle(AppButtonStyle())
                    }.padding(.vertical, 8)
                } else {
                    HStack(spacing: 10) {
                        Image(systemName: "person").foregroundStyle(Surface.muted)
                        TextField("Account name, e.g. Work", text: $model.accountName)
                            .textFieldStyle(.plain).font(.system(size: 13)).accessibilityLabel("Account name")
                    }.padding(12).background(Surface.raised, in: RoundedRectangle(cornerRadius: 9))
                        .disabled(model.isAccountBusy)
                    HStack(spacing: 10) {
                        Button { model.signInAccount() } label: { Label("Sign in", systemImage: "plus") }
                            .buttonStyle(AppButtonStyle(kind: .primary))
                            .disabled(model.isAccountBusy || model.availability.first { $0.provider == model.accountProvider }?.isReady != true)
                        Button("Save current sign-in") { model.saveCurrentAccount() }.buttonStyle(AppButtonStyle())
                            .disabled(model.isAccountBusy)
                        Menu {
                            Button("Import auth file…") { importFile() }
                            Button("Import saved accounts") { model.importSavedAccounts() }
                        } label: { Label("Import", systemImage: "square.and.arrow.down") }
                            .menuStyle(.borderlessButton).fixedSize().disabled(model.isAccountBusy)
                        Spacer()
                        if model.isAccountBusy { ProgressView().controlSize(.small) }
                    }.font(.system(size: 12))
                    Text("Credentials stay on this Mac. Saved accounts are separate from the vendor app's current sign-in.")
                        .font(.system(size: 10)).foregroundStyle(Surface.muted)
                }
            }.padding(24)
        }.frame(width: 650, height: 600).background(Surface.canvas)
        .interactiveDismissDisabled(model.isAccountBusy)
        .onChange(of: model.accountProvider) { _, _ in model.accountError = nil; model.accountStatus = nil }
        .sheet(isPresented: Binding(get: { editing.renaming != nil }, set: { if !$0 { editing.renaming = nil } })) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Rename account").font(.system(size: 18, weight: .semibold))
                TextField("Account name", text: $editing.renameText).textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("Cancel") { editing.renaming = nil }
                    Button("Save") {
                        if let account = editing.renaming { model.renameAccount(account, label: editing.renameText) }
                        editing.renaming = nil
                    }.keyboardShortcut(.defaultAction).disabled(editing.renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(24).frame(width: 350)
        }
        .confirmationDialog("Remove this saved account from Shastra?", isPresented: Binding(
            get: { editing.removing != nil }, set: { if !$0 { editing.removing = nil } })) {
                Button("Remove account", role: .destructive) {
                    if let account = editing.removing { model.removeAccount(account) }
                    editing.removing = nil
                }
            } message: { Text("The vendor app's sign-in is unaffected.") }
    }

    private var defaultLoginRow: some View {
        let isDefault = model.preferredAccount(for: model.accountProvider) == nil
        return HStack(spacing: 12) {
            Image(systemName: "laptopcomputer").font(.system(size: 16)).frame(width: 32, height: 32)
                .foregroundStyle(Surface.muted)
            VStack(alignment: .leading, spacing: 4) {
                Text("Current vendor sign-in").font(.system(size: 13, weight: .medium))
                Text("Follows \(model.accountProvider.title)'s login on this Mac")
                    .font(.system(size: 11)).foregroundStyle(Surface.muted)
            }
            Spacer()
            if isDefault { Text("Default").font(.system(size: 10, weight: .medium)).foregroundStyle(Surface.muted) }
            else { Button("Use by default") { model.useAccountByDefault(nil) }.buttonStyle(.borderless).font(.system(size: 11)) }
        }.padding(16).background(Surface.raised, in: RoundedRectangle(cornerRadius: Design.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Design.cardRadius).stroke(isDefault ? Surface.accent.opacity(0.4) : Surface.stroke))
            .disabled(model.isAccountBusy)
    }

    private func accountRow(_ account: AgentAccount) -> some View {
        let isDefault = model.preferredAccount(for: account.provider) == account.id
        return HStack(spacing: 12) {
            Text(String(account.label.prefix(1)).uppercased()).font(.system(size: 15, weight: .medium))
                .frame(width: 34, height: 34).background(Surface.selected, in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(account.label).font(.system(size: 13, weight: .medium)).lineLimit(1)
                HStack(spacing: 6) {
                    if let email = account.email { Text(email).lineLimit(1) }
                    if let plan = account.plan { Text(plan.capitalized) }
                    if account.email == nil && account.plan == nil { Text(account.source) }
                }.font(.system(size: 11)).foregroundStyle(Surface.muted)
            }
            Spacer()
            if isDefault { Label("Default", systemImage: "checkmark").font(.system(size: 10)).foregroundStyle(Surface.muted) }
            else { Button("Use by default") { model.useAccountByDefault(account) }.buttonStyle(.borderless).font(.system(size: 11)) }
            Menu {
                Button("Rename…") { editing.renameText = account.label; editing.renaming = account }
                Button("Remove…", role: .destructive) { editing.removing = account }
            } label: { Image(systemName: "ellipsis").frame(width: 22, height: 24) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Options for \(account.label)")
        }.padding(16).background(Surface.raised, in: RoundedRectangle(cornerRadius: Design.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Design.cardRadius).stroke(isDefault ? Surface.accent.opacity(0.4) : Surface.stroke))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(isDefault ? Surface.muted.opacity(0.5) : Surface.stroke))
            .disabled(model.isAccountBusy)
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.title = "Import \(model.accountProvider.title) account"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the account's auth.json or saved authentication JSON file."
        if panel.runModal() == .OK, let file = panel.url { model.importAccountFile(file) }
    }
}

struct ConversationAccountMenu: View {
    @EnvironmentObject private var model: AppModel
    let conversation: Conversation
    var body: some View {
        Menu {
            Button { model.setAccount(nil, for: conversation.id) } label: {
                if conversation.accountID == nil { Label("Current sign-in", systemImage: "checkmark") }
                else { Text("Current sign-in") }
            }
            ForEach(model.accounts.filter { $0.provider == conversation.provider }) { account in
                Button { model.setAccount(account.id, for: conversation.id) } label: {
                    if conversation.accountID == account.id { Label(account.label, systemImage: "checkmark") }
                    else { Text(account.label) }
                }
            }
            Divider()
            Button("Manage accounts…") { model.accountProvider = conversation.provider; model.showAccounts = true }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "person.crop.circle")
                Text(model.accountLabel(for: conversation)).lineLimit(1).truncationMode(.middle).frame(maxWidth: 110)
            }.font(.system(size: 11))
        }.menuStyle(.borderlessButton).fixedSize().help("Choose account")
            .disabled([.running, .connecting, .waitingForApproval].contains(conversation.state))
            .accessibilityLabel("Account: \(model.accountLabel(for: conversation))")
    }
}
