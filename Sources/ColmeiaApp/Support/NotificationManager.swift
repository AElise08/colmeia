import Foundation
import AppKit
import UserNotifications
import ColmeiaKit

/// Notificações §19 via UserNotifications. UNUserNotificationCenter exige bundle de app;
/// rodando como executável SPM cru (sem .app) o framework aborta — por isso tudo aqui é
/// no-op quando `Bundle.main.bundleIdentifier == nil`. Sem som por padrão (§19).
@MainActor
final class NotificationManager: NSObject {
    static let disponivel = Bundle.main.bundleIdentifier != nil

    var onNavigateToNode: ((ULID) -> Void)?

    func requestPermission() {
        guard Self.disponivel else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .badge]) { _, _ in }
    }

    func notifyAprovacao(_ approval: Approval, nodeID: ULID?) {
        deliver(
            title: "Aprovação pendente — \(approval.nodeNome)",
            body: approval.resumo,
            nodeID: nodeID
        )
    }

    func notifyRotina(_ routine: Routine, resultado: RoutineResultado) {
        deliver(
            title: "Rotina \(routine.nome)",
            body: resultado == .executada ? "executada" : resultado.rawValue,
            nodeID: routine.alvo
        )
    }

    func notifySessaoMorta(node: String, nodeID: ULID, motivo: String?) {
        deliver(
            title: "Sessão morta — \(node)",
            body: motivo ?? "o processo saiu inesperadamente",
            nodeID: nodeID
        )
    }

    private func deliver(title: String, body: String, nodeID: ULID?) {
        guard Self.disponivel else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let nodeID {
            content.userInfo = ["node_id": nodeID.string]
        }
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}

extension NotificationManager: UNUserNotificationCenterDelegate {
    /// Clique DEVE levar ao nó (§19).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let raw = userInfo["node_id"] as? String
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            if let raw, let nodeID = ULID(raw) {
                self.onNavigateToNode?(nodeID)
            }
            completionHandler()
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner])
    }
}
