import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import ColmeiaKit

/// Estado de um workspace no engine: registro (§5.1) + documento materializado (§7)
/// + arquivo de ops append-only. TODA mutação do documento passa por `applyProposal`
/// (regra §7.1: não existe mutação fora de `doc.apply`).
final class WorkspaceState {
    let paths: ColmeiaPaths
    var workspace: Workspace
    var aberto = false

    private(set) var nodes: [ULID: Node] = [:]
    private(set) var nodeOrder: [ULID] = []
    private(set) var connections: [ULID: Connection] = [:]
    private(set) var connectionOrder: [ULID] = []
    private(set) var seq: UInt64 = 0

    private var opsFD: Int32 = -1
    private var opsSinceSnapshot = 0
    /// Snapshot a cada N ops (§7.4, DEVERIA ser ≤ 500).
    private let snapshotEvery: Int
    /// Preenchido no load se houve quarentena (§22.3) — vira engine.warning na abertura.
    var corruptionNotice: String?

    func health() -> WorkspaceHealth {
        let fm = FileManager.default
        let documentURL = paths.documentFile(workspace.id)
        let quarantineURL = documentURL.appendingPathExtension("quarantine")
        let recoverable = corruptionNotice != nil
        return WorkspaceHealth(
            workspaceID: workspace.id,
            state: recoverable ? .recoverable : .open,
            message: corruptionNotice,
            snapshotAvailable: fm.fileExists(atPath: paths.documentSnapshotFile(workspace.id).path),
            journalAvailable: fm.fileExists(atPath: documentURL.path),
            quarantineAvailable: fm.fileExists(atPath: quarantineURL.path))
    }

