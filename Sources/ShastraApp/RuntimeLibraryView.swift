import AppKit
import SwiftUI
import ShastraCore

@MainActor private final class RuntimeLibraryState: ObservableObject {
    @Published var showingAccounts = false
    @Published var tab = "Connections"
    @Published var destinationItems: [RuntimeLibraryItem] = []
    @Published var revision = 0
    @Published var selectedFromDestination = false
    @Published var source = Provider.codex
    @Published var destination = Provider.claude
    @Published var project = false
    @Published var search = ""
    @Published var items: [RuntimeLibraryItem] = []
    @Published var selected: RuntimeLibraryItem?
    @Published var name = ""
    @Published var plan: RuntimeCopyPlan?
    @Published var receipt: RuntimeCopyReceipt?
    @Published var includeCredentials = false
    @Published var busy = false
    @Published var status = ""
    @Published var inventoryError: String?
    let library = RuntimeLibrary()
}
struct RuntimeLibraryView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var ui = RuntimeLibraryState()
    private var workspace: String {
        if app.showNewConversation { return app.workingDirectory }
        if app.showAgents { return app.agentBoard.selected?.workspace ?? app.workingDirectory }
        return app.selected?.workingDirectory ?? app.workingDirectory
    }
    private var base: URL {
        ui.project ? URL(fileURLWithPath: workspace) : FileManager.default.homeDirectoryForCurrentUser
    }
    private var source: RuntimeLocation { .init(provider: ui.source, base: base, project: ui.project) }
    private var destination: RuntimeLocation { .init(provider: ui.destination, base: base, project: ui.project) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Skills & tools").font(.system(size: 22, weight: .semibold))
                    Text("Copy skill bundles and compatible MCP servers between runtimes.").font(.caption).foregroundStyle(Surface.muted)
                }
                Spacer(); Button("Done") { dismiss() }.buttonStyle(AppButtonStyle())
            }
            Picker("Library view", selection: $ui.tab) {
                Text("Connections").tag("Connections")
                Text("Skills & tools").tag("Library")
            }.pickerStyle(.segmented)
            if ui.tab == "Connections" {
                RuntimeConnectionsView(board: app.agentBoard) {
                    ui.showingAccounts = true
                } inspect: { provider in ui.source = provider; ui.tab = "Library" }
            } else {
            HStack {
                Picker("From", selection: $ui.source) { ForEach(Provider.allCases.filter(\.supportedInMVP)) { Text($0.title).tag($0) } }
                Image(systemName: "arrow.right")
                Picker("To", selection: $ui.destination) { ForEach(Provider.allCases.filter(\.supportedInMVP)) { Text($0.title).tag($0) } }
                Toggle("Project settings", isOn: $ui.project).disabled(app.workspaceIdentities[workspace]?.isGit != true)
                Button("Refresh") { ui.revision += 1 }.help("Refresh source and destination inventory")
            }.disabled(ui.busy)
            Text(ui.project ? base.path : "User settings for the default runtime sign-in. Saved Shastra accounts keep separate configurations.")
                .font(.caption).foregroundStyle(Surface.muted).textSelection(.enabled)
            HSplitView {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Find a skill or tool…", text: $ui.search).textFieldStyle(.roundedBorder)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            if !ui.destinationItems.isEmpty {
                                Text("Configured in \(ui.destination.title)").font(.caption.bold()).foregroundStyle(Surface.muted).padding(.top, 8)
                                ForEach(ui.destinationItems.filter { matches($0) }) { item in libraryRow(item, destination: true) }
                            }
                            ForEach(IntegrationReadiness.allCases.filter { $0 != .configured }, id: \.self) { status in
                                let items = ui.items.filter { matches($0) && readiness($0) == status }
                                if !items.isEmpty {
                                    Text(status.rawValue).font(.caption.bold()).foregroundStyle(Surface.muted).padding(.top, 8)
                                    ForEach(items) { item in libraryRow(item, destination: false) }
                                }
                            }
                            if ui.items.filter({ matches($0) }).isEmpty && ui.destinationItems.filter({ matches($0) }).isEmpty { Text(ui.search.isEmpty ? "No skills or MCP servers found in this scope." : "No matching skills or tools.").foregroundStyle(Surface.muted).padding() }
                        }
                    }
                }.frame(minWidth: 240, idealWidth: 290, maxWidth: 340)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let item = ui.selected {
                            Text(item.name).font(.headline)
                            Text(item.source.path).font(.caption).foregroundStyle(Surface.muted).textSelection(.enabled)
                            if item.kind == .skill { Text(item.detail).font(.caption).lineLimit(8).textSelection(.enabled) }
                            TextField("Destination name", text: $ui.name).textFieldStyle(.roundedBorder).disabled(ui.busy)
                            Label(ui.selectedFromDestination ? "Configured in \(ui.destination.title) · connection not checked" : readiness(item).rawValue, systemImage: "info.circle").font(.caption).foregroundStyle(Surface.muted)
                            if !ui.selectedFromDestination {
                                Button("Preview copy") { preview() }.buttonStyle(AppButtonStyle()).disabled(ui.busy)
                            }
                            if let plan = ui.plan {
                                Label("Destination", systemImage: "folder").font(.caption.bold())
                                Text(plan.destination.path).font(.caption).textSelection(.enabled)
                                Text(plan.preview).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                    .padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Surface.code, in: RoundedRectangle(cornerRadius: 8))
                                if plan.containsCredentials {
                                    Toggle("Include environment values and credentials in this local copy", isOn: $ui.includeCredentials).font(.caption)
                                }
                                Text("Existing names are never overwritten. Configuration changes get a backup. Restart the destination runtime and complete its normal trust/sign-in steps to use copied tools.").font(.caption).foregroundStyle(Surface.muted)
                                Button("Copy to \(ui.destination.title)") {
                                    ui.busy = true
                                    Task {
                                        defer { ui.busy = false }
                                        do { ui.receipt = try await ui.library.apply(plan, includeCredentials: ui.includeCredentials); ui.plan = nil; ui.status = "Copied. Restart the destination runtime to load it."; ui.revision += 1 }
                                        catch { ui.status = error.localizedDescription }
                                    }
                                }.buttonStyle(AppButtonStyle(kind: .primary)).disabled(ui.busy || (plan.containsCredentials && !ui.includeCredentials))
                            }
                        } else { WorkspaceEmptyState(title: "Bring your setup with you", message: "Select a skill or MCP server, choose its destination, then preview the copy.", symbol: "square.on.square") }
                    }.padding(.leading, 16).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minWidth: 400)
            }.frame(height: 380)
            if let error = ui.inventoryError { Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Surface.warning).textSelection(.enabled) }
            if !ui.status.isEmpty { Text(ui.status).font(.caption).textSelection(.enabled) }
            if let receipt = ui.receipt {
                HStack {
                    Button("Reveal copied files") { NSWorkspace.shared.selectFile(receipt.destination.path, inFileViewerRootedAtPath: receipt.destination.deletingLastPathComponent().path) }
                    if let backup = receipt.backup { Button("Reveal backup") { NSWorkspace.shared.selectFile(backup.path, inFileViewerRootedAtPath: backup.deletingLastPathComponent().path) } }
                    Button("Undo last copy") {
                        Task { do { try await ui.library.undo(receipt); ui.receipt = nil; ui.status = "Copy undone; previous files preserved."; ui.revision += 1 } catch { ui.status = error.localizedDescription } }
                    }.disabled(ui.busy)
                }.font(.caption)
            }
            Text("Configured means saved settings, not a verified live connection. Copying does not install a runtime or sign in.").font(.caption).foregroundStyle(Surface.muted)
            }
            Divider()
            NotificationSettings()
        }.padding(24).frame(width: 890).materialPanel(color: Surface.canvas)
            .task(id: "\(ui.source):\(ui.destination):\(ui.project):\(base.path):\(ui.revision)") {
                ui.selected = nil; ui.plan = nil; ui.inventoryError = nil
                do {
                    let sourceItems = try await ui.library.inventory(source)
                    let destinationItems = try await ui.library.inventory(destination)
                    guard !Task.isCancelled else { return }
                    ui.items = sourceItems; ui.destinationItems = destinationItems
                } catch { if !Task.isCancelled { ui.items = []; ui.destinationItems = []; ui.inventoryError = error.localizedDescription } }
            }
            .sheet(isPresented: $ui.showingAccounts) { AccountsView().environmentObject(app) }
            .onChange(of: ui.source) { _, _ in ui.status = "" }
            .onChange(of: ui.project) { _, _ in ui.status = "" }
            .onChange(of: ui.destination) { _, _ in ui.plan = nil; ui.status = "" }
            .onChange(of: ui.name) { _, _ in ui.plan = nil }
    }
    private func matches(_ item: RuntimeLibraryItem) -> Bool { ui.search.isEmpty || item.name.localizedCaseInsensitiveContains(ui.search) }
    private func readiness(_ item: RuntimeLibraryItem) -> IntegrationReadiness {
        .assess(item, destinationItems: ui.destinationItems, runtimeAvailable: app.availability.first { $0.provider == ui.destination }?.isReady == true)
    }
    private func libraryRow(_ item: RuntimeLibraryItem, destination: Bool) -> some View {
        Button {
            ui.selected = item; ui.selectedFromDestination = destination; ui.name = item.name
            ui.plan = nil; ui.includeCredentials = false; ui.status = ""
        } label: {
            HStack {
                Image(systemName: item.kind == .skill ? "sparkles" : "wrench.and.screwdriver")
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name).lineLimit(1)
                    Text(item.kind.rawValue + (item.fields?["enabled"] == .bool(false) || item.fields?["disabled"] == .bool(true) ? " · Disabled" : ""))
                        .font(.caption).foregroundStyle(Surface.muted)
                }
                Spacer()
            }.padding(9).contentShape(Rectangle()).background(ui.selected?.id == item.id ? Surface.selected : .clear, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).disabled(ui.busy).help(item.source.path)
    }
    private func preview() {
        guard let item = ui.selected else { return }
        ui.busy = true; ui.plan = nil
        let from = source, to = destination, name = ui.name
        Task {
            defer { ui.busy = false }
            do { let plan = try await ui.library.preview(item, from: from, to: to, name: name); if source == from, destination == to, ui.name == name { ui.plan = plan; ui.status = "" } }
            catch { ui.status = error.localizedDescription }
        }
    }
}
