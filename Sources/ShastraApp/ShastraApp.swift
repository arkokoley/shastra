import SwiftUI
import ShastraCore

@MainActor final class AppModel: ObservableObject {
    @Published var experience = ExperiencePreferences.read(UserDefaults.standard.data(forKey: "experience.v1")) {
        didSet { agentBoard.organization = experience.chats; if let data = try? JSONEncoder().encode(experience) { UserDefaults.standard.set(data, forKey: "experience.v1") } }
    }
    @Published var chatFilter = "All"
    @Published var newModel = ""
    @Published var showRuntimeLibrary = false
    @Published var jumpToEntryID: UUID?
    @Published var requestedTool: String?
    @Published var indexingStatus = ""
    @Published var indexingRevision = 0
    @Published var indexingPaused = false
    var indexingTask: Task<Void, Never>?

    @Published var conversations: [Conversation] = []
    @Published var workspaceIdentities: [String: WorkspaceIdentity] = [:]
    // Automatic scans must not trigger a macOS protected-folder access prompt.
    // Histories remain available; protected projects retain their folder grouping.
    private let workspaceCatalog = WorkspaceIdentityCatalog(excludedMetadataRoots:
        ["Documents", "Desktop", "Downloads"].map {
            FileManager.default.homeDirectoryForCurrentUser.appending(path: $0)
        })
    @Published var selectedID: UUID? {
        didSet {
            if let oldValue { drafts[oldValue] = draft }
            draft = selectedID.flatMap { id in drafts[id] ?? conversations.first(where: { $0.id == id })?.savedDraft } ?? ""
            UserDefaults.standard.set(selectedID?.uuidString, forKey: "selectedConversation")
        }
    }
    @Published var approvals: [PendingApproval] = []
    @Published var questions: [PendingQuestion] = []
    @Published var showPalette = false
    @Published var draft = "" {
        didSet {
            if let id = selectedID, let index = conversations.firstIndex(where: { $0.id == id }) {
                conversations[index].savedDraft = draft
                drafts[id] = draft
                scheduleSave()
            }
        }
    }
    @Published var unresolvedEndpointIDs: Set<UUID> = []
    @Published var indexedMatches: Set<UUID> = []
    private var searchTask: Task<Void, Never>?

    @Published var search = "" {
        didSet {
            searchTask?.cancel()
            indexedMatches = []
            let query = search
            searchTask = Task {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                do {
                    let results = try await store.search(query)
                    guard !Task.isCancelled, search == query else { return }
                    indexedMatches = Set(results.map(\.conversationID))
                } catch { notice = "History search failed: \(error.localizedDescription)" }
            }
        }
    }
    @Published var sourceFilter = "All"
    @Published var selectedProvider: Provider = .codex
    @Published var resolvingNewChatWorkspace = false
    @Published var verifyingNewChat = false
    private var workspaceSelectionTask: Task<Void, Never>?
    @Published var workingDirectory = FileManager.default.homeDirectoryForCurrentUser.path
    @Published var profileDirectory = ""
    @Published var showNewConversation = false
    @Published var newChatUsesService = true
    @Published var newChatIsolated = false
    @Published var newChatMessage = UserDefaults.standard.string(forKey: "newChatMessage") ?? "" {
        didSet { UserDefaults.standard.set(newChatMessage, forKey: "newChatMessage") }
    }
    @Published var showAccounts = false
    @Published var showAgents = UserDefaults.standard.bool(forKey: "showAgents") {
        didSet { UserDefaults.standard.set(showAgents, forKey: "showAgents") }
    }
    let agentBoard = AgentBoardModel()
    @Published var accounts: [AgentAccount] = []
    @Published var newAccountID: UUID?
    @Published var accountProvider: Provider = .codex
    @Published var accountName = ""
    @Published var accountError: String?
    @Published var accountStatus: String?
    @Published var isAccountBusy = false
    @Published var isSigningIn = false
    let accountStore = AccountStore()
    private var accountLogin: AccountLogin?
    private var accountTask: Task<Void, Never>?
    private var accountDefaults = UserDefaults.standard.dictionary(forKey: "accountDefaults") as? [String: String] ?? [:]
    @Published var isScanning = false
    @Published var loadingHistory = false
    @Published var loadingHistoryID: UUID?
    @Published var historyErrors: [UUID: String] = [:]
    @Published var catalogStatus = ""
    @Published var notice: String?

    let availability = ExecutableLocator.discover()
    private let store = ConversationStore()
    private var sessions: [UUID: AgentSession] = [:]
    private var sessionTokens: [UUID: UUID] = [:]
    private var promptTasks: [UUID: Task<Void, Never>] = [:]
    private var newAssistantMessages: Set<UUID> = []
    private var drafts: [UUID: String] = [:]
    private var sourceIndex: [String: DiscoveredSession] = [:]
    private var saveTask: Task<Void, Never>?

