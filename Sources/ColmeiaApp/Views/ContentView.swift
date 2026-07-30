import SwiftUI
import AppKit
import WebKit
import ColmeiaKit

struct ContentView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var connection: EngineConnection
    @State private var showMemoryPanel = false
    @State private var showDeliveriesPanel = false
    @State private var showWorkersPanel = false
    @State private var showRoomsPanel = false
    @State private var showNowPanel = false
    @State private var showFilesPanel = false
    @State private var showPromptComposer = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if store.workspace != nil {
                VStack(spacing: 0) {
                    FloorBar()
                    CanvasView()
                }
                DrawingToolbar()
                    .padding(.bottom, 14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            } else {
                emptyState
            }
            overlayIndicators
        }
        // Prefixo tmux (§Apêndice B) fica no nível da janela, antes de o evento
        // chegar ao terminal/portal. O bridge não participa de hit-testing.
        .background(TmuxPrefixBridge(store: store))
        .toolbar { toolbarContent }
        .onReceive(NotificationCenter.default.publisher(for: .colmeiaOpenRooms)) { _ in
            showRoomsPanel = true
        }
        .sheet(isPresented: $store.showNewTerminal) {
            NewTerminalSheet(adapterInicial: store.newTerminalAdapter)
        }
        .sheet(isPresented: $store.showApprovals) {
            ApprovalsPanel()
        }
        .sheet(isPresented: $store.showRoutines) {
            RoutinesPanel()
        }
        .sheet(isPresented: $showMemoryPanel) {
            MemoryPanel(
                memory: store.memory,
                proposals: store.memoryProposals,
                history: store.memoryHistory,
                onUpdate: { content in Task { await store.updateMemory(content) } },
                onAccept: { id, editedContent in Task { await store.acceptMemoryProposal(id, editedContent: editedContent) } },
                onReject: { id in Task { await store.rejectMemoryProposal(id) } }
            )
        }
        .sheet(isPresented: $showNowPanel) {
            NowPanel(
                workers: activeWorkers,
                notes: canvasNotes,
                deliveries: store.deliveries,
                openDecisions: store.openDecisions,
                alerts: operationAlerts,
                messages: store.agentMessages,
                roomSyncLabel: store.roomSyncLabel,
                nodeName: { store.nodeName($0) },
                onCreateWorker: { store.presentNewTerminal(adapter: store.newTerminalAdapter) },
                onOpenDeliveries: {
                    showNowPanel = false
                    showDeliveriesPanel = true
                    Task { await store.refreshDeliveries() }
                },
                onOpenMemory: {
                    showNowPanel = false
                    showMemoryPanel = true
                    Task { await store.refreshMemory() }
                },
                onOpenRooms: {
                    showNowPanel = false
                    showRoomsPanel = true
                }
            )
        }
        .sheet(isPresented: $showFilesPanel) {
            FileTreePanel(rootPath: currentFilesRoot)
        }
        .sheet(isPresented: $showPromptComposer) {
            PromptComposerView(initialRecipient: selectedTerminalID)
        }
        .sheet(isPresented: $showDeliveriesPanel) {
            DeliveriesPanel(
                deliveries: store.deliveries,
                onAccept: { id in Task { await store.acceptDelivery(id) } },
                onReopen: { id in Task { await store.reopenDelivery(id) } },
                onTerminateAndArchive: { sessionID in
                    Task { await store.terminateAndArchiveWorker(sessionID: sessionID) }
                }
            )
        }
        .sheet(isPresented: $showWorkersPanel) {
            WorkersOperationPanel(
                watchdog: Binding(
                    get: { store.watchdogConfiguration },
                    set: { configuration in Task { await store.updateWatchdog(configuration) } }
                ),
                alerts: operationAlerts,
                activeWorkers: activeWorkers,
                archives: store.workerArchives,
                onConfigurationChange: { configuration in
                    Task { await store.updateWatchdog(configuration) }
                },
                onCreateWorker: {
                    store.presentNewTerminal(adapter: store.newTerminalAdapter)
                },
                onOpenReplay: { store.replaySession = $0 }
            )
        }
        .sheet(item: $store.replaySession) { session in
            ReplayPanel(session: session, connection: connection)
        }
        .sheet(isPresented: $showRoomsPanel) {
            RoomsPanel()
        }
        .sheet(isPresented: Binding(
            get: { store.textoPendentePonto != nil },
            set: { if !$0 { store.textoPendentePonto = nil } }
        )) {
            if let ponto = store.textoPendentePonto {
                TextoSoltoSheet(ponto: ponto)
            }
        }
    }

    /// §3.2 / Marco A — primeiro convite é criar Missão, não abrir terminal.
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "hexagon")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            if connection.isConnected {
                Text("Criar uma Missão")
                    .font(.title3)
                Text("O canvas organiza resultado, responsáveis e entregas — o terminal vem depois.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                Button {
                    showRoomsPanel = true
                } label: {
                    Label("Abrir salas e missões", systemImage: "flag.fill")
                }
                .buttonStyle(.borderedProminent)
                WorkspaceSelectorMenu()
            } else {
                ProgressView()
                    .controlSize(.small)
                Text("conectando ao engine…")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var overlayIndicators: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if case .reconectando(let tentativa) = connection.status {
                Label("reconectando (\(tentativa))", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.thinMaterial, in: Capsule())
            }
            engineVersionBanner
            if let aviso = store.avisoInfo {
                Text(aviso)
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.thinMaterial, in: Capsule())
            }
            if let erro = store.lastError {
                HStack(spacing: 6) {
                    Text(erro)
                        .font(.caption)
                        .lineLimit(2)
                    Button {
                        store.lastError = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                .frame(maxWidth: 420)
            }
        }
        .padding(12)
    }

    /// §3.3/§6.3 — engine sobreviveu ao upgrade dos binários: banner PERSISTENTE
    /// (métodos novos falhariam silenciosamente) com a reciclagem a um clique.
    /// Não bloqueia o uso do app; some sozinho quando as versões batem.
    @ViewBuilder
    private var engineVersionBanner: some View {
        if connection.reciclandoEngine {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("reciclando engine…")
                    .font(.caption)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        } else if connection.isConnected && connection.engineDesatualizado {
            VStack(alignment: .trailing, spacing: 6) {
                Label(
                    connection.appDesatualizado
                        ? "Interface antiga aberta (app \(connection.appVersion), engine \(connection.engineVersion ?? "?"))"
                        : "Engine desatualizado (app \(connection.appVersion) ≠ engine \(connection.engineVersion ?? "?"))",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption.bold())
                Text(connection.appDesatualizado
                    ? "Reabra o aplicativo para carregar a versão instalada."
                    : "Reciclar encerra as sessões ativas; journals preservados.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let erro = connection.erroReciclagem {
                    Text(erro)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
                Button(connection.appDesatualizado ? "Reabrir Colmeia" : "Reciclar engine") {
                    if connection.appDesatualizado {
                        connection.relaunchApplication()
                    } else {
                        Task { await connection.recycleEngine() }
                    }
                }
                .controlSize(.small)
            }
            .padding(10)
            .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.orange.opacity(0.4), lineWidth: 1))
            .frame(maxWidth: 420)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            WorkspaceSelectorMenu()
        }
        ToolbarItemGroup {
            // Escolher o adapter aqui apenas abre o diálogo: a pessoa sempre dá
            // um nome antes de qualquer nó/sessão ser criado.
            Menu {
                ForEach(NewTerminalSheet.quickStarts) { qs in
                    Button {
                        store.presentNewTerminal(adapter: qs.id)
                    } label: {
                        Label(qs.nome, systemImage: qs.icone)
                    }
                    .disabled(!store.adapterPodeSerSelecionado(qs.id))
                }
                Divider()
                Button {
                    store.presentNewTerminal(adapter: store.newTerminalAdapter)
                } label: {
                    Label("Opções avançadas…", systemImage: "slider.horizontal.3")
                }
            } label: {
                Label("Novo Terminal", systemImage: "terminal")
            }
            .disabled(store.workspace == nil)

            Button {
                store.addNota()
            } label: {
                Label("Nova Nota", systemImage: "note.text.badge.plus")
            }
            .disabled(store.workspace == nil)

            Button {
                store.showNewPortal.toggle()
            } label: {
                Label("Novo Portal", systemImage: "globe")
            }
            .disabled(store.workspace == nil)
            .popover(isPresented: $store.showNewPortal, arrowEdge: .bottom) {
                NewPortalPopover()
            }

            approvalsButton

            Button {
                showPromptComposer = true
            } label: {
                Label("Compor prompt", systemImage: "square.and.pencil")
            }
            .disabled(store.workspace == nil)

            Menu {
                Button {
                    showNowPanel = true
                    Task {
                        await store.refreshDeliveries()
                        await store.refreshWatchdog()
                        await store.refreshWorkerArchives()
                    }
                } label: {
                    Label("Agora", systemImage: "rectangle.and.text.magnifyingglass")
                }
                Button {
                    showFilesPanel = true
                } label: {
                    Label("Arquivos", systemImage: "folder")
                }
                Divider()
                Button {
                    showMemoryPanel = true
                    Task { await store.refreshMemory() }
                } label: {
                    Label("Memória", systemImage: "brain.head.profile")
                }
                Button {
                    showDeliveriesPanel = true
                    Task { await store.refreshDeliveries() }
                } label: {
                    Label("Entregas", systemImage: "shippingbox")
                }
                Button {
                    showWorkersPanel = true
                    Task {
                        await store.refreshWatchdog()
                        await store.refreshWorkerArchives()
                    }
                } label: {
                    Label("Operação de workers", systemImage: "shield.lefthalf.filled")
                }
            } label: {
                Label("Operação", systemImage: "slider.horizontal.3")
            }
            .disabled(store.workspace == nil)

            EditorPreferenceMenu()
            Button {
                showRoomsPanel = true
            } label: {
                Label("Salas", systemImage: "person.3.fill")
            }
        }
    }

    private var operationAlerts: [WorkerOperationAlert] {
        store.watchdogAlerts.map { alert in
            WorkerOperationAlert(
                id: "\(alert.sessionID.string)-\(alert.episode)-\(alert.kind)",
                sessionID: alert.sessionID,
                title: alert.kind == "escalate" ? "Revisão humana necessária" :
                    (alert.kind == "recovered" ? "Worker recuperado" : "Worker sem atividade"),
                detail: alert.message,
                createdAt: Date(),
                escalated: alert.kind == "escalate")
        }
    }

    private var canvasNotes: [CanvasNoteSummary] {
        store.nodes.values.compactMap { node in
            guard case .nota(let note) = node else { return nil }
            return CanvasNoteSummary(
                id: note.id,
                title: "Nota \(note.id.string.prefix(6))",
                lastWriter: note.ultimaFonte?.description)
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private var currentFilesRoot: String? {
        if let path = store.activeFloor?.caminho, !path.isEmpty { return path }
        if let path = selectedTerminalCWD, !path.isEmpty { return path }
        if let path = store.workspace?.caminhoRaiz, !path.isEmpty { return path }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }

    private var selectedTerminalCWD: String? {
        guard let selection = store.selection,
              case .terminal(let terminal)? = store.nodes[selection]
        else { return nil }
        return terminal.cwd
    }

    private var selectedTerminalID: ULID? {
        guard let selection = store.selection,
              case .terminal = store.nodes[selection]
        else { return nil }
        return selection
    }

    private var activeWorkers: [ActiveWorkerSummary] {
        store.nodes.values.compactMap { node in
            guard case .terminal(let terminal) = node else { return nil }
            let controller = store.terminalControllers[terminal.id]
            guard let session = controller?.session else { return nil }
            return ActiveWorkerSummary(
                nodeID: terminal.id,
                nome: terminal.nome,
                adapter: terminal.adapter,
                estado: controller?.estado ?? session.estado,
                sessionID: session.id)
        }
        .sorted { $0.nome.localizedCaseInsensitiveCompare($1.nome) == .orderedAscending }
    }

    /// Badge global DEVE ficar sempre visível quando > 0 (§18.4).
    private var approvalsButton: some View {
        Button {
            store.showApprovals.toggle()
        } label: {
            Label("Aprovações", systemImage: "checkmark.shield")
                .overlay(alignment: .topTrailing) {
                    let count = store.pendingApprovals.count
                    if count > 0 {
                        Text("\(count)")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.red, in: Capsule())
                            .offset(x: 10, y: -8)
                    }
                }
        }
    }
}

