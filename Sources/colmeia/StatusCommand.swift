import Foundation
import ColmeiaKit

/// `colmeia status [--json] [--workspace <id>]` (§13.4) — como um Lead "enxerga a sala":
/// nós terminais do workspace com nome, papel, adapter, estado e idade do estado,
/// mais a topologia de conexões (quem pode delegar para quem) e qual nó é "você"
/// quando chamado de dentro de uma sessão gerenciada.
enum StatusCommand {
    static let usage = "uso: colmeia status [--json] [--workspace <workspace-id>]"

    struct Row: Codable {
        var nodeID: ULID
        var nome: String
        var papel: String?
        var adapter: String
        var estado: String?
        var estadoHaSeg: Double?
        var sessionID: ULID?
        /// true quando o nó é o chamador (COLMEIA_NODE_ID da sessão gerenciada).
        var voce: Bool

        enum CodingKeys: String, CodingKey {
            case nome, papel, adapter, estado, voce
            case nodeID = "node_id"
            case estadoHaSeg = "estado_ha_seg"
            case sessionID = "session_id"
        }
    }

    /// Conexão do canvas com as pontas resolvidas para endereços úteis: nome do
    /// terminal (o que `colmeia ask` aceita) ou o tipo do nó (nota/desenho/portal).
    struct ConnRow: Codable {
        var id: ULID
        var de: String
        var para: String
        var semantica: String
    }

    struct Report: Codable {
        var workspaceID: ULID
        var nos: [Row]
        var conexoes: [ConnRow]
        var notas: Int
        var desenhos: Int
        var portais: Int

        enum CodingKeys: String, CodingKey {
            case nos, conexoes, notas, desenhos, portais
            case workspaceID = "workspace_id"
        }
    }

    static func run(_ args: [String], context: CLIContext = CLIContext()) async -> Int32 {
        do {
            try await execute(args, context: context)
            return CLIExit.ok
        } catch let failure as CLIFailure {
            printErr(failure.message)
            return failure.code
        } catch {
            printErr("colmeia status: \(error)")
            return CLIExit.contexto
        }
    }

