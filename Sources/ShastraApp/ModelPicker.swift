import SwiftUI
import ShastraCore

@MainActor private final class ModelPickerState: ObservableObject {
    @Published var presented = false
    @Published var query = ""
    @Published var snapshot: ModelCatalogSnapshot?
    @Published var loading = false
    @Published var error: String?
    @Published var reload = UUID()
    var forceRefresh = false
    private var context: ModelCatalogContext?
    private var generation = UUID()
    func refresh(_ next: ModelCatalogContext, store: AccountStore, force: Bool) async {
        let token = UUID(); generation = token
        if context != next { snapshot = nil; error = nil; context = next }
        loading = true
        if let cached = await ModelCatalogCache.shared.cached(next) {
            guard generation == token, !Task.isCancelled else { return }
            snapshot = cached
            if !force && Date().timeIntervalSince(cached.updatedAt) < 300 { loading = false; return }
        }
        do {
            let configuration: AccountLaunchConfiguration?
            if let id = next.accountID { configuration = try await store.configuration(for: id, provider: next.provider) }
            else { configuration = nil }
            try Task.checkCancellation()
            let value = try await ProviderModelReader.read(next, configuration: configuration)
            guard generation == token, !Task.isCancelled else { return }
            await ModelCatalogCache.shared.store(value, for: next)
            snapshot = value; error = nil; loading = false
        } catch {
            guard generation == token else { return }
            loading = false
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }
}
struct ModelPicker: View {
    @EnvironmentObject private var app: AppModel
    @StateObject private var ui = ModelPickerState()
    @FocusState private var searchFocused: Bool
    let provider: Provider
    @Binding var model: String
    var accountID: UUID? = nil
    var workspace = ""
    var profile: String? = nil
    private var context: ModelCatalogContext { .init(provider: provider, accountID: accountID, profile: profile, workspace: workspace) }
    private var favorites: [String] { app.experience.modelFavorites?[context.preferenceKey] ?? [] }
    private var choices: [ProviderModel] {
        (ui.snapshot?.models ?? []).filter { ui.query.isEmpty || "\($0.name) \($0.id) \($0.detail)".localizedCaseInsensitiveContains(ui.query) }
            .sorted { a, b in
                if favorites.contains(a.id) != favorites.contains(b.id) { return favorites.contains(a.id) }
                if a.isDefault != b.isDefault { return a.isDefault }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
    }
    private var accountLabel: String {
        if let accountID { return app.accounts.first { $0.id == accountID }?.label ?? "Account unavailable" }
        return profile == nil ? "Current provider login" : "Custom profile"
    }
    var body: some View {
        Button { ui.presented.toggle() } label: {
            Label(model.isEmpty ? "Default model" : model, systemImage: "slider.horizontal.3").lineLimit(1)
        }.buttonStyle(.plain).help("Choose model").popover(isPresented: $ui.presented) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) { Text("\(provider.title) models").font(.headline); Text(accountLabel).font(.caption).foregroundStyle(Surface.muted) }
                    Spacer()
                    if ui.loading { ProgressView().controlSize(.small) }
                    Button { ui.forceRefresh = true; ui.reload = UUID() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).help("Refresh models").disabled(ui.loading)
                }
                TextField("Search models or enter an ID", text: $ui.query).textFieldStyle(.roundedBorder).focused($searchFocused)
                Button { choose("") } label: { Label("Provider default", systemImage: model.isEmpty ? "checkmark.circle.fill" : "circle") }.buttonStyle(.plain)
                if !model.isEmpty, let snapshot = ui.snapshot, !snapshot.models.contains(where: { $0.id == model || $0.resolvedID == model }) {
                    Text("Selected: \(model). This ID was not returned in this catalog; it remains selected until you change it.").font(.caption).foregroundStyle(Surface.warning)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(choices) { item in
                            HStack(alignment: .top, spacing: 10) {
                                Button { choose(item.id) } label: {
                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName: model == item.id || model == item.resolvedID ? "checkmark.circle.fill" : "circle").foregroundStyle(Surface.accent)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(item.name + (item.isDefault ? " · Default" : "")).font(.system(size: 12, weight: .medium))
                                            Text(item.id).font(.system(size: 10, design: .monospaced)).foregroundStyle(Surface.muted)
                                            if !item.detail.isEmpty { Text(item.detail).font(.caption).foregroundStyle(Surface.muted).lineLimit(3) }
                                            if !item.modalities.isEmpty || !item.reasoningEfforts.isEmpty {
                                                Text((item.modalities + (item.reasoningEfforts.isEmpty ? [] : ["Effort: " + item.reasoningEfforts.joined(separator: ", ")])).joined(separator: " · ")).font(.caption2).foregroundStyle(Surface.muted)
                                            }
                                        }.frame(maxWidth: .infinity, alignment: .leading)
                                    }.padding(7).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                Button { toggleFavorite(item.id) } label: { Image(systemName: favorites.contains(item.id) ? "star.fill" : "star") }.buttonStyle(.plain).foregroundStyle(Surface.accent).help(favorites.contains(item.id) ? "Unpin model" : "Pin model").accessibilityLabel((favorites.contains(item.id) ? "Unpin " : "Pin ") + item.name).padding(.top, 7)
                            }.background(model == item.id ? Surface.selected : .clear, in: RoundedRectangle(cornerRadius: 8))
                        }
                        if choices.isEmpty { Text(ui.loading ? "Loading provider models…" : ui.query.isEmpty ? "No catalog available" : "No matching models").font(.caption).foregroundStyle(Surface.muted).padding(.vertical, 10) }
                    }
                }.frame(height: 300)
                if let error = ui.error {
                    Text((ui.snapshot == nil ? "" : "Showing cached results. ") + error).font(.caption).foregroundStyle(Surface.warning).lineLimit(4)
                    Button("Manage accounts…") { ui.presented = false; app.showAccounts = true }.buttonStyle(.plain)
                }
                let custom = ui.query.trimmingCharacters(in: .whitespacesAndNewlines)
                if !custom.isEmpty && !custom.contains(where: \.isWhitespace) && !choices.contains(where: { $0.id == custom }) {
                    Button("Use custom ID: \(custom)") { choose(custom) }.buttonStyle(.plain)
                }
                if let snapshot = ui.snapshot { Text("\(snapshot.models.count) models · \(snapshot.source) · \(snapshot.updatedAt.formatted(date: .omitted, time: .shortened))").font(.caption2).foregroundStyle(Surface.muted) }
                Text("Reported by this runtime for the selected sign-in. Access and quota are checked by the provider when a run starts.").font(.caption2).foregroundStyle(Surface.muted)
            }.padding(16).frame(width: 440).foregroundStyle(Surface.text).background(Surface.canvas)
                .onAppear { searchFocused = true }
                .task(id: "\(context):\(ui.reload)") {
                    let force = ui.forceRefresh; ui.forceRefresh = false
                    await ui.refresh(context, store: app.accountStore, force: force)
                }
        }
    }
    private func choose(_ id: String) { model = id; ui.presented = false }
    private func toggleFavorite(_ id: String) {
        var all = app.experience.modelFavorites ?? [:], values = all[context.preferenceKey] ?? []
        if values.contains(id) { values.removeAll { $0 == id } } else { values.append(id) }
        all[context.preferenceKey] = values; app.experience.modelFavorites = all
    }
}
