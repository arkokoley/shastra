import AppKit
import SwiftUI
import ShastraCore

extension AppModel {
    func organize(_ id: UUID, _ update: (inout ChatOrganization) -> Void) {
        var item = experience.organization(id); update(&item); experience.chats[id.uuidString] = item
    }
    func archiveChat(_ id: UUID) {
        if let task = agentBoard.snapshot?.tasks.first(where: { $0.id == id }) {
            let archived = task.archived || experience.organization(id).archived
            agentBoard.perform("task.archive", params: ["taskID": id.uuidString, "archived": String(!archived)]) { [weak self] in
                self?.organize(id) { $0.archived = false }
            }
        } else { organize(id) { $0.archived.toggle() } }
    }
    func title(_ id: UUID, fallback: String) -> String { experience.organization(id).title ?? fallback }
    func renameChat(_ id: UUID, current: String) {
        let alert = NSAlert(); alert.messageText = "Rename chat"
        let field = NSTextField(string: title(id, fallback: current)); field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field; alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }; organize(id) { $0.title = String(name.prefix(120)) }
    }
    func rememberProjectDefaults() {
        guard let workspace = workspaceIdentities[workingDirectory], workspace.isGit else { return }
        experience.projects[workspace.projectID] = .init(provider: selectedProvider, accountID: newAccountID, model: newModel, background: newChatUsesService)
        experience.projectWorkspaces[workspace.projectID] = workingDirectory
        let name = newModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty && !(experience.models[selectedProvider.rawValue] ?? []).contains(name) {
            experience.models[selectedProvider.rawValue, default: []].append(name)
        }
    }
    func restoreProjectDefaults(_ identity: WorkspaceIdentity) {
        guard let defaults = experience.projects[identity.projectID] else { return }
        selectedProvider = defaults.provider; newAccountID = defaults.accountID
        newModel = defaults.model; newChatUsesService = defaults.background
    }
    func addContextFiles(_ urls: [URL], key: String) {
        var files = experience.attachments[key] ?? []
        for url in urls where url.isFileURL && FileManager.default.fileExists(atPath: url.path) {
            if !files.contains(url.path) { files.append(url.path) }
        }
        experience.attachments[key] = files
    }
    func pasteContextImage(key: String) {
        guard let image = NSImage(pasteboard: .general), let data = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data), let png = bitmap.representation(using: .png, properties: [:]) else {
            notice = "Copy an image or screenshot first."; return
        }
        saveContextImage(png, key: key)
    }
    func saveContextImage(_ data: Data, key: String) {
        do {
            let root = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Shastra/Attachments")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let url = root.appending(path: "Screenshot-\(UUID()).png")
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            addContextFiles([url], key: key)
        } catch { notice = error.localizedDescription }
    }
    func openAgent(_ id: UUID) {
        showNewConversation = false; showAgents = true; agentBoard.selectedID = id
        agentBoard.filter = "All"; agentBoard.search = ""
        organize(id) { $0.unread = false }
    }
    func prepareRecovery(_ chat: Conversation) {
        guard !hasUnresolvedDelivery(chat) else { notice = "Check the originating runtime before retrying an uncertain delivery."; return }
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft = chat.state == .failed ? chat.entries.last(where: { $0.kind == .user })?.text ?? "Continue from where you stopped." : "Continue from where you stopped. Check the current state before making changes."
        }
    }
}

struct ChatOrganizationMenu: View {
    @EnvironmentObject private var app: AppModel
    let id: UUID
    let title: String
    var active = false
    var body: some View {
        let state = app.experience.organization(id)
        Button(state.pinned ? "Unpin" : "Pin") { app.organize(id) { $0.pinned.toggle() } }
        Button("Rename…") { app.renameChat(id, current: title) }
        Button(state.unread ? "Mark read" : "Mark unread") { app.organize(id) { $0.unread.toggle() } }
        Button(state.archived || app.agentBoard.snapshot?.tasks.first(where: { $0.id == id })?.archived == true ? "Unarchive" : "Archive") { app.archiveChat(id) }.disabled(active)
    }
}
