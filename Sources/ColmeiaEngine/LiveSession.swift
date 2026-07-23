import Foundation
import ColmeiaKit

/// Mensagem aguardando o destino ficar `esperando_humano`/`ociosa` (§14.2).
struct QueuedMessage {
    let id: ULID
    let deNode: ULID
    let texto: String
    let enqueuedAt: Date
}

/// `colmeia ask` bloqueante: resposta = output do destino desde a injeção até a
/// próxima transição para esperando_humano/ociosa (§14.1.5).
final class BlockingWait {
    let messageID: ULID
    let senderNode: ULID
    let destNode: ULID
    let destSession: ULID
    let deadline: Date
    var delivered = false
    var sawOutput = false
    var accum = Data()
    let respond: (JSONValue) -> Void

    init(
        messageID: ULID, senderNode: ULID, destNode: ULID, destSession: ULID,
        deadline: Date, respond: @escaping (JSONValue) -> Void
    ) {
        self.messageID = messageID
        self.senderNode = senderNode
        self.destNode = destNode
        self.destSession = destSession
        self.deadline = deadline
        self.respond = respond
    }
}

/// Runtime de uma sessão viva (§5.4 + §9). O DTO do protocolo sai de `dto()` —
/// o handle de PTY nunca cruza o socket.
final class LiveSession {
    let id: ULID
    let workspaceID: ULID
    let nodeID: ULID
    var nodeNome: String
    let adapterID: String
    let monitorar: Bool
    let journal: SessionJournal

    var pty: PTYHandle?
    var estado: SessionEstado = .iniciando
    var estadoDesde = Date()
    let iniciadaEm = Date()
    var encerradaEm: Date?
    var cols: Int
    var rows: Int

    /// §10.5 — heurística que lançou exceção põe a sessão em modo degradado.
    var degraded = false
    var lastOutputAt = Date()
    var lastActivityAt = Date()
    /// Tail cru do output (heurísticas §10.1); cap 16 KiB.
    var recent = Data()
    var belRecente = false
    var tituloOSC: String?

    var pendingApprovalID: ULID?
    /// Houve input de terminal desde a criação da Approval → `resolvida_no_terminal` (§12.1b).
    var inputSincePendingApproval = false

    /// Fila FIFO de mensagens por destino (§14.2); limite imposto pelo Engine.
    var fila: [QueuedMessage] = []
    /// SIGTERM enviado; sem saída até aqui → SIGKILL (§9.1.5).
    var killDeadline: Date?
    var exited = false

    init(
        id: ULID, workspaceID: ULID, nodeID: ULID, nodeNome: String,
        adapterID: String, monitorar: Bool, journal: SessionJournal,
        cols: Int, rows: Int
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.nodeID = nodeID
        self.nodeNome = nodeNome
        self.adapterID = adapterID
        self.monitorar = monitorar
        self.journal = journal
        self.cols = cols
        self.rows = rows
    }

    var silencioSeg: Double { Date().timeIntervalSince(lastOutputAt) }

    func appendRecent(_ chunk: Data) {
        recent.append(chunk)
        if recent.count > 16 * 1024 {
            recent.removeFirst(recent.count - 16 * 1024)
        }
        if chunk.contains(0x07) { belRecente = true }
    }

    func contexto(ultimoChunk: Data) -> AdapterContexto {
        AdapterContexto(
            ultimoChunk: ultimoChunk,
            bufferRecente: TerminalText.decodeLossy(recent),
            silencioSeg: silencioSeg,
            tituloOSC: tituloOSC,
            belRecente: belRecente
        )
    }

    func dto() -> Session {
        Session(
            id: id,
            workspaceID: workspaceID,
            nodeID: nodeID,
            adapter: adapterID,
            estado: estado,
            pid: pty.map { Int32($0.pid) },
            journal: journal.url.path,
            iniciadaEm: iniciadaEm,
            encerradaEm: encerradaEm,
            cols: cols,
            rows: rows,
            estadoDesde: estadoDesde
        )
    }
}