// MARK: - Preferência de editor (§18.7)

private struct EditorPreferenceMenu: View {
    @State private var preferredID = EditorOpener.preferenciaExplicita?.id

    var body: some View {
        Menu {
            let editors = EditorOpener.instalados
            Button {
                EditorOpener.usarDeteccaoAutomatica()
                preferredID = nil
            } label: {
                if preferredID == nil {
                    Label("Detecção automática", systemImage: "checkmark")
                } else {
                    Text("Detecção automática")
                }
            }
            Button {
                EditorOpener.preferido = EditorOpener.appPadrao
                preferredID = EditorOpener.appPadrao.id
            } label: {
                if preferredID == EditorOpener.appPadrao.id {
                    Label(EditorOpener.appPadrao.nome, systemImage: "checkmark")
                } else {
                    Text(EditorOpener.appPadrao.nome)
                }
            }
            if !editors.isEmpty {
                Divider()
            }
            ForEach(editors) { editor in
                Button {
                    EditorOpener.preferido = editor
                    preferredID = editor.id
                } label: {
                    if preferredID == editor.id {
                        Label(editor.nome, systemImage: "checkmark")
                    } else {
                        Text(editor.nome)
                    }
                }
            }
        } label: {
            Label("Editor preferido", systemImage: "square.and.pencil")
        }
        .accessibilityLabel("Escolher editor preferido")
        .help("Editor usado por Abrir no Editor (⌘E)")
    }
}

