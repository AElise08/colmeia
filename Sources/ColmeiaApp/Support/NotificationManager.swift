import Foundation
import AppKit
import UserNotifications
import ColmeiaKit

/// Destino completo de uma notificação: o node sozinho não basta quando a janela
/// está em outro workspace/andar (§19). Campos opcionais preservam notificações
/// antigas que só conheciam o nó.
struct NotificationDestination: Equatable, Sendable {
    var workspaceID: ULID?
    var floorID: ULID?
    var nodeID: ULID?

    init(workspaceID: ULID? = nil, floorID: ULID? = nil, nodeID: ULID? = nil) {
        self.workspaceID = workspaceID
        self.floorID = floorID
        self.nodeID = nodeID
    }
}

/// Notificações §19 via UserNotifications. UNUserNotificationCenter exige bundle de app;
/// rodando como executável SPM cru (sem .app) o framework aborta — por isso tudo aqui é
/// no-op quando `Bundle.main.bundleIdentifier == nil`. Sem som por padrão (§19).
@MainActor
final class NotificationManager: NSObject {
    static let disponivel = Bundle.main.bundleIdentifier != nil

    /// Novo callback com contexto completo. AppStore deve fornecer workspace e
    /// andar ao criar a notificação; o App troca o contexto antes de focar o nó.
    var onNavigateToDestination: ((NotificationDestination) -> Void)?
    /// Compatibilidade com os chamadores atuais durante a migração.
    var onNavigateToNode: ((ULID) -> Void)?

    func requestPermission() {
        guard Self.disponivel else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .badge]) { _, _ in }
    }

    func notifyAprovacao(
        _ approval: Approval,
        nodeID: ULID?,
        destination: NotificationDestination? = nil
    ) {
        deliver(
            title: "Aprovação pendente — \(approval.nodeNome)",
            body: approval.resumo,
            destination: destination ?? NotificationDestination(nodeID: nodeID)
        )
    }

    func notifyRotina(
        _ routine: Routine,
        resultado: RoutineResultado,
        destination: NotificationDestination? = nil
    ) {
        deliver(
            title: "Rotina \(routine.nome)",
            body: resultado == .executada ? "executada" : resultado.rawValue,
            destination: destination ?? NotificationDestination(nodeID: routine.alvo)
        )
    }

    func notifySessaoMorta(
        node: String,
        nodeID: ULID,
        motivo: String?,
        destination: NotificationDestination? = nil
    ) {
        deliver(
            title: "Sessão morta — \(node)",
            body: motivo ?? "o processo saiu inesperadamente",
            destination: destination ?? NotificationDestination(nodeID: nodeID)
        )
    }

    func notifyAndarOrfao(nome: String, destination: NotificationDestination) {
        deliver(
            title: "Andar órfão — \(nome)",
            body: "O worktree existe, mas não estava registrado. Abra o andar para readotá-lo.",
            destination: destination
        )
    }

    func notifyEntrega(resumo: String, destination: NotificationDestination) {
        deliver(
            title: "Entrega pronta",
            body: resumo,
            destination: destination
        )
    }

    private func deliver(title: String, body: String, destination: NotificationDestination) {
        guard Self.disponivel else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        var userInfo: [String: String] = [:]
        if let workspaceID = destination.workspaceID { userInfo["workspace_id"] = workspaceID.string }
        if let floorID = destination.floorID { userInfo["floor_id"] = floorID.string }
        if let nodeID = destination.nodeID { userInfo["node_id"] = nodeID.string }
        if !userInfo.isEmpty {
            content.userInfo = userInfo
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
        let destination = NotificationDestination(
            workspaceID: (userInfo["workspace_id"] as? String).flatMap(ULID.init),
            floorID: (userInfo["floor_id"] as? String).flatMap(ULID.init),
            nodeID: (userInfo["node_id"] as? String).flatMap(ULID.init)
        )
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            if (destination.workspaceID != nil || destination.floorID != nil || destination.nodeID != nil),
               let onNavigateToDestination = self.onNavigateToDestination {
                onNavigateToDestination(destination)
            } else if let nodeID = destination.nodeID {
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
