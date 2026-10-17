import SwiftUI
import ShastraCore

struct AgentAccessMenu: View {
    let mode: AgentAccessMode
    var disabled = false
    let select: (AgentAccessMode) -> Void
    var body: some View {
        Menu {
            Text("Codex permissions · saved for future chats")
            ForEach(AgentAccessMode.allCases, id: \.self) { option in
                Button { select(option) } label: {
                    Label("\(option.title) — \(option.detail)", systemImage: option == mode ? "checkmark" : "shield")
                }
            }
        } label: {
            Label(mode.title, systemImage: mode == .full ? "shield.lefthalf.filled.trianglebadge.exclamationmark" : "shield")
        }.menuStyle(.borderlessButton).fixedSize().font(.system(size: 12))
            .foregroundStyle(mode == .full ? Surface.warning : Surface.muted)
            .disabled(disabled).help(mode.detail + (disabled ? " Change when the agent is idle." : " Your choice is remembered."))
            .accessibilityLabel("Codex permissions").accessibilityValue(mode.title)
    }
}
