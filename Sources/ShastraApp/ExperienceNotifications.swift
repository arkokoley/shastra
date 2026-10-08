import AppKit
import UserNotifications
import SwiftUI
import ShastraCore

extension Notification.Name { static let shastraOpenChat = Notification.Name("shastra.open-chat") }
@MainActor final class ExperienceNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ExperienceNotifications()
    var openChat: ((UUID) -> Void)?
    private var seeded = false
    private var seen: [UUID: String] = [:]
    private var previous: [UUID: AgentTaskStatus] = [:]
    private var delivered = Set(UserDefaults.standard.stringArray(forKey: "notificationReceipts") ?? [])
    func enable() async throws -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }
    func observe(_ tasks: [AgentTask]) {
        let enabled = ExperiencePreferences.read(UserDefaults.standard.data(forKey: "experience.v1")).notifications
        UNUserNotificationCenter.current().delegate = self
        for task in tasks {
            let event = "\(task.status.rawValue):\(task.approvals.map(\.id).sorted().joined(separator: ","))"
            defer { seen[task.id] = event; previous[task.id] = task.status }
            guard seeded, enabled, !task.archived, seen[task.id] != event else { continue }
            let needsInput = !task.approvals.isEmpty || task.status == .needsInput
            let finished = [.completed, .failed, .interrupted].contains(task.status) && previous[task.id]?.isActive == true
            guard needsInput || finished else { continue }
            let receipt = "\(task.id):\(event):\(task.updatedAt.timeIntervalSince1970)"
            guard delivered.insert(receipt).inserted else { continue }
            let content = UNMutableNotificationContent()
            content.title = needsInput ? "Agent needs you" : task.status == .completed ? "Agent finished" : "Agent stopped"
            content.body = task.title
            content.userInfo = ["taskID": task.id.uuidString]
            UNUserNotificationCenter.current().add(.init(identifier: receipt, content: content, trigger: nil))
        }
        seeded = true
        if delivered.count > 500 { delivered = Set(delivered.sorted().suffix(500)) }
        UserDefaults.standard.set(Array(delivered), forKey: "notificationReceipts")
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let id = response.notification.request.content.userInfo["taskID"] as? String else { return }
        await MainActor.run {
            if let id = UUID(uuidString: id) { Self.shared.openChat?(id) }
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner] }
}

struct NotificationSettings: View {
    @EnvironmentObject private var app: AppModel
    var body: some View {
        HStack {
            Label("Notify for approvals and finished work", systemImage: "bell")
                .help("Notifications appear while Shastra is running, including with its window closed. Background agents also continue after you quit the app.")
            Spacer()
            if app.experience.notifications {
                Button("Turn off") { app.experience.notifications = false }
            } else {
                Button("Enable notifications") {
                    Task {
                        do {
                            app.experience.notifications = try await ExperienceNotifications.shared.enable()
                            if !app.experience.notifications { app.notice = "Notifications are disabled in macOS. Enable Shastra in System Settings → Notifications." }
                        } catch { app.notice = error.localizedDescription }
                    }
                }
            }
        }.font(.caption)
    }
}