    private static func execute(_ args: [String], context: CLIContext) async throws {
        var json = false
        var workspaceFlag: String?
        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--json":
                json = true
            case "--workspace":
                index += 1
                guard index < args.count else {
                    throw CLIFailure(code: CLIExit.uso, message: "--workspace exige um id\n\(usage)")
                }
                workspaceFlag = args[index]
            case let flag where flag.hasPrefix("--workspace="):
                workspaceFlag = String(flag.dropFirst("--workspace=".count))
            default:
                throw CLIFailure(code: CLIExit.uso, message: "argumento desconhecido: \(arg)\n\(usage)")
            }
            index += 1
        }

        let client = try await connectEngine(context)
        defer { client.close() }

        let workspaceID = try await resolveWorkspace(flag: workspaceFlag, context: context, client: client)

        let snapshot: DocSnapshotResult
        let sessionsRaw: JSONValue
        do {
            snapshot = try await raced(client) {
                try await client.call(
                    .docSnapshot,
                    params: DocSnapshotParams(workspaceID: workspaceID),
                    expecting: DocSnapshotResult.self
                )
            }
            sessionsRaw = try await raced(client) {
                try await client.call(.sessionList, params: SessionListParams(workspaceID: workspaceID))
            }
        } catch {
            throw mapError(error)
        }

        let sessions = parseSessions(sessionsRaw)
        let now = Date()
        var rows: [Row] = []
        var notas = 0
        var desenhos = 0
        var portais = 0

        for node in snapshot.documentSnapshot.nodes {
            switch node {
            case .nota:
                notas += 1
            case .desenho:
                desenhos += 1
            case .portal:
                portais += 1
            case .terminal(let terminal):
                let vivaOuRecente = pickSession(for: terminal, in: sessions)
                let estadoDesde = vivaOuRecente.map { entry -> Date in
                    entry.estadoDesde
                        ?? (entry.session.estado.isViva ? entry.session.iniciadaEm
                            : entry.session.encerradaEm ?? entry.session.iniciadaEm)
                }
                rows.append(Row(
                    nodeID: terminal.id,
                    nome: terminal.nome,
                    papel: terminal.papel,
                    adapter: terminal.adapter,
                    estado: vivaOuRecente?.session.estado.rawValue,
                    estadoHaSeg: estadoDesde.map { max(0, now.timeIntervalSince($0)) },
                    sessionID: vivaOuRecente?.session.id,
                    voce: terminal.id == context.nodeID
                ))
            }
        }
        rows.sort { $0.nome.lowercased() < $1.nome.lowercased() }

        let conexoes = snapshot.documentSnapshot.connections.map { connection in
            ConnRow(
                id: connection.id,
                de: endereco(connection.de, in: snapshot.documentSnapshot),
                para: endereco(connection.para, in: snapshot.documentSnapshot),
                semantica: connection.semantica.rawValue
            )
        }

        let report = Report(
            workspaceID: workspaceID, nos: rows, conexoes: conexoes,
            notas: notas, desenhos: desenhos, portais: portais)
        if json {
            let encoder = ColmeiaJSON.encoder()
            encoder.outputFormatting.insert(.prettyPrinted)
            let data = try encoder.encode(report)
            print(String(decoding: data, as: UTF8.self))
        } else {
            printTable(report)
        }
    }

    // MARK: - Workspace

    /// Precedência: --workspace > COLMEIA_WORKSPACE_ID > único workspace do engine.
    private static func resolveWorkspace(
        flag: String?,
        context: CLIContext,
        client: SocketClient
    ) async throws -> ULID {
        if let flag {
            guard let id = ULID(flag) else {
                throw CLIFailure(code: CLIExit.uso, message: "workspace id inválido: \(flag)")
            }
            return id
        }
        if let id = context.workspaceID {
            return id
        }
        let list: WorkspaceListResult
        do {
            list = try await raced(client) {
                try await client.call(.workspaceList, expecting: WorkspaceListResult.self)
            }
        } catch {
            throw mapError(error)
        }
        switch list.count {
        case 0:
            throw CLIFailure(code: CLIExit.contexto, message: "nenhum workspace no engine")
        case 1:
            return list[0].id
        default:
            let opcoes = list.map { "  \($0.id.string)  \($0.nome)" }.joined(separator: "\n")
            throw CLIFailure(
                code: CLIExit.contexto,
                message: "vários workspaces — escolha com --workspace <id>:\n\(opcoes)"
            )
        }
    }

    // MARK: - Sessões

    private struct SessionEntry {
        var session: Session
        /// Campo de extensão do engine com o instante da última transição (§11);
        /// sem ele a idade cai para iniciada_em/encerrada_em.
        var estadoDesde: Date?
    }

    private static func parseSessions(_ raw: JSONValue) -> [SessionEntry] {
        guard let items = raw.arrayValue else { return [] }
        return items.compactMap { item in
            guard let session = try? item.decode(as: Session.self) else { return nil }
            let desde = item["estado_desde"]?.stringValue.flatMap(ColmeiaJSON.date(from:))
            return SessionEntry(session: session, estadoDesde: desde)
        }
    }

    private static func pickSession(for node: TerminalNode, in sessions: [SessionEntry]) -> SessionEntry? {
        let doNode = sessions.filter { $0.session.nodeID == node.id }
        if let atual = doNode.first(where: { $0.session.id == node.sessionID }) {
            return atual
        }
        let vivas = doNode.filter { $0.session.estado.isViva }
        return (vivas.isEmpty ? doNode : vivas).max { $0.session.iniciadaEm < $1.session.iniciadaEm }
    }

    // MARK: - Saída

    /// Endereço legível de uma ponta de conexão: nome do terminal ou tipo do nó.
    private static func endereco(_ nodeID: ULID, in snapshot: DocumentSnapshot) -> String {
        guard let node = snapshot.nodes.first(where: { $0.id == nodeID }) else {
            return nodeID.string
        }
        if case .terminal(let terminal) = node { return terminal.nome }
        return node.tipo.rawValue
    }

    private static func printTable(_ report: Report) {
        if report.nos.isEmpty {
            print("nenhum nó terminal no workspace \(report.workspaceID.string)")
        } else {
            let header = ["NOME", "PAPEL", "ADAPTER", "ESTADO", "HÁ"]
            var linhas: [[String]] = [header]
            for row in report.nos {
                linhas.append([
                    row.voce ? "\(row.nome) (você)" : row.nome,
                    row.papel ?? "—",
                    row.adapter,
                    row.estado ?? "sem sessão",
                    row.estadoHaSeg.map(formatIdade) ?? "—",
                ])
            }
            let larguras = (0..<header.count).map { coluna in
                linhas.map { $0[coluna].count }.max() ?? 0
            }
            for linha in linhas {
                let celulas = linha.enumerated().map { indice, valor in
                    valor + String(repeating: " ", count: max(0, larguras[indice] - valor.count))
                }
                print(celulas.joined(separator: "  ").trimmingCharacters(in: .whitespaces))
            }
        }
        if !report.conexoes.isEmpty {
            print("conexões:")
            for conexao in report.conexoes {
                let seta = conexao.semantica == ConnectionSemantica.conversa.rawValue ? "⇄" : "→"
                print("  \(conexao.de) \(seta) \(conexao.para)  (\(conexao.semantica))")
            }
        }
        if report.notas > 0 || report.desenhos > 0 || report.portais > 0 {
            print("(\(report.notas) nota(s), \(report.desenhos) desenho(s), \(report.portais) portal(is))")
        }
    }

    private static func raced<T: Sendable>(
        _ client: SocketClient,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await racedCall(
            client: client,
            watchdogSeconds: 30,
            expiry: CLIFailure(code: CLIExit.contexto, message: "engine não respondeu em 30s"),
            operation
        )
    }

    private static func mapError(_ error: Error) -> CLIFailure {
        if let failure = error as? CLIFailure { return failure }
        if let proto = error as? ProtocolError {
            let code = proto.known == .workspace_not_found ? CLIExit.contexto : CLIExit.destinoInexistente
            return CLIFailure(code: code, message: "colmeia status: \(proto)")
        }
        return CLIFailure(code: CLIExit.contexto, message: "colmeia status: \(error)")
    }
}
