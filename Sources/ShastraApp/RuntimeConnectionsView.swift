import SwiftUI
import ShastraCore

struct RuntimeConnectionsView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var board: AgentBoardModel
    let accounts: () -> Void
    let inspect: (Provider) -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("On this Mac").font(.headline)
                    Spacer()
                    Button("Refresh") { app.availability = ExecutableLocator.discover() }
                    Button("Manage accounts…", action: accounts)
                }
                if board.connected {
                    Text("Connected").font(.caption.bold()).foregroundStyle(Surface.muted)
                    HStack(spacing: 12) {
                        Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(Surface.accent)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Shastra coordination").fontWeight(.medium)
                            Text("The local background service is responding. Agents can report progress and coordinate tasks.").font(.caption).foregroundStyle(Surface.muted)
                        }
                        Spacer(); Text("Connected").font(.caption).foregroundStyle(Surface.accent)
                    }.padding(12).materialPanel(radius: 12)
                } else {
                    Label("Shastra coordination · Unavailable", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(Surface.warning)
                        .help("The local background service has not responded.")
                }
                section("Available", items: app.availability.filter(\.isReady))
                section("Unavailable", items: app.availability.filter { !$0.isReady })
                Text("Available means the runtime is installed. Authentication and each MCP server’s connection are checked by that runtime when used. The library shows user or project settings; saved accounts may have separate configurations.")
                    .font(.caption).foregroundStyle(Surface.muted)
            }.padding(.vertical, 8)
        }.frame(height: 435)
    }
    private func section(_ title: String, items: [ProviderAvailability]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !items.isEmpty { Text(title).font(.caption.bold()).foregroundStyle(Surface.muted) }
            ForEach(items) { item in
                HStack(spacing: 12) {
                    Image(systemName: item.isReady ? "terminal" : "minus.circle").frame(width: 22).foregroundStyle(Surface.muted)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.provider.title).fontWeight(.medium)
                        Text(!item.provider.supportedInMVP ? "Adapter not available in this build" : item.isReady ? "Installed · \(app.accounts.filter { $0.provider == item.provider }.count) saved accounts" : item.provider == .claude && item.path != nil ? "Claude bridge or Node.js unavailable" : "Install the provider’s CLI to use this runtime")
                            .font(.caption).foregroundStyle(Surface.muted)
                    }
                    Spacer()
                    if item.isReady { Button("Inspect skills & tools") { inspect(item.provider) }.font(.caption) }
                    else { Text("Unavailable").font(.caption).foregroundStyle(Surface.muted) }
                }.padding(12).background(Surface.raised, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}
