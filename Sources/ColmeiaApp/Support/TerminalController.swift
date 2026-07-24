import Foundation
import AppKit
import SwiftTerm
import ColmeiaKit

/// Subtipo próprio para o hitTest do canvas distinguir nossos emuladores.
/// keyDown do SwiftTerm não é `open` — o Esc duplo (Apêndice B) é interceptado
/// por um monitor local de eventos no CanvasView.
final class ColmeiaTerminalView: TerminalView {}

/// Um por TerminalNode. Dono do NSView do emulador (retido mesmo com o nó fora do
/// viewport — §18.2 manda parar de renderizar, não perder estado) e da ponte
/// attach/input/resize com o engine. `lastSeq` garante re-attach sem buraco/duplicata (§8.4).
@MainActor
final class TerminalController: NSObject, ObservableObject {
    let nodeID: ULID
    private unowned let connection: EngineConnection

    @Published private(set) var session: Session?
    @Published private(set) var estado: SessionEstado?
    @Published private(set) var motivoEstado: String?
    @Published private(set) var ultimaLinha: String = ""

    private(set) lazy var terminalView: ColmeiaTerminalView = makeTerminalView()
    private var lastSeq: UInt64 = 0
    private var resizeTask: Task<Void, Never>?
    private var pendingResize: (cols: Int, rows: Int)?
    /// Encadeia `session.input` para teclas não chegarem fora de ordem ao PTY.
    private var inputChain: Task<Void, Never>?
    /// Um attach ativo por sessão (§8.4) — chamadas concorrentes aguardam o mesmo.
    private var attachTask: Task<Void, Never>?
    /// Output vivo que chega ENQUANTO o replay está em voo é adiado e emendado
    /// depois, em ordem de seq — nunca alimentado antes do replay (§8.4).
    private var replayEmVoo = false
    private var vivoAdiado: [SessionOutputTopicPayload] = []

    init(nodeID: ULID, connection: EngineConnection) {
        self.nodeID = nodeID
        self.connection = connection
        super.init()
    }

    var sessionID: ULID? { session?.id }
    var viva: Bool { estado?.isViva ?? false }

    // MARK: - Ciclo de vida da sessão

    func adopt(session: Session) {
        if self.session?.id != session.id {
            lastSeq = 0
        }
        self.session = session
        estado = session.estado
    }

    func updateEstado(_ novo: SessionEstado, motivo: String?) {
        estado = novo
        motivoEstado = motivo
        if var s = session {
            s.estado = novo
            session = s
        }
    }

    func start(workspaceID: ULID) async throws {
        // §9.1 — geometria inicial do cliente no session.start: o agente já nasce no
        // tamanho certo, sem redesenho por resize logo após o launch.
        let terminal = terminalView.getTerminal()
        let cols = terminal.cols
        let rows = terminal.rows
        let result = try await connection.call(
            .sessionStart,
            params: SessionStartParams(workspaceID: workspaceID, nodeID: nodeID, cols: cols, rows: rows),
            expecting: SessionResult.self
        )
        lastSeq = 0
        adopt(session: result.session)
        await attach()
        // Só empurra geometria se a view mudou desde o start (o engine deduplica
        // resizes idênticos de qualquer forma).
        let atual = terminalView.getTerminal()
        if result.session.cols != atual.cols || result.session.rows != atual.rows {
            pushCurrentGeometry()
        }
    }

    /// Replay desde `lastSeq + 1` emendado no vivo (§8.4); idempotente por `seq` e
    /// single-flight: um segundo attach concorrente aguarda o que já está em voo.
    func attach() async {
        if let emVoo = attachTask {
            await emVoo.value
            return
        }
        let task = Task { await performAttach() }
        attachTask = task
        await task.value
        attachTask = nil
    }

    private func performAttach() async {
        guard let sessionID = session?.id else { return }
        replayEmVoo = true
        vivoAdiado.removeAll()
        connection.registerOutputHandler(session: sessionID) { [weak self] payload in
            guard let self else { return }
            if self.replayEmVoo {
                self.vivoAdiado.append(payload) // emenda exata: vivo só DEPOIS do replay
            } else {
                self.ingest(seq: payload.seq, dataB64: payload.dataB64)
            }
        }
        do {
            let result = try await connection.call(
                .sessionAttach,
                params: SessionAttachParams(sessionID: sessionID, desdeSeq: lastSeq == 0 ? nil : lastSeq + 1),
                expecting: SessionAttachResult.self
            )
            adopt(session: result.session)
            feedReplay(result.replay)
        } catch {
            // Sessão pode ter morrido entre list e attach; o estado chega por session.state.
        }
        replayEmVoo = false
        for payload in vivoAdiado.sorted(by: { $0.seq < $1.seq }) {
            ingest(seq: payload.seq, dataB64: payload.dataB64)
        }
        vivoAdiado.removeAll()
    }