// MARK: - Atalhos tmux-like (Apêndice B)

/// Monitor local de teclas para sequências `⌃A` + tecla. `Commands` do SwiftUI
/// cobre atalhos de uma tecla; este bridge cobre o prefixo sem criar um primeiro
/// responder paralelo ao SwiftTerm. Campos de texto/WebKit preservam a digitação.
private struct TmuxPrefixBridge: NSViewRepresentable {
    let store: AppStore

    func makeNSView(context: Context) -> TmuxPrefixMonitorView {
        let view = TmuxPrefixMonitorView()
        view.store = store
        return view
    }

    func updateNSView(_ nsView: TmuxPrefixMonitorView, context: Context) {
        nsView.store = store
        nsView.observeWorkspace(store.workspace?.id)
    }
}

private final class TmuxPrefixMonitorView: NSView {
    weak var store: AppStore?

    private var monitor: Any?
    private var prefixAt: Date?
    private var workspaceAtual: ULID?
    private var workspaceAnterior: ULID?

    private static let prefixKeyCode: UInt16 = 0 // A
    private static let spaceKeyCode: UInt16 = 49
    private static let tabKeyCode: UInt16 = 48
    private static let prefixTimeout: TimeInterval = 1.2

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            tearDown()
        } else {
            install()
        }
    }

    deinit { tearDown() }

    func observeWorkspace(_ workspaceID: ULID?) {
        guard workspaceID != workspaceAtual else { return }
        workspaceAnterior = workspaceAtual
        workspaceAtual = workspaceID
    }

    private func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    private func tearDown() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        prefixAt = nil
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window === window, window.isKeyWindow else { return event }

        // Espaço focaliza/ajusta o nó selecionado. Em qualquer superfície que
        // aceita texto (inclusive portal), passa intacto — CanvasNavigation então
        // também não entra em modo mão por esse mesmo evento.
        if event.keyCode == Self.spaceKeyCode,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
           !Self.focoEstaDigitando(window),
           store?.selection != nil {
            zoomNoNoSelecionado()
            return nil
        }

        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == Self.prefixKeyCode, mods == .control {
            // Em campo de texto, ⌃A mantém o comportamento nativo de mover ao
            // começo da linha; no terminal é deliberadamente o prefixo tmux.
            guard !Self.focoEhCampoDeTexto(window) else { return event }
            prefixAt = Date()
            return nil
        }

        guard let prefixAt, Date().timeIntervalSince(prefixAt) <= Self.prefixTimeout else {
            self.prefixAt = nil
            return event
        }
        self.prefixAt = nil
        guard mods.isEmpty || event.keyCode == Self.tabKeyCode else { return event }
        runPrefixedAction(event)
        return nil
    }

    private func runPrefixedAction(_ event: NSEvent) {
        guard let store else { return }
        if let number = workspaceNumber(for: event) {
            openWorkspace(numero: number)
            return
        }
        switch event.keyCode {
        case Self.tabKeyCode:
            guard let workspaceAnterior,
                  store.workspaces.contains(where: { $0.id == workspaceAnterior }) else { return }
            Task { await store.open(workspaceID: workspaceAnterior) }
        default:
            let char = event.charactersIgnoringModifiers?.lowercased()
            switch char {
            case "f":
                switchToNextFloor()
            case "n":
                store.presentNewTerminal(adapter: store.newTerminalAdapter)
            case "a":
                store.showApprovals = true
            default:
                switch event.keyCode {
                case 123: focusTerminal(direction: .left)
                case 124: focusTerminal(direction: .right)
                case 125: focusTerminal(direction: .down)
                case 126: focusTerminal(direction: .up)
                default: break
                }
            }
        }
    }

    /// Key codes de números variam menos que `characters`, mas os caracteres
    /// permitem layouts internacionais. Só 1–9 entram no protocolo.
    private func workspaceNumber(for event: NSEvent) -> Int? {
        guard let char = event.charactersIgnoringModifiers,
              let value = Int(char), (1...9).contains(value) else { return nil }
        return value
    }

    private func openWorkspace(numero: Int?) {
        guard let numero, numero > 0,
              let store,
              store.workspaces.indices.contains(numero - 1) else { return }
        Task { await store.open(workspaceID: store.workspaces[numero - 1].id) }
    }

    private func switchToNextFloor() {
        guard let store else { return }
        let options: [Floor?] = [nil] + store.floors.filter { $0.estado == .ativo || $0.estado == .orfao }
        guard options.count > 1 else { return }
        let current = store.activeFloor?.id
        let index = options.firstIndex { $0?.id == current } ?? 0
        let next = options[(index + 1) % options.count]
        Task { await store.switchFloor(next) }
    }

    private enum Direction { case left, right, up, down }

    /// Foco espacial: escolhe o terminal no hemisfério pedido com menor avanço
    /// na direção; desvio perpendicular desempata. Funciona também se a seleção
    /// atual for uma nota/portal, usando o centro desse nó como origem.
    private func focusTerminal(direction: Direction) {
        guard let store else { return }
        let origin: Ponto
        if let selected = store.selection, let node = store.nodes[selected],
           store.floorOpacity(for: selected) >= 0.99 {
            origin = center(of: node)
        } else {
            origin = Ponto(
                x: store.viewport.x + Double(store.canvasSize.width) / (2 * store.viewport.zoom),
                y: store.viewport.y + Double(store.canvasSize.height) / (2 * store.viewport.zoom)
            )
        }
        let target = store.nodes.values.compactMap { node -> (Node, Double)? in
            guard case .terminal = node,
                  node.id != store.selection,
                  store.floorOpacity(for: node.id) >= 0.99 else { return nil }
            let candidate = center(of: node)
            let dx = candidate.x - origin.x
            let dy = candidate.y - origin.y
            let primary: Double
            let perpendicular: Double
            switch direction {
            case .left: primary = -dx; perpendicular = abs(dy)
            case .right: primary = dx; perpendicular = abs(dy)
            case .up: primary = -dy; perpendicular = abs(dx)
            case .down: primary = dy; perpendicular = abs(dx)
            }
            guard primary > 0 else { return nil }
            return (node, primary + perpendicular * 0.35)
        }
        .min { $0.1 < $1.1 }?.0
        if let target { store.focus(nodeID: target.id) }
    }

    private func zoomNoNoSelecionado() {
        guard let store, let id = store.selection, let node = store.nodes[id] else { return }
        let width = max(node.tamanho.w * 1.25, 1)
        let height = max(node.tamanho.h * 1.4, 1)
        let zoom = min(
            Viewport.zoomRange.upperBound,
            max(
                Viewport.zoomRange.lowerBound,
                min(Double(store.canvasSize.width) / width, Double(store.canvasSize.height) / height)
            )
        )
        var viewport = store.viewport
        viewport.zoom = zoom
        viewport.x = node.posicao.x + node.tamanho.w / 2 - Double(store.canvasSize.width) / (2 * zoom)
        viewport.y = node.posicao.y + node.tamanho.h / 2 - Double(store.canvasSize.height) / (2 * zoom)
        store.setViewport(viewport)
    }

    private func center(of node: Node) -> Ponto {
        Ponto(x: node.posicao.x + node.tamanho.w / 2, y: node.posicao.y + node.tamanho.h / 2)
    }

    private static func focoEhCampoDeTexto(_ window: NSWindow) -> Bool {
        guard let responder = window.firstResponder else { return false }
        return responder is NSText || responder is NSTextView
    }

    private static func focoEstaDigitando(_ window: NSWindow) -> Bool {
        guard let responder = window.firstResponder else { return false }
        if responder is NSText || responder is NSTextView { return true }
        guard let view = responder as? NSView else { return false }
        var current: NSView? = view
        while let candidate = current {
            if candidate is WKWebView { return true }
            current = candidate.superview
        }
        return false
    }
}