    init(paths: ColmeiaPaths, workspace: Workspace, snapshotEveryOps: Int = 500) throws {
        self.paths = paths
        self.workspace = workspace
        self.snapshotEvery = min(max(1, snapshotEveryOps), 500)
        try paths.ensureWorkspaceLayout(workspace.id)
        try load()
        opsFD = open(paths.documentFile(workspace.id).path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard opsFD >= 0 else { throw EngineFailure.io("open document.jsonl", errno) }
    }

    deinit {
        if opsFD >= 0 { close(opsFD) }
    }

    // MARK: - Carga (§24.7)

    private func load() throws {
        let snapshotURL = paths.documentSnapshotFile(workspace.id)
        if FileManager.default.fileExists(atPath: snapshotURL.path) {
            do {
                let snapshot = try AtomicJSON.read(DocumentSnapshot.self, from: snapshotURL)
                guard snapshot.workspaceID == workspace.id else {
                    throw EngineFailure.io("snapshot de outro workspace", EINVAL)
                }
                seq = snapshot.seq
                for node in snapshot.nodes {
                    nodes[node.id] = node
                    nodeOrder.append(node.id)
                }
                for connection in snapshot.connections {
                    connections[connection.id] = connection
                    connectionOrder.append(connection.id)
                }
            } catch {
                // Conserva o arquivo para auditoria e reconstrói pelo JSONL sozinho.
                // Não o apagamos: uma ferramenta de recuperação ainda pode inspecioná-lo.
                corruptionNotice = "document.snapshot.json ilegível; reconstruído de document.jsonl"
            }
        }
        let docURL = paths.documentFile(workspace.id)
        guard let raw = try? Data(contentsOf: docURL) else { return }
        var goodBytes = 0
        var cursor = raw.startIndex
        var corrupted = false
        while cursor < raw.endIndex {
            let lineEnd = raw[cursor...].firstIndex(of: 0x0A) ?? raw.endIndex
            let line = raw[cursor..<lineEnd]
            let nextCursor = lineEnd < raw.endIndex ? raw.index(after: lineEnd) : raw.endIndex
            if line.isEmpty {
                cursor = nextCursor
                goodBytes = raw.distance(from: raw.startIndex, to: nextCursor)
                continue
            }
            guard let op = try? SocketFraming.decodeLine(DocOp.self, from: Data(line)),
                  let opSeq = op.seq
            else {
                corrupted = true
                break
            }
            if opSeq <= seq {
                // anterior ao snapshot — já materializado
                cursor = nextCursor
                goodBytes = raw.distance(from: raw.startIndex, to: nextCursor)
                continue
            }
            guard opSeq == seq + 1 else {
                corrupted = true // buraco de seq (§8.1 por analogia; §22.3)
                break
            }
            materialize(op)
            seq = opSeq
            cursor = nextCursor
            goodBytes = raw.distance(from: raw.startIndex, to: nextCursor)
        }
        if corrupted {
            let rest = raw[raw.index(raw.startIndex, offsetBy: goodBytes)...]
            let quarantineURL = docURL.appendingPathExtension("quarantine")
            let qfd = open(quarantineURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
            if qfd >= 0 {
                defer { close(qfd) }
                do {
                    try AtomicFile.writeAll(Data(rest), to: qfd, operation: "quarentena document.jsonl")
                    guard fsync(qfd) == 0 else { throw EngineFailure.io("fsync quarantine", errno) }
                    try AtomicFile.replace(Data(raw.prefix(goodBytes)), at: docURL)
                } catch {
                    // Se a quarentena não pôde ser gravada, preservar o original é
                    // mais seguro que truncá-lo; o warning continua visível.
                }
            }
            corruptionNotice =
                "document.jsonl com ops ilegíveis após seq \(seq); \(rest.count) bytes em quarentena"
        }
    }

    // MARK: - Aplicação de ops (§7.1)

    /// Valida, computa `anterior` (§7.3), atribui `seq`, persiste e materializa.
    /// `liveNodeIDs`: TerminalNodes com sessão viva — bloqueia `node.delete` (§7.2).
    func applyProposal(_ proposal: DocOp, liveNodeIDs: Set<ULID>) throws -> DocOp {
        guard let applied = try applyBatch([proposal], liveNodeIDs: liveNodeIDs).first else {
            throw ProtocolError(name: .internal_error, message: "lote vazio inesperado")
        }
        return applied
    }

    /// §7.1 — valida o lote inteiro contra um estado provisório antes de tocar no
    /// arquivo real. Assim `delete conexão antiga + add conexão nova`, por exemplo,
    /// nunca deixa apenas o prefixo aplicado quando a segunda operação é inválida.
    /// A persistência usa um único append e trunca de volta ao offset inicial se a
    /// escrita falhar no meio.
    func applyBatch(_ proposals: [DocOp], liveNodeIDs: Set<ULID>) throws -> [DocOp] {
        guard !proposals.isEmpty else { return [] }

        let originalNodes = nodes
        let originalNodeOrder = nodeOrder
        let originalConnections = connections
        let originalConnectionOrder = connectionOrder
        let originalSeq = seq
        let originalWorkspace = workspace

        var prepared: [DocOp] = []
        do {
            for proposal in proposals {
                var op = proposal
                op.anterior = try validate(op, liveNodeIDs: liveNodeIDs)
                op.seq = seq + 1
                materialize(op)
                seq += 1
                prepared.append(op)
            }
        } catch {
            nodes = originalNodes
            nodeOrder = originalNodeOrder
            connections = originalConnections
            connectionOrder = originalConnectionOrder
            seq = originalSeq
            workspace = originalWorkspace
            throw error
        }

        // A passagem acima foi apenas validação. Restaurar e só então persistir.
        nodes = originalNodes
        nodeOrder = originalNodeOrder
        connections = originalConnections
        connectionOrder = originalConnectionOrder
        seq = originalSeq
        workspace = originalWorkspace

        var encoded = Data()
        for op in prepared {
            guard var line = try? SocketFraming.encodeLine(op) else {
                throw ProtocolError(name: .internal_error, message: "falha ao serializar lote de ops")
            }
            line.append(0x0A)
            encoded.append(line)
        }

        let initialOffset = lseek(opsFD, 0, SEEK_END)
        guard initialOffset >= 0 else {
            throw ProtocolError(name: .internal_error, message: "falha ao posicionar document.jsonl")
        }
        do {
            try AtomicFile.writeAll(encoded, to: opsFD, operation: "append document.jsonl")
        } catch let error as EngineFailure {
            // Melhor esforço de rollback do append parcial; o próximo boot ainda
            // possui quarentena/reparo caso o próprio truncate falhe.
            _ = ftruncate(opsFD, initialOffset)
            _ = lseek(opsFD, 0, SEEK_END)
            if case .io(_, let code) = error, code == ENOSPC || code == EDQUOT {
                throw ProtocolError(
                    name: .internal_error,
                    message: "disco cheio; engine em modo somente-leitura para novas sessões")
            }
            throw ProtocolError(name: .internal_error, message: "falha ao gravar document.jsonl")
        }

        for op in prepared { materialize(op) }
        seq = originalSeq + UInt64(prepared.count)
        workspace.atualizadoEm = Date()
        opsSinceSnapshot += prepared.count
        if opsSinceSnapshot >= snapshotEvery {
            // A rodada periódica já é o ponto seguro para compactar: snapshot
            // atômico primeiro, depois JSONL reescrito preservando a janela do dia.
            // Se I/O falhar, a op recém-appendada e o JSONL antigo permanecem.
            try? compactDocument()
        }
        return prepared
    }

    private func validate(_ op: DocOp, liveNodeIDs: Set<ULID>) throws -> JSONValue? {
        switch op.payload {
        case .nodeAdd(let payload):
            guard nodes[payload.node.id] == nil else {
                throw ProtocolError(name: .invalid_params, message: "nó \(payload.node.id) já existe")
            }
            if case .terminal(let terminal) = payload.node {
                try checarNomeUnico(terminal.nome, excluindo: terminal.id)
            }
            return nil
        case .nodeMove(let payload):
            guard let node = nodes[payload.id] else {
                throw ProtocolError(name: .node_not_found, message: "nó \(payload.id) não existe")
            }
            return try? JSONValue(encoding: ["posicao": node.posicao])
        case .nodeResize(let payload):
            guard let node = nodes[payload.id] else {
                throw ProtocolError(name: .node_not_found, message: "nó \(payload.id) não existe")
            }
            return try? JSONValue(encoding: ["tamanho": node.tamanho])
        case .nodeUpdate(let payload):
            guard let node = nodes[payload.id] else {
                // Distinção importante para o cliente: callbacks assíncronos de
                // webview/nota podem chegar depois de um `node.delete` remoto. A
                // UI só pode tornar esse update idempotente quando o engine afirma
                // inequivocamente que o alvo já não existe — outros invalid_params
                // continuam sendo erros visíveis.
                throw ProtocolError(name: .node_not_found, message: "nó \(payload.id) não existe")
            }
            let (merged, anterior) = try merge(node: node, campos: payload.campos)
            if case .terminal(let terminal) = merged {
                try checarNomeUnico(terminal.nome, excluindo: terminal.id)
            }
            return anterior
        case .nodeDelete(let payload):
            guard let node = nodes[payload.id] else {
                throw ProtocolError(name: .invalid_params, message: "nó \(payload.id) não existe")
            }
            if case .terminal = node, liveNodeIDs.contains(payload.id) {
                throw ProtocolError(
                    name: .session_already_running,
                    message: "nó tem sessão ativa; mate a sessão primeiro (§7.2)")
            }
            return try? JSONValue(encoding: ["node": node])
        case .connectionAdd(let payload):
            guard connections[payload.connection.id] == nil else {
                throw ProtocolError(name: .invalid_params, message: "conexão já existe")
            }
            guard nodes[payload.connection.de] != nil, nodes[payload.connection.para] != nil else {
                throw ProtocolError(name: .invalid_params, message: "conexão referencia nó inexistente")
            }
            return nil
        case .connectionDelete(let payload):
            guard let connection = connections[payload.id] else {
                throw ProtocolError(name: .invalid_params, message: "conexão \(payload.id) não existe")
            }
            return try? JSONValue(encoding: ["connection": connection])
        case .tracoAdd(let payload):
            guard case .desenho = nodes[payload.nodeID] else {
                throw ProtocolError(name: .invalid_params, message: "traco.add exige DesenhoNode existente")
            }
            return nil
        case .tracoDelete(let payload):
            guard case .desenho(let desenho)? = nodes[payload.nodeID],
                  let traco = desenho.tracos.first(where: { $0.id == payload.tracoID })
            else {
                throw ProtocolError(name: .invalid_params, message: "traço \(payload.tracoID) não existe")
            }
            return try? JSONValue(encoding: ["traco": traco])
        case .viewportSet:
            return try? JSONValue(encoding: ["viewport": workspace.viewport])
        case .workspaceRename(let payload):
            guard !payload.nome.isEmpty else {
                throw ProtocolError(name: .invalid_params, message: "nome vazio")
            }
            return .object(["nome": .string(workspace.nome)])
        }
    }

    private func checarNomeUnico(_ nome: String, excluindo: ULID) throws {
        let lower = nome.lowercased()
        for node in nodes.values {
            if case .terminal(let terminal) = node,
               terminal.id != excluindo, terminal.nome.lowercased() == lower {
                throw ProtocolError(
                    name: .duplicate_node_name,
                    message: "nome \"\(nome)\" já usado no workspace (§5.2.1)")
            }
        }
    }

    /// node.update: merge raso de `campos` sobre o JSON do nó; `id`/`tipo` são imutáveis.
    private func merge(node: Node, campos: JSONValue) throws -> (Node, JSONValue) {
        guard let updates = campos.objectValue else {
            throw ProtocolError(name: .invalid_params, message: "campos deve ser objeto")
        }
        guard updates["id"] == nil, updates["tipo"] == nil else {
            throw ProtocolError(name: .invalid_params, message: "id/tipo são imutáveis")
        }
        guard var object = (try? JSONValue(encoding: node))?.objectValue else {
            throw ProtocolError(name: .internal_error, message: "falha ao codificar nó")
        }
        var anterior: [String: JSONValue] = [:]
        for (key, value) in updates {
            anterior[key] = object[key] ?? .null
            object[key] = value
        }
        do {
            let merged = try JSONValue.object(object).decode(as: Node.self)
            return (merged, .object(["campos": .object(anterior)]))
        } catch {
            throw ProtocolError(name: .invalid_params, message: "campos inválidos para o nó: \(error)")
        }
    }

    /// Aplica sem validação — usado no replay do disco e após validar.
    private func materialize(_ op: DocOp) {
        switch op.payload {
        case .nodeAdd(let payload):
            if nodes[payload.node.id] == nil { nodeOrder.append(payload.node.id) }
            nodes[payload.node.id] = payload.node
        case .nodeMove(let payload):
            guard var node = nodes[payload.id] else { return }
            switch node {
            case .terminal(var terminal): terminal.posicao = payload.posicao; node = .terminal(terminal)
            case .nota(var nota): nota.posicao = payload.posicao; node = .nota(nota)
            case .desenho(var desenho): desenho.posicao = payload.posicao; node = .desenho(desenho)
            case .portal(var portal): portal.posicao = payload.posicao; node = .portal(portal)
            }
            nodes[payload.id] = node
        case .nodeResize(let payload):
            guard var node = nodes[payload.id] else { return }
            switch node {
            case .terminal(var terminal): terminal.tamanho = payload.tamanho; node = .terminal(terminal)
            case .nota(var nota): nota.tamanho = payload.tamanho; node = .nota(nota)
            case .desenho(var desenho): desenho.tamanho = payload.tamanho; node = .desenho(desenho)
            case .portal(var portal): portal.tamanho = payload.tamanho; node = .portal(portal)
            }
            nodes[payload.id] = node
        case .nodeUpdate(let payload):
            guard let node = nodes[payload.id], let merged = try? merge(node: node, campos: payload.campos).0
            else { return }
            nodes[payload.id] = merged
        case .nodeDelete(let payload):
            nodes.removeValue(forKey: payload.id)
            nodeOrder.removeAll { $0 == payload.id }
            let dangling = connections.values.filter { $0.de == payload.id || $0.para == payload.id }
            for connection in dangling {
                connections.removeValue(forKey: connection.id)
                connectionOrder.removeAll { $0 == connection.id }
            }
        case .connectionAdd(let payload):
            if connections[payload.connection.id] == nil { connectionOrder.append(payload.connection.id) }
            connections[payload.connection.id] = payload.connection
        case .connectionDelete(let payload):
            connections.removeValue(forKey: payload.id)
            connectionOrder.removeAll { $0 == payload.id }
        case .tracoAdd(let payload):
            guard case .desenho(var desenho)? = nodes[payload.nodeID] else { return }
            desenho.tracos.append(payload.traco)
            nodes[payload.nodeID] = .desenho(desenho)
        case .tracoDelete(let payload):
            guard case .desenho(var desenho)? = nodes[payload.nodeID] else { return }
            desenho.tracos.removeAll { $0.id == payload.tracoID }
            nodes[payload.nodeID] = .desenho(desenho)
        case .viewportSet(let payload):
            workspace.viewport = payload.viewport
        case .workspaceRename(let payload):
            workspace.nome = payload.nome
        }
    }

    // MARK: - Snapshot (§7.4) e consultas

    func snapshot() -> DocumentSnapshot {
        DocumentSnapshot(
            workspaceID: workspace.id,
            seq: seq,
            nodes: nodeOrder.compactMap { nodes[$0] },
            connections: connectionOrder.compactMap { connections[$0] },
            criadoEm: Date()
        )
    }

    func writeSnapshot() throws {
        try AtomicJSON.write(snapshot(), to: paths.documentSnapshotFile(workspace.id))
        opsSinceSnapshot = 0
    }

    /// §7.4: snapshot primeiro, depois troca atômica do JSONL. Retemos as ops do
    /// dia de trabalho corrente por padrão; elas são redundantes ao snapshot mas
    /// mantêm uma janela humana de histórico. Se houver crash em qualquer ponto,
    /// o par antigo ou snapshot novo + JSONL antigo ainda reconstrói o mesmo canvas.
    func compactDocument(now: Date = Date(), retainSince: Date? = nil) throws {
        if opsFD >= 0, fsync(opsFD) != 0 {
            StorageHealth.shared.recordWriteFailure(errno, operation: "fsync document.jsonl antes de compactar")
            throw EngineFailure.io("fsync document.jsonl", errno)
        }
        try writeSnapshot()
        let calendar = Calendar.current
        let cutoff = retainSince ?? calendar.startOfDay(for: now)
        let documentURL = paths.documentFile(workspace.id)
        let raw = (try? Data(contentsOf: documentURL)) ?? Data()
        var retained = Data()
        var cursor = raw.startIndex
        while cursor < raw.endIndex {
            guard let lineEnd = raw[cursor...].firstIndex(of: 0x0A) else { break }
            let line = raw[cursor..<lineEnd]
            let next = raw.index(after: lineEnd)
            if let op = try? SocketFraming.decodeLine(DocOp.self, from: Data(line)), op.ts >= cutoff {
                retained.append(raw[cursor..<next])
            }
            cursor = next
        }
        // A troca fecha o descritor antigo antes do rename; continuar escrevendo no
        // inode antigo após o rename perderia as ops novas na próxima abertura.
        if opsFD >= 0 { _ = close(opsFD); opsFD = -1 }
        do {
            try AtomicFile.replace(retained, at: documentURL)
            opsFD = open(documentURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
            guard opsFD >= 0 else { throw EngineFailure.io("reabrir document.jsonl", errno) }
        } catch {
            if opsFD < 0 {
                opsFD = open(documentURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
            }
            throw error
        }
    }

    func saveWorkspace() throws {
        try AtomicJSON.write(workspace, to: paths.workspaceFile(workspace.id))
    }

    /// `doc.history {desde_seq, ate_seq?}` — leitura direta do arquivo de ops.
    func history(desdeSeq: UInt64, ateSeq: UInt64?) -> [DocOp] {
        guard let raw = try? Data(contentsOf: paths.documentFile(workspace.id)) else { return [] }
        var ops: [DocOp] = []
        var cursor = raw.startIndex
        while cursor < raw.endIndex {
            let lineEnd = raw[cursor...].firstIndex(of: 0x0A) ?? raw.endIndex
            let line = raw[cursor..<lineEnd]
            cursor = lineEnd < raw.endIndex ? raw.index(after: lineEnd) : raw.endIndex
            guard !line.isEmpty,
                  let op = try? SocketFraming.decodeLine(DocOp.self, from: Data(line)),
                  let opSeq = op.seq
            else { continue }
            if opSeq >= desdeSeq, ateSeq.map({ opSeq <= $0 }) ?? true {
                ops.append(op)
            }
        }
        return ops
    }

    func terminalNode(_ id: ULID) -> TerminalNode? {
        if case .terminal(let terminal)? = nodes[id] { return terminal }
        return nil
    }

    func terminalPorNome(_ nome: String) -> TerminalNode? {
        let lower = nome.lowercased()
        for node in nodes.values {
            if case .terminal(let terminal) = node, terminal.nome.lowercased() == lower {
                return terminal
            }
        }
        return nil
    }
}
