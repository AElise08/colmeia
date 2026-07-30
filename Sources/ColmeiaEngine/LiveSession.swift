import Foundation
import ColmeiaKit

/// Mensagem aguardando o destino ficar `esperando_humano`/`ociosa` (§14.2).
struct QueuedMessage {
    let id: ULID
    let deNode: ULID
    let texto: String
    let enqueuedAt: Date
    /// Aviso do engine (consciência de conexão): entra como evento `system` no journal
    /// e input com author `sistema`, sem `message.delivered` nem auto-conexão. Usa a
    /// MESMA fila FIFO — nunca atropela um turno (§14.2).
    var sistema = false
    var systemName = "conexao"
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
        // OSC 0/2 pode atravessar chunks; reexaminar o tail completo evita assumir
        // framing do PTY e deixa o título disponível aos adapters (§9.2/§10.1).
        if let title = TerminalControlSequences.lastOSCTitle(in: recent) {
            tituloOSC = title
        }
    }

    func contexto(ultimoChunk: Data) -> AdapterContexto {
        let contexto = AdapterContexto(
            ultimoChunk: ultimoChunk,
            bufferRecente: TerminalText.decodeLossy(recent),
            silencioSeg: silencioSeg,
            tituloOSC: tituloOSC,
            belRecente: belRecente
        )
        // BEL é edge-triggered: um único beep é uma pista, não deve transformar
        // todos os chunks seguintes em "esperando humano" indefinidamente.
        belRecente = false
        return contexto
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

/// Parser deliberadamente mínimo para OSC 0/2: título em `ESC ] 0;… BEL` ou
/// `ESC ] 2;… ESC \\`. Não interpreta outras sequências VT; bytes inválidos são
/// decodificados lossy, como o restante das heurísticas.
enum TerminalControlSequences {
    static func lastOSCTitle(in data: Data) -> String? {
        let bytes = [UInt8](data)
        var result: String?
        var index = 0
        while index + 3 < bytes.count {
            guard bytes[index] == 0x1B, bytes[index + 1] == 0x5D,
                  (bytes[index + 2] == 0x30 || bytes[index + 2] == 0x32),
                  bytes[index + 3] == 0x3B
            else { index += 1; continue }
            let start = index + 4
            var end = start
            var foundTerminator = false
            while end < bytes.count {
                if bytes[end] == 0x07 {
                    foundTerminator = true
                    break
                }
                if end + 1 < bytes.count, bytes[end] == 0x1B, bytes[end + 1] == 0x5C {
                    foundTerminator = true
                    break
                }
                end += 1
            }
            if foundTerminator {
                let title = String(decoding: bytes[start..<end], as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty { result = String(title.prefix(512)) }
            }
            index = max(end + 1, index + 1)
        }
        return result
    }
}