    /// Replay reproduzindo a geometria do journal (§8.2): cada `resize` é aplicado ao
    /// emulador na ordem; o output ENTRE resizes vai num feed só (journals grandes não
    /// podem virar milhares de passadas no main actor durante o launch, §21.1).
    private func feedReplay(_ events: [Event]) {
        var ultimoOutput = Data()
        for acao in TerminalReplay.plan(events: events, lastSeq: &lastSeq) {
            switch acao {
            case .resize(let cols, let rows):
                terminalView.resize(cols: cols, rows: rows)
            case .feed(let data):
                terminalView.feed(byteArray: [UInt8](data)[...])
                ultimoOutput = data
            }
        }
        guard !ultimoOutput.isEmpty else { return }
        refreshUltimaLinha(Data(ultimoOutput.suffix(4096)))
    }

    func detach() {
        if let sessionID = session?.id {
            connection.unregisterOutputHandler(session: sessionID)
        }
    }

    /// Reconstrói o "último frame" de uma sessão encerrada/morta ao reabrir a UI
    /// (§18.3) — `session.replay` funciona para sessões encerradas (§6.4).
    func restoreDeadFrame() async {
        guard let sessionID = session?.id, lastSeq == 0 else { return }
        guard let result = try? await connection.call(
            .sessionReplay,
            params: SessionReplayParams(sessionID: sessionID),
            expecting: SessionReplayResult.self
        ) else { return }
        feedReplay(result.events)
    }

    func kill(sinal: KillSinal = .term) async {
        guard let sessionID = session?.id else { return }
        _ = try? await connection.call(.sessionKill, params: SessionKillParams(sessionID: sessionID, sinal: sinal))
    }

    private func ingest(seq: UInt64, dataB64: String) {
        guard seq > lastSeq else { return }
        lastSeq = seq
        guard let data = Data(base64Encoded: dataB64) else { return }
        terminalView.feed(byteArray: [UInt8](data)[...])
        refreshUltimaLinha(data)
    }

    private func refreshUltimaLinha(_ data: Data) {
        if let text = String(data: data, encoding: .utf8) {
            let lines = text.split(whereSeparator: \.isNewline)
            if let last = lines.last {
                let clean = Self.stripEscapes(String(last)).trimmingCharacters(in: .whitespaces)
                if !clean.isEmpty { ultimaLinha = clean }
            }
        }
    }

    private static func stripEscapes(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[a-zA-Z]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\u{1B}\\][^\u{07}]*\u{07}", with: "", options: .regularExpression)
    }

    // MARK: - Input / resize

    func sendInput(_ bytes: ArraySlice<UInt8>) {
        guard let sessionID = session?.id else { return }
        let b64 = Data(bytes).base64EncodedString()
        let previous = inputChain
        let connection = self.connection
        inputChain = Task {
            await previous?.value
            _ = try? await connection.call(.sessionInput, params: SessionInputParams(sessionID: sessionID, dataB64: b64))
        }
    }

    /// Throttle ~10/s (§9.3).
    func requestResize(cols: Int, rows: Int) {
        pendingResize = (cols, rows)
        guard resizeTask == nil else { return }
        resizeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard let self else { return }
            self.resizeTask = nil
            guard let sessionID = self.session?.id, let geo = self.pendingResize else { return }
            self.pendingResize = nil
            _ = try? await self.connection.call(
                .sessionResize,
                params: SessionResizeParams(sessionID: sessionID, cols: geo.cols, rows: geo.rows)
            )
        }
    }

    func pushCurrentGeometry() {
        let terminal = terminalView.getTerminal()
        requestResize(cols: terminal.cols, rows: terminal.rows)
    }

    // MARK: - View

    private func makeTerminalView() -> ColmeiaTerminalView {
        let view = ColmeiaTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 380))
        view.terminalDelegate = self
        return view
    }
}

// SwiftTerm chama o delegate na main thread; `assumeIsolated` evita o hop de Task
// (que poderia reordenar teclas).
extension TerminalController: TerminalViewDelegate {
    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let bytes = [UInt8](data)
        MainActor.assumeIsolated {
            sendInput(bytes[...])
        }
    }

    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        MainActor.assumeIsolated {
            requestResize(cols: newCols, rows: newRows)
        }
    }

    nonisolated func setTerminalTitle(source: TerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func scrolled(source: TerminalView, position: Double) {}
    nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