    var selected: Conversation? { conversations.first { $0.id == selectedID } }
    var filtered: [Conversation] {
        guard !search.isEmpty else { return conversations.sorted { $0.updatedAt > $1.updatedAt } }
        return conversations.filter {
            indexedMatches.contains($0.id) || title($0.id, fallback: $0.title).localizedCaseInsensitiveContains(search) ||
            $0.entries.contains { $0.text.localizedCaseInsensitiveContains(search) }
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    private var loaded = false
    func load() async {
        guard !loaded else { return }; loaded = true
        agentBoard.organization = experience.chats
        agentBoard.onActivity = { [weak self] id in
            guard let self, !showAgents || agentBoard.selectedID != id else { return }
            organize(id) { $0.unread = true }
        }
        agentBoard.start()
        await reloadAccounts()
        do {
            conversations = try await store.load()
            _ = try await store.recoverDispatches()
            unresolvedEndpointIDs = Set(try await store.unresolvedDeliveries().map(\.endpointID))
            if !unresolvedEndpointIDs.isEmpty { notice = "Some sends have unknown acceptance. Check the originating runtime before sending again; they will not be replayed." }
            Task { await refreshWorkspaceIdentities() }
            for index in conversations.indices {
                conversations[index].entries.removeAll {
                    $0.kind == .status && $0.text == "Imported read-only from Codex. Sending a message will create a linked continuation."
                }
            }
            for index in conversations.indices where [.running, .connecting, .waitingForApproval].contains(conversations[index].state) {
                conversations[index].state = .interrupted
                conversations[index].entries.append(.init(kind: .status, text: "Shastra restarted. The previous runtime needs reconciliation; pending sends will not be replayed."))
            }
            let savedID = UserDefaults.standard.string(forKey: "selectedConversation").flatMap(UUID.init(uuidString:))
            selectedID = conversations.first { $0.id == savedID }?.id ?? conversations.first?.id
            loadSelectedHistory()
        } catch { notice = "Could not load conversations: \(error.localizedDescription)" }
        refreshCatalog()
    }

    func beginNewChat(in workspace: String? = nil, background: Bool? = nil) {
        newChatIsolated = false
        newModel = ""
        newChatUsesService = background ?? true
        let remembered = workspace.flatMap { workspaceIdentities[$0]?.projectID }.flatMap { experience.projectWorkspaces[$0] }
        let candidates = workspace.map { [remembered, $0].compactMap { $0 } } ?? [
            UserDefaults.standard.string(forKey: "lastChatWorkspace"),
            showAgents ? agentBoard.selected?.workspace : selected?.workingDirectory,
            workingDirectory
        ].compactMap { $0 } + recentWorkspacePaths
        prepareNewChatWorkspace(candidates, reportInvalid: workspace != nil, background: background)
        selectedProvider = (showAgents ? agentBoard.selected?.provider : selected?.provider) ?? selectedProvider
        newAccountID = preferredAccount(for: selectedProvider)
        profileDirectory = ""
        showNewConversation = true
    }

    func selectNewChatWorkspace(_ path: String) {
        prepareNewChatWorkspace([path], reportInvalid: true)
    }

    private func prepareNewChatWorkspace(_ paths: [String], reportInvalid: Bool, background: Bool? = nil) {
        workspaceSelectionTask?.cancel()
        resolvingNewChatWorkspace = true
        workspaceSelectionTask = Task {
            let resolved = await workspaceCatalog.resolve(paths.filter { !$0.isEmpty })
            guard !Task.isCancelled else { return }
            workspaceIdentities.merge(resolved) { _, new in new }
            let location = paths.compactMap { resolved[$0] }.first { $0.isGit && $0.isAvailable }
            if let location {
                if location.workspacePath != workingDirectory { newChatIsolated = false }
                workingDirectory = location.workspacePath
                restoreProjectDefaults(location)
                if let background { newChatUsesService = background }
                workspaceIdentities[workingDirectory] = location
                UserDefaults.standard.set(workingDirectory, forKey: "lastChatWorkspace")
            } else {
                workingDirectory = ""
                newChatIsolated = false
                if reportInvalid { notice = "Choose an existing Git repository or worktree. This folder is not a Git workspace." }
            }
            resolvingNewChatWorkspace = false
        }
    }

    var hasGitChatWorkspace: Bool {
        !resolvingNewChatWorkspace && workspaceIdentities[workingDirectory]?.isGit == true
            && workspaceIdentities[workingDirectory]?.isAvailable == true
    }

    func resolveWorkspace(_ path: String) async {
        guard !path.isEmpty else { return }
        let resolved = await workspaceCatalog.resolve([path])
        workspaceIdentities.merge(resolved) { _, new in new }
    }

    func validatedGitWorkspace(_ path: String) async -> String? {
        guard !path.isEmpty else { return nil }
        let resolved = await workspaceCatalog.resolve([path])
        workspaceIdentities.merge(resolved) { _, new in new }
        guard let location = resolved[path], location.isGit, location.isAvailable else { return nil }
        workspaceIdentities[location.workspacePath] = location
        return location.workspacePath
    }

    private func refreshWorkspaceIdentities() async {
        let paths = conversations.map(\.workingDirectory) + (agentBoard.snapshot?.tasks.map(\.workspace) ?? [])
            + (agentBoard.snapshot?.workspaces.filter { !$0.archived }.map(\.path) ?? [])
            + [workingDirectory, UserDefaults.standard.string(forKey: "lastChatWorkspace") ?? ""]
        let resolved = await workspaceCatalog.resolve(paths.filter { !$0.isEmpty })
        workspaceIdentities.merge(resolved) { _, new in new }
    }

    func backgroundTask(for chat: Conversation) -> AgentTask? {
        agentBoard.snapshot?.tasks.first {
            $0.conversationID == chat.id || ($0.nativeID != nil && $0.nativeID == chat.resumeEndpoint?.nativeThreadID
                && $0.provider == chat.provider && $0.accountID == chat.accountID && $0.profileDirectory == chat.profileDirectory)
        }
    }

    func openConversation(_ id: UUID) {
        if let chat = conversations.first(where: { $0.id == id }), let task = backgroundTask(for: chat) { openAgent(task.id); return }
        showNewConversation = false
        showAgents = false
        organize(id) { $0.unread = false }
        selectedID = id
    }

    var recentWorkspacePaths: [String] {
        let paths = [workingDirectory] + (agentBoard.snapshot?.tasks.sorted { $0.updatedAt > $1.updatedAt }.map(\.workspace) ?? [])
            + conversations.sorted { $0.updatedAt > $1.updatedAt }.map(\.workingDirectory)
        var seen = Set<String>()
        let ordered = paths.compactMap { workspaceIdentities[$0] }
            + workspaceIdentities.values.sorted { $0.workspacePath.localizedStandardCompare($1.workspacePath) == .orderedAscending }
        return ordered.filter { $0.isGit && $0.isAvailable && seen.insert($0.workspacePath).inserted }
            .map(\.workspacePath)
    }

    func sendNewChat() {
        guard !verifyingNewChat, hasGitChatWorkspace else { return }
        let path = workingDirectory
        let message = newChatMessage
        verifyingNewChat = true
        Task {
            defer { verifyingNewChat = false }
            let root = await validatedGitWorkspace(path)
            guard workingDirectory == path, newChatMessage == message else { return }
            guard let root else {
                workingDirectory = ""
                notice = "This Git workspace is no longer available. Choose another repository or worktree."
                return
            }
            workingDirectory = root
            await finishNewChat()
        }
    }

    private func finishNewChat() async {
        let message = newChatMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workingDirectory, isDirectory: &isDirectory), isDirectory.boolValue else {
            notice = "Choose an existing workspace folder."; return
        }
        guard hasGitChatWorkspace else {
            notice = "Choose a Git repository or worktree before starting a chat."; return
        }
        UserDefaults.standard.set(workingDirectory, forKey: "lastChatWorkspace")
        rememberProjectDefaults()
        let messageWithFiles = ComposerContext.prompt(message, files: experience.attachments["new"] ?? [])
        if newChatUsesService || newChatIsolated {
            var params = ["objective": messageWithFiles, "title": String(message.prefix(60)), "provider": selectedProvider.rawValue,
                          "workspace": workingDirectory, "isolate": String(newChatIsolated)]
            if !newModel.isEmpty { params["model"] = newModel }
            if let newAccountID { params["accountID"] = newAccountID.uuidString }
            agentBoard.perform("agents.spawn", params: params, selectResult: true) { [weak self] in
                guard let self else { return }
                if newChatMessage.trimmingCharacters(in: .whitespacesAndNewlines) == message { newChatMessage = "" }
                experience.attachments["new"] = []
                showNewConversation = false
                showAgents = true
            }
        } else {
            createConversation()
            guard !showNewConversation else { return }
            showAgents = false
            draft = messageWithFiles
            experience.attachments["new"] = []
            newChatMessage = ""
            send()
        }
    }

    func createConversation() {
        guard hasGitChatWorkspace else {
            notice = "Choose a Git repository or worktree before starting a chat."; return
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workingDirectory, isDirectory: &isDirectory), isDirectory.boolValue else {
            notice = "Choose an existing working directory"; return
        }
        let profile = profileDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        var conversation = Conversation(provider: selectedProvider, workingDirectory: workingDirectory,
                                        profileDirectory: profile.isEmpty ? nil : profile)
        if let id = newAccountID, accounts.contains(where: { $0.id == id && $0.provider == selectedProvider }) {
            conversation.accountID = id
            conversation.profileDirectory = nil
        }
        conversation.selectedModel = newModel.isEmpty ? nil : newModel
        conversation.migrateEndpoints()
        conversations.insert(conversation, at: 0)
        selectedID = conversation.id
        showNewConversation = false
        scheduleSave()
        Task { await refreshWorkspaceIdentities() }
    }

    func refreshCatalog() {
        guard !isScanning else { return }
        isScanning = true
        Task {
            let found = await ConversationCatalog.discover()
            for index in conversations.indices { conversations[index].migrateEndpoints() }
            sourceIndex = [:]
            for source in found { sourceIndex[source.id] = source }
            var positions: [String: Int] = [:]
            for (index, conversation) in conversations.enumerated() {
                if let identity = conversation.sourceIdentity { positions[identity] = index }
            }
            var modified = false
            for source in found {
                if let index = positions[source.id] {
                    if conversations[index].managedContinuationEnabled != true, conversations[index].linkedWorkspaceConfirmed != true,
                       conversations[index].workingDirectory != source.workingDirectory {
                        conversations[index].workingDirectory = source.workingDirectory
                        modified = true
                    }
                    if source.updatedAt > (conversations[index].sourceEndpoint?.sourceUpdatedAt ?? .distantPast) {
                        if let endpointIndex = conversations[index].endpoints?.firstIndex(where: { $0.sourceIdentity == source.id }) {
                            conversations[index].endpoints?[endpointIndex].sourceUpdatedAt = source.updatedAt
                        }
                        if conversations[index].managedContinuationEnabled != true { conversations[index].title = source.title }
                        conversations[index].updatedAt = max(conversations[index].updatedAt, source.updatedAt)
                        conversations[index].historyLoaded = false
                        modified = true
                    }
                } else {
                    positions[source.id] = conversations.count
                    conversations.append(source.placeholder())
                    modified = true
                }
            }
            if selectedID == nil { selectedID = conversations.first?.id }
            await refreshWorkspaceIdentities()
            startHistoryIndexing()
            catalogStatus = "\(found.count) conversations found across installed apps"
            isScanning = false
            if modified { scheduleSave() }
            loadSelectedHistory()
            startHistoryIndexing()
        }
    }

    func monitorCatalog() async {
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(60)) }
            catch { break }
            refreshCatalog()
        }
    }

    func retrySelectedHistory() {
        if let selectedID { historyErrors.removeValue(forKey: selectedID) }
        loadSelectedHistory()
    }

    func loadSelectedHistory() {
        guard let id = selectedID,
              let index = conversations.firstIndex(where: { $0.id == id }),
              conversations[index].historyLoaded == false,
              let sourceID = conversations[index].sourceIdentity,
              historyErrors[id] == nil, !loadingHistory else { return }
        let stored = conversations[index]
        let source = sourceIndex[sourceID] ?? DiscoveredSession(
            id: sourceID, provider: stored.sourceEndpoint?.provider ?? stored.provider, kind: stored.sourceKind ?? stored.provider.title,
            vendorID: stored.sourceEndpoint?.nativeThreadID ?? stored.vendorSessionID ?? "", title: stored.title,
            workingDirectory: stored.workingDirectory, locator: stored.sourceLocator, updatedAt: stored.updatedAt)
        loadingHistory = true
        loadingHistoryID = id
        Task {
            do {
                let entries = try await ConversationCatalog.load(source)
                if let position = conversations.firstIndex(where: { $0.id == id }) {
                    conversations[position].migrateEndpoints()
                    if let endpoint = conversations[position].sourceEndpoint {
                        conversations[position].entries = HistoryReconciler.merge(entries, endpoint: endpoint,
                            into: conversations[position].entries)
                        if let endpointIndex = conversations[position].endpoints?.firstIndex(where: { $0.id == endpoint.id }) {
                            conversations[position].endpoints?[endpointIndex].completeness = .partial
                            conversations[position].endpoints?[endpointIndex].sourceRevision = StableIdentity.hash(entries.map { ($0.nativeItemID ?? "") + $0.text }.joined())
                        }
                    }
                    conversations[position].historyLoaded = true
                    scheduleSave()
                }
            } catch { historyErrors[id] = error.localizedDescription }
            loadingHistory = false
            loadingHistoryID = nil
            if selectedID != id { loadSelectedHistory() }
        }
    }

    func historySearch(_ query: String) async -> [HistorySearchResult] {
        ((try? await store.search(query)) ?? []).filter { [.user, .assistant].contains($0.entry.kind) }
    }

    func toggleHistoryIndexing() {
        if indexingTask != nil { indexingPaused = true; indexingTask?.cancel(); indexingStatus = "Indexing paused" }
        else { indexingPaused = false; startHistoryIndexing() }
    }
    func startHistoryIndexing() {
        guard indexingTask == nil, !indexingPaused else { return }
        indexingTask = Task {
            defer { indexingTask = nil }
            let pending = conversations.filter { $0.historyLoaded == false && $0.sourceIdentity != nil }
            var failures = 0
            for (offset, stored) in pending.enumerated() {
                guard !Task.isCancelled else { indexingStatus = "Indexing paused"; return }
                indexingStatus = "Indexing history \(offset + 1) / \(pending.count)"
                guard let sourceID = stored.sourceIdentity,
                      let current = conversations.first(where: { $0.id == stored.id }), current.historyLoaded == false,
                      ![.running, .connecting, .waitingForApproval].contains(current.state) else { continue }
                let source = sourceIndex[sourceID] ?? DiscoveredSession(id: sourceID,
                    provider: stored.sourceEndpoint?.provider ?? stored.provider, kind: stored.sourceKind ?? stored.provider.title,
                    vendorID: stored.sourceEndpoint?.nativeThreadID ?? stored.vendorSessionID ?? "", title: stored.title,
                    workingDirectory: stored.workingDirectory, locator: stored.sourceLocator, updatedAt: stored.updatedAt)
                do {
                    let entries = try await ConversationCatalog.load(source)
                    guard !Task.isCancelled else { return }
                    if let index = conversations.firstIndex(where: { $0.id == stored.id }) {
                        conversations[index].migrateEndpoints()
                        if let endpoint = conversations[index].sourceEndpoint {
                            conversations[index].entries = HistoryReconciler.merge(entries, endpoint: endpoint, into: conversations[index].entries)
                        }
                        // A newer scan will re-index changed histories on its next pass.
                        if conversations[index].sourceEndpoint?.sourceUpdatedAt == stored.sourceEndpoint?.sourceUpdatedAt {
                            conversations[index].historyLoaded = true
                        }
                    }
                } catch { failures += 1 }
                if offset % 20 == 19 {
                    do { try await store.save(conversations); indexingRevision += 1 } catch { failures += 1 }
                }
                await Task.yield()
            }
            do { try await store.save(conversations); indexingRevision += 1 } catch { failures += 1 }
            indexingStatus = failures == 0 ? "History indexed" : "History indexed · \(failures) sources unavailable"
        }
    }

    func hasUnresolvedDelivery(_ conversation: Conversation) -> Bool {
        conversation.nativeEndpoints.contains { unresolvedEndpointIDs.contains($0.id) }
    }

    func openCursorForContinuation() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.todesktop.230313mzl4w4u92") else {
            notice = "Cursor is not installed."; return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, error in
            if let error { Task { @MainActor [weak self] in self?.notice = error.localizedDescription } }
        }
    }

    func continueInBackground(_ chat: Conversation) {
        guard ![.running, .connecting, .waitingForApproval].contains(chat.state),
              !hasUnresolvedDelivery(chat), chat.historyLoaded != false,
              let index = conversations.firstIndex(where: { $0.id == chat.id }) else { return }
        if let task = backgroundTask(for: chat) { openAgent(task.id); return }
        var source = chat; source.migrateEndpoints()
        do { try source.validateResumeAccount() } catch { notice = error.localizedDescription; return }
        guard source.resumeEndpoint != nil else { notice = "Send the first message in this chat before moving it to background execution."; return }
        sessions.removeValue(forKey: chat.id)?.stop()
        sessionTokens.removeValue(forKey: chat.id)
        promptTasks.removeValue(forKey: chat.id)?.cancel()
        conversations[index].state = .connecting
        Task {
            defer {
                if let index = conversations.firstIndex(where: { $0.id == chat.id }) { conversations[index].state = chat.state }
                scheduleSave()
            }
            do {
                let payload = String(decoding: try JSONEncoder().encode(source), as: UTF8.self)
                let result = try await agentBoard.client.request("agents.adopt", params: ["conversation": payload], operationID: "adopt-" + chat.id.uuidString)
                let task = try JSONDecoder().decode(AgentTask.self, from: Data(result.utf8))
                agentBoard.drafts[task.id.uuidString] = drafts[chat.id] ?? chat.savedDraft ?? ""
                await agentBoard.refresh()
                openAgent(task.id)
            } catch { notice = "Could not enable background execution: " + error.localizedDescription }
        }
    }

    func continueWith(_ provider: Provider) {
        guard let id = selectedID, let index = conversations.firstIndex(where: { $0.id == id }),
              ![.running, .connecting, .waitingForApproval].contains(conversations[index].state),
              !hasUnresolvedDelivery(conversations[index]), conversations[index].historyLoaded != false else { return }
        sessions.removeValue(forKey: id)?.stop()
        sessionTokens.removeValue(forKey: id)
        promptTasks.removeValue(forKey: id)?.cancel()
        conversations[index].migrateEndpoints()
        if conversations[index].provider != provider {
            conversations[index].selectedModel = nil
            conversations[index].accountID = preferredAccount(for: provider)
            conversations[index].profileDirectory = nil
        }
        conversations[index].provider = provider
        conversations[index].managedContinuationEnabled = true
        conversations[index].state = .idle
        if conversations[index].resumeEndpoint == nil {
            append(.init(kind: .continuation, text: "Switched to \(provider.title). The next message starts a new session with this provider."), to: id)
        }
        scheduleSave()
    }

    func chooseLinkedWorkspace() {
        guard let id = selectedID, let index = conversations.firstIndex(where: { $0.id == id }),
              ![.running, .connecting, .waitingForApproval].contains(conversations[index].state) else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.message = "Choose the workspace for this thread. The native source workspace is unresolved."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            guard let root = await validatedGitWorkspace(url.path) else {
                notice = "Choose an existing Git repository or worktree."; return
            }
            guard let current = conversations.firstIndex(where: { $0.id == id }),
                  ![.running, .connecting, .waitingForApproval].contains(conversations[current].state) else { return }
            conversations[current].workingDirectory = root
            conversations[current].linkedWorkspaceConfirmed = true
            scheduleSave()
        }
    }

    func send() {
        guard let id = selectedID, let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        if let chat = conversations.first(where: { $0.id == id }), let task = backgroundTask(for: chat) { openAgent(task.id); return }
        conversations[index].migrateEndpoints()
        do { try conversations[index].validateResumeAccount() }
        catch { notice = error.localizedDescription; return }
        let originalDraft = draft
        let originalFiles = experience.attachments[id.uuidString] ?? []
        let text = ComposerContext.prompt(draft.trimmingCharacters(in: .whitespacesAndNewlines), files: originalFiles)
        guard !text.isEmpty, !hasUnresolvedDelivery(conversations[index]), conversations[index].historyLoaded != false,
              ![.running, .connecting, .waitingForApproval].contains(conversations[index].state) else { return }
        if conversations[index].sourceIdentity != nil, conversations[index].sourceEndpoint?.workingDirectory == nil,
           conversations[index].linkedWorkspaceConfirmed != true {
            notice = "The original workspace could not be resolved. Choose a workspace before resuming this thread."
            return
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: conversations[index].workingDirectory, isDirectory: &isDirectory), isDirectory.boolValue else {
            notice = "This workspace is unavailable. Choose an existing folder for a new chat."
            return
        }
        draft = ""
        if conversations[index].entries.isEmpty {
            conversations[index].title = String(text.prefix(60))
        }
        experience.attachments[id.uuidString] = []
        conversations[index].state = .connecting
        let conversation = conversations[index]
        let token = sessionTokens[id] ?? UUID()
        sessionTokens[id] = token
        promptTasks[id] = Task { [self] in
            var deliveryID: UUID?
            do {
                let session: AgentSession
                var needsContext = false
                if let current = sessions[id] { session = current }
                else {
                    needsContext = conversation.resumeEndpoint == nil
                    let accountConfiguration: AccountLaunchConfiguration?
                    if let accountID = conversation.accountID {
                        accountConfiguration = try await accountStore.configuration(for: accountID, provider: conversation.provider)
                        guard sessionTokens[id] == token, !Task.isCancelled else { return }
                        try await accountStore.markUsed(accountID)
                    } else { accountConfiguration = nil }
                    session = try AgentSession(provider: conversation.provider,
                                               workingDirectory: conversation.workingDirectory,
                    profileDirectory: conversation.profileDirectory, accountConfiguration: accountConfiguration, model: conversation.selectedModel) { [weak self] event in
                        Task { @MainActor [weak self] in
                            guard let self, self.sessionTokens[id] == token else { return }
                            self.handle(event, for: id)
                        }
                    }
                    sessions[id] = session
                    let resumeID = conversation.resumeEndpoint?.nativeThreadID
                    let vendorID = try await session.connect(existingSessionID: resumeID)
                    guard sessionTokens[id] == token, !Task.isCancelled else { session.stop(); return }
                    if let position = conversations.firstIndex(where: { $0.id == id }) {
                        if resumeID == nil { _ = conversations[position].attachManagedEndpoint(nativeID: vendorID) }
                        else { _ = try conversations[position].recordResumedEndpoint(nativeID: vendorID) }
                    }
                    if resumeID == nil, let previous = conversation.vendorSessionID {
                        append(.init(kind: .continuation,
                                     text: "Continued from \(conversation.activeEndpoint?.provider.title ?? conversation.provider.title) session \(previous) as \(vendorID)"), to: id)
                    }
                    scheduleSave()
                }
                guard sessionTokens[id] == token, !Task.isCancelled,
                      let current = conversations.first(where: { $0.id == id }), let endpoint = current.activeEndpoint else { return }
                let prompt = needsContext && !conversation.entries.isEmpty
                    ? try await store.contextPrompt(conversation: conversation, request: text) : text
                var entry = Entry(kind: .user, text: text)
                entry.endpointID = endpoint.id; entry.provenance = .managedRuntime
                append(entry, to: id)
                try await store.save(conversations)
                guard sessionTokens[id] == token, !Task.isCancelled else { return }
                let intent = Delivery(principal: "local-user", idempotencyKey: UUID().uuidString,
                                      endpointID: endpoint.id, message: prompt)
                _ = try await store.enqueue(intent)
                deliveryID = intent.id
                _ = try await store.transition(intent.id, to: .dispatching)
                let turnID = try await session.prompt(prompt)
                _ = try await store.transition(intent.id, to: .accepted, receipt: DeliveryReceipt(
                    endpointID: endpoint.id, nativeThreadID: endpoint.nativeThreadID, nativeTurnID: turnID,
                    evidence: "Managed runtime acknowledged the prompt RPC; desktop visibility is unverified"))

            } catch {
                if let deliveryID {
                    do {
                        let uncertain = try await store.transition(deliveryID, to: .unknown, detail: "Prompt acknowledgement was not recorded. Reconcile before retrying.")
                        unresolvedEndpointIDs.insert(uncertain.endpointID)
                    } catch { notice = "Could not record delivery outcome: \(error.localizedDescription)" }
                }
                guard sessionTokens[id] == token else { return }
                if deliveryID == nil {
                    sessions.removeValue(forKey: id)?.stop()
                    if (drafts[id] ?? "").isEmpty { drafts[id] = originalDraft; if selectedID == id { draft = originalDraft } }
                    if (experience.attachments[id.uuidString] ?? []).isEmpty { experience.attachments[id.uuidString] = originalFiles }
                }
                handle(.error(error.localizedDescription), for: id)
            }
            promptTasks.removeValue(forKey: id)
        }
    }

    func cancel() {
        guard let id = selectedID else { return }
        if selected?.state == .connecting {
            sessionTokens.removeValue(forKey: id)
            promptTasks.removeValue(forKey: id)?.cancel()
            sessions.removeValue(forKey: id)?.stop()
            handle(.status(.interrupted, "Connection cancelled"), for: id)
            return
        }
        guard let session = sessions[id] else { return }
        Task { do { try await session.cancel() } catch { handle(.error(error.localizedDescription), for: id) } }
    }

    func answer(_ approval: PendingApproval, choice: String) {
        guard let session = sessions[approval.conversationID] else { return }
        do {
            try session.answerApproval(id: approval.id, choice: choice)
            approvals.removeAll { $0.id == approval.id && $0.conversationID == approval.conversationID }
        } catch { handle(.error(error.localizedDescription), for: approval.conversationID) }
    }

    func answer(_ question: PendingQuestion, answers: [String: [String]]) {
        guard let session = sessions[question.conversationID] else { return }
        do {
            try session.answerQuestion(id: question.id, answers: answers)
            questions.removeAll { $0.id == question.id && $0.conversationID == question.conversationID }
        } catch { handle(.error(error.localizedDescription), for: question.conversationID) }
    }

    private func handle(_ event: SessionEvent, for id: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        switch event {
        case .messageStart: newAssistantMessages.insert(id)
        case .text(let delta):
            let startsMessage = newAssistantMessages.remove(id) != nil
            if !startsMessage, let last = conversations[index].entries.indices.last,
               conversations[index].entries[last].kind == .assistant {
                conversations[index].entries[last].text += delta
            } else { append(.init(kind: .assistant, text: delta), to: id) }
        case .tool(let detail): append(.init(kind: .tool, text: detail), to: id)
        case .status(let state, let detail):
            conversations[index].state = state
            if [.completed, .interrupted, .failed].contains(state) {
                approvals.removeAll { $0.conversationID == id }
                questions.removeAll { $0.conversationID == id }
            }
            if state != .running { append(.init(kind: .status, text: detail), to: id) }
        case .approval(let requestID, let detail, let options):
            conversations[index].state = .waitingForApproval
            approvals.append(.init(id: requestID, conversationID: id,
                                   method: conversations[index].provider.rawValue,
                                   detail: detail, options: options))
        case .question(let requestID, let items):
            conversations[index].state = .waitingForApproval
            questions.append(.init(id: requestID, conversationID: id, questions: items))
        case .error(let detail):
            sessionTokens.removeValue(forKey: id)
            promptTasks.removeValue(forKey: id)?.cancel()
            sessions.removeValue(forKey: id)?.stop()
            approvals.removeAll { $0.conversationID == id }
            questions.removeAll { $0.conversationID == id }
            conversations[index].state = .failed
            append(.init(kind: .error, text: detail), to: id)
        }
        conversations[index].updatedAt = .now
        scheduleSave()
    }

    private func append(_ entry: Entry, to id: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        var attributed = entry
        if attributed.endpointID == nil, conversations[index].activeEndpoint?.ownership == .managed {
            attributed.endpointID = conversations[index].activeEndpointID
            if [.user, .assistant, .tool].contains(attributed.kind) { attributed.provenance = .managedRuntime }
        }
        conversations[index].entries.append(attributed)
        conversations[index].updatedAt = .now
        scheduleSave()
    }

    func reloadAccounts() async {
        do {
            accounts = try await accountStore.list()
            if let id = newAccountID, !accounts.contains(where: { $0.id == id && $0.provider == selectedProvider }) { newAccountID = nil }
        } catch { accountError = "Could not load saved accounts. \(error.localizedDescription)" }
    }

    func preferredAccount(for provider: Provider) -> UUID? {
        guard let value = accountDefaults[provider.rawValue], let id = UUID(uuidString: value),
              accounts.contains(where: { $0.id == id && $0.provider == provider }) else { return nil }
        return id
    }

    func useAccountByDefault(_ account: AgentAccount?) {
        let provider = account?.provider ?? accountProvider
        if let account { accountDefaults[provider.rawValue] = account.id.uuidString }
        else { accountDefaults.removeValue(forKey: provider.rawValue) }
        UserDefaults.standard.set(accountDefaults, forKey: "accountDefaults")
        if selectedProvider == provider { newAccountID = account?.id }
        accountStatus = account.map { "\($0.label) is the default for new \(provider.title) chats." } ?? "New chats use the current vendor sign-in."
    }

    func accountLabel(for conversation: Conversation) -> String {
        if let id = conversation.accountID { return accounts.first { $0.id == id }?.label ?? "Account unavailable" }
        return conversation.profileDirectory == nil ? "Current sign-in" : "Custom profile"
    }

    func setAccount(_ accountID: UUID?, for conversationID: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }),
              ![.connecting, .running, .waitingForApproval].contains(conversations[index].state) else { return }
        guard accountID != conversations[index].accountID else { return }
        if let accountID, !accounts.contains(where: { $0.id == accountID && $0.provider == conversations[index].provider }) { return }
        sessions.removeValue(forKey: conversationID)?.stop()
        sessionTokens.removeValue(forKey: conversationID)
        promptTasks.removeValue(forKey: conversationID)?.cancel()
        conversations[index].accountID = accountID
        conversations[index].profileDirectory = nil
        conversations[index].state = .idle
        append(.init(kind: .status, text: "Account changed to \(accountLabel(for: conversations[index]))."), to: conversationID)
        scheduleSave()
    }

    func saveCurrentAccount() {
        guard !isAccountBusy else { return }
        let provider = accountProvider, label = accountName
        beginAccountAction()
        accountTask = Task {
            do {
                let account = try await accountStore.captureCurrent(provider: provider, label: label)
                await reloadAccounts()
                accountName = ""
                accountStatus = "Saved \(account.label)."
            } catch { accountError = error.localizedDescription }
            isAccountBusy = false
        }
    }

    func importAccountFile(_ file: URL) {
        guard !isAccountBusy else { return }
        let provider = accountProvider, label = accountName
        beginAccountAction()
        accountTask = Task {
            do {
                let account = try await accountStore.importFile(file, provider: provider, label: label)
                await reloadAccounts()
                accountName = ""
                accountStatus = "Imported \(account.label)."
            } catch { accountError = error.localizedDescription }
            isAccountBusy = false
        }
    }

    func importSavedAccounts() {
        guard !isAccountBusy else { return }
        let provider = accountProvider
        beginAccountAction()
        accountTask = Task {
            do {
                let result = try await accountStore.importSavedAccounts(provider: provider)
                await reloadAccounts()
                accountStatus = result.imported == 0 && result.skipped == 0
                    ? "No saved accounts found in the supported account managers."
                    : "Imported \(result.imported) accounts" + (result.skipped > 0 ? "; \(result.skipped) unavailable profiles skipped." : ".")
            } catch { accountError = error.localizedDescription }
            isAccountBusy = false
        }
    }

    func signInAccount() {
        guard !isAccountBusy else { return }
        let provider = accountProvider, label = accountName
        let login = AccountLogin()
        accountLogin = login
        beginAccountAction()
        isSigningIn = true
        accountTask = Task {
            var loginID: UUID?
            let timeout = Task {
                do { try await Task.sleep(for: .seconds(300)); login.cancel() }
                catch { }
            }
            defer { timeout.cancel(); accountLogin = nil; isSigningIn = false; isAccountBusy = false }
            do {
                let (id, configuration) = try await accountStore.beginLogin(provider: provider)
                loginID = id
                try await login.run(configuration: configuration)
                try Task.checkCancellation()
                let account = try await accountStore.finishLogin(id, configuration: configuration, label: label)
                await reloadAccounts()
                accountName = ""
                accountStatus = "Signed in as \(account.label)."
            } catch is CancellationError {
                if let loginID { try? await accountStore.discardLogin(loginID) }
                accountStatus = "Sign-in cancelled or timed out."
            } catch {
                if let loginID { try? await accountStore.discardLogin(loginID) }
                accountError = error.localizedDescription
            }
        }
    }

    func cancelAccountSignIn() { accountLogin?.cancel(); accountTask?.cancel() }

    func renameAccount(_ account: AgentAccount, label: String) {
        guard !isAccountBusy else { return }
        beginAccountAction()
        accountTask = Task {
            do { try await accountStore.rename(account.id, label: label); await reloadAccounts(); accountStatus = "Account renamed." }
            catch { accountError = error.localizedDescription }
            isAccountBusy = false
        }
    }

    func removeAccount(_ account: AgentAccount) {
        guard !isAccountBusy else { return }
        guard !conversations.contains(where: { $0.accountID == account.id }) else {
            accountError = "This account is assigned to a chat. Choose another account in those chats before removing it."
            return
        }
        beginAccountAction()
        accountTask = Task {
            do {
                try await accountStore.remove(account.id)
                if preferredAccount(for: account.provider) == account.id { useAccountByDefault(nil) }
                await reloadAccounts()
                accountStatus = "Removed \(account.label) from Shastra."
            } catch { accountError = error.localizedDescription }
            isAccountBusy = false
        }
    }

    private func beginAccountAction() { isAccountBusy = true; accountError = nil; accountStatus = nil }

    func flushBeforeQuit() async -> Bool {
        indexingTask?.cancel()
        await indexingTask?.value
        saveTask?.cancel()
        do { try await store.save(conversations); return true }
        catch { notice = "Could not save before quitting: \(error.localizedDescription)"; return false }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            do { try await store.save(conversations) }
            catch { notice = "Could not save conversations: \(error.localizedDescription)" }
        }
    }
}

@MainActor final class ShastraAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        Task { sender.reply(toApplicationShouldTerminate: await model.flushBeforeQuit()) }
        return .terminateLater
    }
}

@main struct ShastraApp: App {
    @NSApplicationDelegateAdaptor(ShastraAppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    @Environment(\.openWindow) private var openWindow
    var body: some Scene {
        WindowGroup("Shastra", id: "main") {
            WorkspaceView()
                .environmentObject(model)
                .task {
                    delegate.model = model
                    ExperienceNotifications.shared.openChat = { id in model.openAgent(id); openWindow(id: "main") }
                    await model.load(); await model.monitorCatalog()
                }
                .frame(minWidth: 1080, minHeight: 680)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1390, height: 860)
        .commands {
            CommandGroup(after: .appSettings) {
                Button("Skills & tools…") { model.showRuntimeLibrary = true }
                Button("Accounts…") { model.showAccounts = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .newItem) {
                Button("New Chat") { model.beginNewChat() }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandMenu("Navigate") {
                Button("Search & Commands…") { model.showPalette = true }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Quick Open…") { model.showPalette = true }
                    .keyboardShortcut("k", modifiers: .command)
            }
        }
    }
}
