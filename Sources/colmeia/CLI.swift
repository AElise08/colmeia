import Foundation
import ColmeiaKit

/// Códigos de saída da CLI (§13.2): 0 sucesso; 1 destino inexistente; 2 timeout;
/// 3 erro de contexto/conexão. 64 (EX_USAGE) fica fora do espaço reservado 0–3.
enum CLIExit {
    static let ok: Int32 = 0
    static let destinoInexistente: Int32 = 1
    static let timeout: Int32 = 2
    static let contexto: Int32 = 3
    static let uso: Int32 = 64
}

struct CLIFailure: Error, Sendable {
    var code: Int32
    var message: String
}

func printErr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// Contexto descoberto pelas envs de sessão gerenciada (§13.1).
struct CLIContext {
    let socketPath: String
    let rawNodeID: String?
    let nodeID: ULID?
    let rawWorkspaceID: String?
    let workspaceID: ULID?
    let sessionID: ULID?
    let hubToken: String?

    init(socketPath: String? = nil, hubToken: String? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.socketPath = socketPath
            ?? environment["COLMEIA_SOCKET_PATH"]
            ?? environment["COLMEIA_SOCKET"]
            ?? environment["COLMEIA_HUB"]
            ?? ColmeiaPaths.socketPath(environment: environment)
        self.hubToken = hubToken ?? environment["COLMEIA_HUB_TOKEN"]
        rawNodeID = environment[ColmeiaEnv.nodeID]
        nodeID = rawNodeID.flatMap(ULID.init)
        rawWorkspaceID = environment[ColmeiaEnv.workspaceID]
        workspaceID = rawWorkspaceID.flatMap(ULID.init)
        sessionID = environment[ColmeiaEnv.sessionID].flatMap(ULID.init)
    }

    /// §6.3 — dentro de terminal gerenciado a CLI se identifica como `agente:<node-id>`;
    /// fora, `humano:local` é legítimo.
    var author: Author {
        nodeID.map { Author.agente($0.string) } ?? .humanoLocal
    }

    /// §13.1 — subcomandos que exigem identidade de agente DEVEM falhar com exit 3
    /// fora de uma sessão gerenciada.
    func requireAgentIdentity(subcomando: String) throws -> (nodeID: ULID, workspaceID: ULID) {
        guard let nodeID else {
            let motivo = rawNodeID.map { "COLMEIA_NODE_ID inválido: \($0)" } ?? "COLMEIA_NODE_ID ausente"
            throw CLIFailure(
                code: CLIExit.contexto,
                message: "colmeia \(subcomando) exige terminal gerenciado — \(motivo) (§13.1)"
            )
        }
        guard let workspaceID else {
            let motivo = rawWorkspaceID.map { "COLMEIA_WORKSPACE_ID inválido: \($0)" }
                ?? "COLMEIA_WORKSPACE_ID ausente"
            throw CLIFailure(
                code: CLIExit.contexto,
                message: "colmeia \(subcomando) exige terminal gerenciado — \(motivo) (§13.1)"
            )
        }
        return (nodeID, workspaceID)
    }
}

/// Conecta ao engine e faz o handshake obrigatório (§6.3).
/// Qualquer falha aqui é erro de contexto/conexão → exit 3.
func connectEngine(_ context: CLIContext) async throws -> SocketClient {
    let client = SocketClient()
    do {
        try client.connect(to: context.socketPath)
    } catch {
        throw CLIFailure(
            code: CLIExit.contexto,
            message: "não conectou ao engine em \(context.socketPath): \(error) — o engine está rodando?"
        )
    }
    do {
        // Watchdog próprio: um engine aceitando conexões mas mudo travaria a CLI para sempre.
        _ = try await racedCall(
            client: client,
            watchdogSeconds: 10,
            expiry: CLIFailure(code: CLIExit.contexto, message: "engine não respondeu ao handshake em 10s")
        ) {
            try await client.hello(client: "cli", author: context.author, token: context.hubToken)
        }
    } catch let failure as CLIFailure {
        client.close()
        throw failure
    } catch {
        client.close()
        throw CLIFailure(code: CLIExit.contexto, message: "handshake com o engine falhou: \(error)")
    }
    return client
}

/// Corre `operation` contra um watchdog local — protege contra engine travado, que nunca
/// responderia. Na expiração fecha o client: isso acorda a continuation pendente do
/// SocketClient (que não é cancelável) e evita o task group esperar para sempre.
func racedCall<T: Sendable>(
    client: SocketClient,
    watchdogSeconds: Double,
    expiry: CLIFailure,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(watchdogSeconds * 1_000_000_000))
            client.close()
            throw expiry
        }
        do {
            guard let first = try await group.next() else { throw expiry }
            group.cancelAll()
            return first
        } catch {
            group.cancelAll()
            throw error
        }
    }
}

/// Idade humanizada de um intervalo em segundos ("agora", "42s", "3m10s", "2h05m", "3d4h").
func formatIdade(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded()))
    switch total {
    case 0:
        return "agora"
    case ..<60:
        return "\(total)s"
    case ..<3600:
        let m = total / 60, s = total % 60
        return s == 0 ? "\(m)m" : "\(m)m\(String(format: "%02d", s))s"
    case ..<86400:
        let h = total / 3600, m = (total % 3600) / 60
        return m == 0 ? "\(h)h" : "\(h)h\(String(format: "%02d", m))m"
    default:
        let d = total / 86400, h = (total % 86400) / 3600
        return h == 0 ? "\(d)d" : "\(d)d\(h)h"
    }
}
