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
        let result = try await connection.call(
            .sessionStart,
            params: SessionStartParams(workspaceID: workspaceID, nodeID: nodeID),
            expecting: SessionResult.self
        )
        lastSeq = 0
        adopt(session: result.session)
        await attach()
        pushCurrentGeometry()
    }

    /// Replay desde `lastSeq + 1` emendado no vivo (§8.4); idempotente por `seq`.
    func attach() async {
        guard let sessionID = session?.id else { return }
        connection.registerOutputHandler(session: sessionID) { [weak self] payload in
            self?.ingest(seq: payload.seq, dataB64: payload.dataB64)
        }
        do {
            let result = try await connection.call(
                .sessionAttach,
                params: SessionAttachParams(sessionID: sessionID, desdeSeq: lastSeq == 0 ? nil : lastSeq + 1),
                expecting: SessionAttachResult.self
            )
            adopt(session: result.session)
            for event in result.replay {
                if case .output(let payload) = event.payload {
                    ingest(seq: event.seq, dataB64: payload.dataB64)
                } else {
                    lastSeq = max(lastSeq, event.seq)
                }
            }
        } catch {
            // Sessão pode ter morrido entre list e attach; o estado chega por session.state.
        }
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
        for event in result.events {
            if case .output(let payload) = event.payload {
                ingest(seq: event.seq, dataB64: payload.dataB64)
            }
        }
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
