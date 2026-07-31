import Foundation
import AppKit
import SwiftTerm
import ColmeiaKit

/// Subtipo próprio para o hitTest do canvas distinguir nossos emuladores.
/// keyDown do SwiftTerm não é `open` — o Esc duplo (Apêndice B) é interceptado
/// por um monitor local de eventos no CanvasView.
final class ColmeiaTerminalView: TerminalView {
    /// Chamado sempre que a view ganha janela/frame de layout real — a partir daí
    /// cols/rows do SwiftTerm refletem o espaço que a UI de fato desenha.
    var aoAssentarLayout: (() -> Void)?

    /// true quando o frame corrente veio de layout de verdade (view na janela,
    /// tamanho plausível) — condição para a geometria do SwiftTerm ser confiável.
    var layoutAssentado: Bool {
        window != nil && frame.width >= 80 && frame.height >= 40
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if layoutAssentado { aoAssentarLayout?() }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if layoutAssentado { aoAssentarLayout?() }
    }

    /// Re-deriva cols/rows do frame ATUAL pelo caminho do PRÓPRIO SwiftTerm
    /// (processSizeChange, que desconta o scroller) — usado depois que o replay
    /// aplica geometria histórica do journal, para a tela voltar à verdade do
    /// layout. Nunca calculamos colunas por fora.
    func rederivarGeometriaDoFrame() {
        guard layoutAssentado else { return }
        setFrameSize(frame.size)
    }
}

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
    /// Pequeno recorte legível para superfícies de acompanhamento. Não é replay
    /// nem log: só acompanha
    /// a saída que esta UI já recebeu, sem criar uma segunda fonte de verdade.
    @Published private(set) var linhasRecentes: [String] = []
    /// Respostas reais extraídas do histórico estruturado do Codex. Diferente de
    /// `linhasRecentes`, nunca contém repaint, ANSI, menus ou barras do TUI.
    @Published private(set) var structuredAssistantMessages: [String] = []

    private(set) lazy var terminalView: ColmeiaTerminalView = makeTerminalView()
    private var lastSeq: UInt64 = 0
    private var resizeTask: Task<Void, Never>?
    private var resizePendente = false
    /// Replay aplicando `resize` histórico do journal NÃO pode ecoar pro PTY —
    /// senão geometria velha atropela a atual (ping-pong emulador↔PTY).
    private var aplicandoReplay = false
    /// Continuations aguardando o primeiro layout real da view (§9.1 — o agente
    /// deve nascer já na largura certa, não na do frame placeholder).
    private var layoutWaiters: [CheckedContinuation<Void, Never>] = []
    /// Encadeia `session.input` para teclas não chegarem fora de ordem ao PTY.
    private var inputChain: Task<Void, Never>?
    private var structuredResponseTask: Task<Void, Never>?
    /// Dois cliques em "Lançar" (ou menu + atalho) não podem abrir duas
    /// `session.start` concorrentes para o mesmo nó. Além do erro ruidoso no
    /// engine, a segunda resposta poderia trocar o handler do primeiro attach.
    private var startTask: Task<Void, Error>?
    /// Um attach ativo por sessão (§8.4) — chamadas concorrentes aguardam o mesmo.
    private var attachTask: Task<Void, Never>?
    /// Output vivo que chega ENQUANTO o replay está em voo é adiado e emendado
    /// depois, em ordem de seq — nunca alimentado antes do replay (§8.4).
    private var replayEmVoo = false
    private var vivoAdiado: [SessionOutputTopicPayload] = []
    private var fontSize: CGFloat = TerminalAppearance.tamanhoFonte

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

    func start(workspaceID: ULID, floorID: ULID? = nil) async throws {
        if let emVoo = startTask {
            return try await emVoo.value
        }
        let task = Task { [weak self] () throws -> Void in
            guard let self else { throw CancellationError() }
            try await self.performStart(workspaceID: workspaceID, floorID: floorID)
        }
        startTask = task
        defer { startTask = nil }
        try await task.value
    }

    private func performStart(workspaceID: ULID, floorID: ULID?) async throws {
        // §9.1 — geometria inicial do cliente no session.start. Fonte única da
        // verdade: o PRÓPRIO SwiftTerm, DEPOIS do primeiro layout real — nunca
        // colunas calculadas por fora nem o frame placeholder da view lazy
        // (PTY mais largo que o emulador = caudas de wrap e linhas duplicadas).
        await esperarLayoutAssentar()
        let terminal = terminalView.getTerminal()
        let result = try await connection.call(
            .sessionStart,
            params: SessionStartParams(
                workspaceID: workspaceID, nodeID: nodeID, floorID: floorID,
                cols: terminal.cols, rows: terminal.rows),
            expecting: SessionResult.self
        )
        lastSeq = 0
        adopt(session: result.session)
        await attach()
        // attach → performAttach já re-deriva a geometria do frame e sincroniza o
        // PTY (o engine deduplica resize idêntico — sem SIGWINCH espúrio).
    }

    /// Aguarda o primeiro layout real da view (janela + frame de verdade) por até
    /// 800ms; se a view já assentou — ou nunca montar (nó fora do viewport) —
    /// segue com a geometria corrente do SwiftTerm, que é a última verdade conhecida.
    private func esperarLayoutAssentar() async {
        guard !terminalView.layoutAssentado else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            layoutWaiters.append(continuation)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 800_000_000)
                self?.layoutAssentou() // timeout: resolve quem sobrou (idempotente)
            }
        }
    }

    private func layoutAssentou() {
        guard !layoutWaiters.isEmpty else { return }
        let waiters = layoutWaiters
        layoutWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
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
        // O replay pode ter deixado o emulador na geometria HISTÓRICA do journal.
        // A tela vive no frame real: re-deriva cols/rows pelo caminho do próprio
        // SwiftTerm e sincroniza o PTY (no-op no engine se já forem idênticos).
        terminalView.rederivarGeometriaDoFrame()
        pushCurrentGeometry()
    }

    /// Replay reproduzindo a geometria do journal (§8.2): cada `resize` é aplicado ao
    /// emulador na ordem; o output ENTRE resizes vai num feed só (journals grandes não
    /// podem virar milhares de passadas no main actor durante o launch, §21.1).
    private func feedReplay(_ events: [Event]) {
        var ultimoOutput = Data()
        // `terminalView.resize` dispara o delegate `sizeChanged` — durante o replay
        // isso NÃO pode virar session.resize (ecoaria geometria velha do journal
        // de volta pro PTY vivo). O pós-replay re-sincroniza com o frame real.
        aplicandoReplay = true
        defer { aplicandoReplay = false }
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
        guard let session, lastSeq == 0 else { return }
        // Um frame morto é apenas uma prévia visual. Não precisamos transportar
        // o journal inteiro para a UI: sessões antigas podem ter dezenas de MB e
        // uma única resposta maior que o limite de transporte dispara backpressure
        // antes de o socket conseguir drená-la. O journal permanece completo no
        // Engine e pode ser consultado/reproduzido com limites explícitos.
        let frameReplayLimit = 128
        guard let result = try? await connection.call(
            .sessionReplay,
            params: SessionReplayParams(sessionID: session.id, limit: frameReplayLimit),
            expecting: SessionReplayResult.self
        ) else { return }
        terminalView.resize(cols: session.cols, rows: session.rows)
        feedReplay(result.events)
    }

    func kill(sinal: KillSinal = .term) async {
        guard let sessionID = session?.id else { return }
        _ = try? await connection.call(.sessionKill, params: SessionKillParams(sessionID: sessionID, sinal: sinal))
    }

    /// `session.kill` confirma apenas o sinal enviado; `node.delete` só é válido
    /// depois do evento state final. Esperar aqui preserva a ordem request-
    /// dependente sem adivinhar um tempo fixo de saída do PTY (§6.7/§9.1).
    func killAndWait(sinal: KillSinal = .term, timeout: TimeInterval = 3) async -> Bool {
        guard let sessionID = session?.id else { return true }
        do {
            _ = try await connection.call(
                .sessionKill,
                params: SessionKillParams(sessionID: sessionID, sinal: sinal)
            )
        } catch {
            return false
        }
        let deadline = Date().addingTimeInterval(timeout)
        while session?.id == sessionID && viva && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return session?.id != sessionID || !viva
    }

    /// PONTO ÚNICO de ingestão do vivo. O handler por sessão no EngineConnection é
    /// um dicionário (registrar de novo SUBSTITUI — nunca dois handlers pro mesmo
    /// nó após recriação) e o piso de `seq` do replay (§8.4) vale também aqui:
    /// entrega duplicada de `session.output` por qualquer caminho é descartada.
    private func ingest(seq: UInt64, dataB64: String) {
        guard seq > lastSeq else { return }
        lastSeq = seq
        guard let data = Data(base64Encoded: dataB64) else { return }
        terminalView.feed(byteArray: [UInt8](data)[...])
        refreshUltimaLinha(data)
    }

    private func refreshUltimaLinha(_ data: Data) {
        if let text = String(data: data, encoding: .utf8) {
            let lines = text.split(whereSeparator: { $0.isNewline })
                .compactMap { Self.linhaDeAtividade(String($0)) }
            guard !lines.isEmpty else { return }
            ultimaLinha = lines.last ?? ultimaLinha
            linhasRecentes.append(contentsOf: lines)
            if linhasRecentes.count > 12 { linhasRecentes.removeFirst(linhasRecentes.count - 12) }
        }
    }

    /// O Agent Chat é uma leitura de coordenação, não um emulador de terminal.
    /// Descarta fragmentos de repaint, barras de status e prompts internos que
    /// seriam úteis só no terminal completo — o Canvas continua exibindo tudo.
    private static func linhaDeAtividade(_ raw: String) -> String? {
        let line = stripEscapes(raw)
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.count >= 12 else { return nil }

        let lower = line.lowercased()
        let descartadas = [
            "use /skills to list available skills",
            "gpt-", "xhigh", "ctrl+c", "esc to", "tokens left",
        ]
        guard !descartadas.contains(where: { lower.contains($0) }) else { return nil }

        let letters = line.unicodeScalars.filter {
            CharacterSet.letters.contains($0)
        }.count
        let words = line.split(whereSeparator: { $0.isWhitespace })
        guard letters >= 8, words.count >= 3 else { return nil }
        return line
    }

    private static func stripEscapes(_ raw: String) -> String {
        // Terminal UIs use more than SGR colors: cursor movement, alternate
        // screen, bracketed paste, OSC titles and 8-bit CSI sequences. Regexes
        // that only remove ESC+[digits] leave fragments such as `40H` in the
        // Agent Chat. Parse the control stream and keep only human-readable text.
        var clean = String.UnicodeScalarView()
        let scalars = Array(raw.unicodeScalars)
        var index = 0

        func isCSIFinal(_ scalar: UnicodeScalar) -> Bool {
            scalar.value >= 0x40 && scalar.value <= 0x7E
        }

        while index < scalars.count {
            let scalar = scalars[index]
            if scalar.value == 0x1B { // ESC
                index += 1
                guard index < scalars.count else { break }
                let next = scalars[index]
                if next.value == 0x5B { // CSI: ESC [ ... final
                    index += 1
                    while index < scalars.count && !isCSIFinal(scalars[index]) { index += 1 }
                    if index < scalars.count { index += 1 }
                } else if next.value == 0x5D { // OSC: ESC ] ... BEL or ST
                    index += 1
                    while index < scalars.count {
                        if scalars[index].value == 0x07 { index += 1; break }
                        if scalars[index].value == 0x1B,
                           index + 1 < scalars.count,
                           scalars[index + 1].value == 0x5C {
                            index += 2
                            break
                        }
                        index += 1
                    }
                } else {
                    // Single-character escape (save/restore cursor, keypad,
                    // charset selection, etc.). It has no readable payload.
                    index += 1
                }
                continue
            }
            if scalar.value == 0x9B { // 8-bit CSI
                index += 1
                while index < scalars.count && !isCSIFinal(scalars[index]) { index += 1 }
                if index < scalars.count { index += 1 }
                continue
            }
            switch scalar.value {
            case 0x08: // backspace: emulate the visible effect for progress lines
                if !clean.isEmpty { clean.removeLast() }
            case 0x0D: // carriage return: ignore; the terminal renderer handles it
                break
            case 0x09, 0x0A, 0x20...0x10FFFF:
                clean.append(scalar)
            default:
                break
            }
            index += 1
        }
        return String(clean)
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

    /// Entrada curta disparada por uma superfície de acompanhamento. Usa o mesmo caminho serializado do
    /// terminal visível, portanto nunca fura a ordem do PTY.
    @discardableResult
    func sendCommand(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, session?.id != nil, viva else { return false }
        // O Codex TUI diferencia line-feed de Return: LF pode apenas inserir uma
        // quebra no compositor, enquanto CR confirma a mensagem. PTYs também
        // traduzem CR corretamente para shells e demais CLIs.
        sendInput(Array((trimmed + "\r").utf8)[...])
        return true
    }

    /// Retoma o mesmo nó se necessário e só retorna depois que o engine
    /// confirmou a entrada no PTY. É o caminho usado pelo Agent Chat.
    func ensureAndSendCommand(workspaceID: ULID, floorID: ULID?, command: String) async throws {
        let terminal = terminalView.getTerminal()
        let result = try await connection.call(
            .sessionEnsure,
            params: SessionEnsureParams(
                workspaceID: workspaceID,
                nodeID: nodeID,
                floorID: floorID,
                cols: terminal.cols,
                rows: terminal.rows),
            expecting: SessionResult.self)
        adopt(session: result.session)
        await attach()
        guard let sessionID = session?.id else {
            throw ProtocolError(name: .internal_error, message: "session.ensure retornou sem sessão")
        }
        let cleanCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let baselineCount = structuredAssistantContents(workspaceID: workspaceID).count
        // Texto e Return precisam ser eventos separados. Quando ambos chegam no
        // mesmo write, o Codex TUI pode tratá-los como paste e apenas preencher o
        // compositor — exatamente o sintoma de "oi" visível, mas não enviado.
        let data = Data(cleanCommand.utf8)
        _ = try await connection.call(
            .sessionInput,
            params: SessionInputParams(sessionID: sessionID, dataB64: data.base64EncodedString()),
            expecting: EmptyResult.self)
        try await Task.sleep(nanoseconds: 120_000_000)
        _ = try await connection.call(
            .sessionInput,
            params: SessionInputParams(
                sessionID: sessionID,
                dataB64: Data([0x0D]).base64EncodedString()),
            expecting: EmptyResult.self)
        watchStructuredCodexResponse(
            workspaceID: workspaceID, baselineCount: baselineCount)
    }

    private func watchStructuredCodexResponse(
        workspaceID: ULID,
        baselineCount: Int
    ) {
        structuredResponseTask?.cancel()
        structuredResponseTask = Task { [weak self] in
            var consumedCount = baselineCount
            var settledPolls = 0
            for _ in 0..<360 {
                guard !Task.isCancelled, let self else { return }
                let messages = self.structuredAssistantContents(workspaceID: workspaceID)
                if messages.count > consumedCount {
                    self.structuredAssistantMessages.append(
                        contentsOf: messages[consumedCount...])
                    consumedCount = messages.count
                    if self.structuredAssistantMessages.count > 50 {
                        self.structuredAssistantMessages.removeFirst(
                            self.structuredAssistantMessages.count - 50)
                    }
                    settledPolls = 0
                }
                let hasNewResponse = consumedCount > baselineCount
                let isSettled = self.estado == .esperandoHumano || self.estado == .ociosa
                settledPolls = hasNewResponse && isSettled ? settledPolls + 1 : 0
                // Mantém mensagens intermediárias legíveis (sem TUI), mas só
                // encerra o watcher depois de a sessão realmente estabilizar.
                if settledPolls >= 6 {
                    return
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private func structuredAssistantContents(workspaceID: ULID) -> [String] {
        guard let file = latestCodexSessionFile(workspaceID: workspaceID),
              let data = try? Data(contentsOf: file),
              let raw = String(data: data, encoding: .utf8) else { return [] }
        return raw.split(separator: "\n").compactMap { line -> String? in
            guard let lineData = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  object["type"] as? String == "response_item",
                  let payload = object["payload"] as? [String: Any],
                  payload["type"] as? String == "message",
                  payload["role"] as? String == "assistant",
                  let content = payload["content"] as? [[String: Any]] else { return nil }
            let text = content.compactMap { item -> String? in
                guard item["type"] as? String == "output_text" else { return nil }
                return item["text"] as? String
            }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
    }

    private func latestCodexSessionFile(workspaceID: ULID) -> URL? {
        let sessions = ColmeiaPaths().workspaceDir(workspaceID)
            .appendingPathComponent("codex", isDirectory: true)
            .appendingPathComponent(nodeID.string, isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: sessions,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]
        ) else { return nil }
        return enumerator.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "jsonl" }
            .max {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a < b
            }
    }

    /// Throttle ~10/s (§9.3). A geometria enviada é SEMPRE a corrente do próprio
    /// SwiftTerm no instante do envio — nunca um par guardado que envelheceu no
    /// throttle. Sem sessão na hora do disparo, o pedido fica pendente (o attach
    /// pós-start sincroniza) — nunca é perdido em silêncio.
    func requestResize(cols: Int, rows: Int) {
        agendarSincronizacaoDeGeometria()
    }

    func pushCurrentGeometry() {
        agendarSincronizacaoDeGeometria()
    }

    func applyFontSize(_ size: Double?) {
        let normalized = TerminalAppearance.tamanhoNormalizado(size)
        guard abs(normalized - fontSize) > 0.1 else { return }
        fontSize = normalized
        terminalView.font = TerminalAppearance.fonte(size: normalized)
        terminalView.rederivarGeometriaDoFrame()
        pushCurrentGeometry()
    }

    private func agendarSincronizacaoDeGeometria() {
        resizePendente = true
        guard resizeTask == nil else { return }
        resizeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard let self else { return }
            self.resizeTask = nil
            guard self.resizePendente else { return }
            guard let sessionID = self.session?.id else { return } // pendente até haver sessão
            self.resizePendente = false
            let terminal = self.terminalView.getTerminal()
            _ = try? await self.connection.call(
                .sessionResize,
                params: SessionResizeParams(sessionID: sessionID, cols: terminal.cols, rows: terminal.rows)
            )
        }
    }

    // MARK: - View

    private func makeTerminalView() -> ColmeiaTerminalView {
        // A fonte entra pelo init (mudar depois recalcula cols pelo caminho sem
        // desconto de scroller). O frame aqui é só placeholder até o primeiro
        // layout real — `esperarLayoutAssentar` segura o session.start até lá.
        let view = ColmeiaTerminalView(
            frame: NSRect(x: 0, y: 0, width: 600, height: 380),
            font: TerminalAppearance.fonte(size: fontSize)
        )
        TerminalAppearance.aplicar(em: view)
        view.terminalDelegate = self
        view.aoAssentarLayout = { [weak self] in
            self?.layoutAssentou()
        }
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
            // Resize aplicado pelo replay (geometria histórica do journal) não
            // ecoa pro PTY — só mudanças vindas do layout real sincronizam.
            guard !aplicandoReplay else { return }
            requestResize(cols: newCols, rows: newRows)
        }
    }

    nonisolated func setTerminalTitle(source: TerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func scrolled(source: TerminalView, position: Double) {}
    nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
