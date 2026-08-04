import SwiftUI
import AppKit
import SwiftTerm
import ColmeiaKit

/// Espaço de coordenadas FIXO do canvas (tela): gestos de drag dos nós medem a
/// translação aqui — nunca no espaço local do nó, que se move junto com o gesto
/// (feedback → o nó "voa" para longe e some).
enum CanvasSpace {
    static let nome = "colmeia-canvas"
}

private struct RemotePresenceLayer: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var presenceStore: CollaborationPresenceStore

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(presenceStore.remotePresences.values), id: \.memberID) { presence in
                if let cursor = presence.cursor {
                    let point = CanvasMath.mundoParaTela(cursor, viewport: store.viewport)
                    let color = color(for: presence.memberID)
                    VStack(alignment: .leading, spacing: 0) {
                        Image(systemName: "cursorarrow")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(color)
                        Text(presence.displayName
                             ?? presenceStore.members[presence.memberID]?.displayName
                             ?? presence.memberID)
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(color, in: Capsule())
                            .offset(x: 12, y: -2)
                    }
                    .position(x: point.x, y: point.y)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func color(for memberID: String) -> SwiftUI.Color {
        let scalar = memberID.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 360 }
        return SwiftUI.Color(hue: Double(scalar) / 360, saturation: 0.72, brightness: 0.95)
    }
}

/// Contexto semântico da visão de Missão. O agregado e o layout vêm da Sala
/// quando há colaboração ativa; fora dela, a posição local serve de fallback.
private struct MissionCanvasOverlay: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "flag.checkered")
                    .foregroundStyle(SwiftUI.Color.accentColor)
                Text("Contexto da missão")
                    .font(.caption.weight(.semibold))
                Spacer()
                Button {
                    Task { await store.refreshMissions() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Atualizar missões e frentes")
            }

            if store.missions.isEmpty {
                Text("Nenhuma missão na sala deste workspace.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Crie uma sala e uma missão no painel Salas para começar o planejamento.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else if let mission = store.canvasMission {
                HStack(alignment: .firstTextBaseline) {
                    Text(mission.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    Spacer()
                    Text(mission.state.rawValue.replacingOccurrences(of: "_", with: " "))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                if let context = mission.context, !context.isEmpty {
                    Text(context)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text("Pronto: \(mission.definitionOfDone)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                if !store.canvasWorkstreams.isEmpty {
                    Divider()
                    Text("Frentes")
                        .font(.caption2.weight(.semibold))
                    ForEach(store.canvasWorkstreams, id: \.id) { front in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(frontColor(front.state))
                                .frame(width: 6, height: 6)
                            Text(front.title)
                                .font(.caption2)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(front.state.rawValue.replacingOccurrences(of: "_", with: " "))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                if !store.canvasMissionDecisions.isEmpty || !store.canvasMissionDeliveries.isEmpty {
                    Divider()
                    HStack {
                        Text("Linha do tempo")
                            .font(.caption2.weight(.semibold))
                        Spacer()
                        if !store.canvasMissionDecisions.isEmpty {
                            Label("\(store.canvasMissionDecisions.count)", systemImage: "questionmark.bubble")
                                .font(.caption2)
                        }
                        if !store.canvasMissionDeliveries.isEmpty {
                            Label("\(store.canvasMissionDeliveries.count)", systemImage: "shippingbox")
                                .font(.caption2)
                        }
                    }
                    ForEach(Array(store.canvasMissionTimeline.prefix(5))) { item in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: item.symbol)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .frame(width: 14)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.title)
                                    .font(.caption2)
                                    .lineLimit(1)
                                Text(item.detail)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
                HStack {
                    Button("Todas") { store.canvasFiltroMissao = nil }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    Spacer()
                    Text("Nós atribuídos às frentes ficam em foco")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } else {
                Text("Selecione uma missão para filtrar os nós atribuídos às frentes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(store.missions, id: \.id) { mission in
                    Button {
                        store.canvasFiltroMissao = mission.id
                    } label: {
                        HStack(spacing: 7) {
                            Circle()
                                .fill(missionColor(mission.state))
                                .frame(width: 7, height: 7)
                            Text(mission.title)
                                .font(.caption)
                                .lineLimit(1)
                            Spacer()
                            Text(mission.state.rawValue.replacingOccurrences(of: "_", with: " "))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .frame(width: 330, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.quaternary, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 14, y: 5)
        .padding(14)
    }

    private func missionColor(_ state: MissionState) -> SwiftUI.Color {
        switch state {
        case .active: return .green
        case .blocked: return .orange
        case .inReview: return .blue
        case .completed: return .mint
        case .archived: return .gray
        case .draft: return .secondary
        }
    }

    private func frontColor(_ state: WorkstreamState) -> SwiftUI.Color {
        switch state {
        case .active: return .green
        case .blocked: return .orange
        case .waitingForReview: return .blue
        case .completed: return .mint
        case .canceled: return .gray
        case .notStarted: return .secondary
        }
    }
}

private struct MissionSemanticLayer: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var hubConnection: HubConnection
    @EnvironmentObject private var presenceStore: CollaborationPresenceStore
    @State private var layoutObserverID: UUID?
    @State private var loadedRoomID: ULID?

    private var visibleMissions: [Mission] {
        if let selected = store.canvasFiltroMissao {
            return store.missions.filter { $0.id == selected }
        }
        return store.missions
    }

    var body: some View {
        ForEach(Array(visibleMissions.enumerated()), id: \.element.id) { index, mission in
            let position = store.semanticObjectPosition(mission.id, index: index)
            MissionFrameCard(mission: mission, fronts: store.workstreams.filter { $0.missionID == mission.id })
                .frame(width: 390)
                .scaleEffect(store.viewport.zoom, anchor: .topLeading)
                .offset(
                    x: (position.x - store.viewport.x) * store.viewport.zoom,
                    y: (position.y - store.viewport.y) * store.viewport.zoom)
                .gesture(dragGesture(for: mission.id, initial: position))
                .zIndex(0.05)
        }
        .allowsHitTesting(true)
        .onAppear {
            registerLayoutObserver()
            Task { await loadRemoteLayoutIfNeeded() }
        }
        .onChange(of: presenceStore.activeRoomID) { _, _ in
            loadedRoomID = nil
            Task { await loadRemoteLayoutIfNeeded() }
        }
        .onChange(of: hubConnection.status) { _, status in
            if case .conectado = status {
                loadedRoomID = nil
                Task { await loadRemoteLayoutIfNeeded() }
            }
        }
        .onDisappear {
            if let layoutObserverID {
                hubConnection.removeEventObserver(layoutObserverID)
            }
            layoutObserverID = nil
        }
    }

    private func dragGesture(for id: ULID, initial: Ponto) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(CanvasSpace.nome))
            .onChanged { value in
                let zoom = max(store.viewport.zoom, 0.01)
                store.moveSemanticObject(
                    id,
                    to: Ponto(
                        x: initial.x + value.translation.width / zoom,
                        y: initial.y + value.translation.height / zoom))
            }
            .onEnded { _ in
                if let final = store.semanticObjectPositions[id] {
                    store.moveSemanticObject(id, to: final, persist: true)
                    persistRemotePosition(id, final)
                }
            }
    }

    private func registerLayoutObserver() {
        guard layoutObserverID == nil else { return }
        layoutObserverID = hubConnection.addEventObserver { [store, presenceStore] event in
            guard event.knownTopic == .roomLayoutChanged,
                  let payload = try? event.decodeParams(RoomLayoutChangedTopicPayload.self),
                  payload.roomID == presenceStore.activeRoomID else { return }
            store.applyRemoteSemanticLayoutEvent(event)
        }
    }

    private func loadRemoteLayoutIfNeeded() async {
        guard let roomID = presenceStore.activeRoomID,
              hubConnection.isConnected,
              loadedRoomID != roomID else { return }
        do {
            let result: RoomLayoutResult = try await hubConnection.call(
                .roomLayoutGet,
                params: RoomLayoutGetParams(roomID: roomID),
                expecting: RoomLayoutResult.self)
            guard presenceStore.activeRoomID == roomID else { return }
            store.replaceSemanticObjectPositions(result.positions)
            loadedRoomID = roomID
        } catch {
            // O layout local continua válido se a Sala ainda não estiver pronta.
        }
    }

    private func persistRemotePosition(_ id: ULID, _ position: Ponto) {
        guard let roomID = presenceStore.activeRoomID else { return }
        Task {
            _ = try? await hubConnection.call(
                .roomLayoutUpdate,
                params: RoomLayoutUpdateParams(roomID: roomID, objectID: id, position: position))
        }
    }
}

private struct MissionFrameCard: View {
    let mission: Mission
    let fronts: [Workstream]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "flag.checkered")
                    .foregroundStyle(stateColor)
                Text(mission.title)
                    .font(.headline)
                    .lineLimit(2)
                Spacer()
                Text(mission.state.rawValue.replacingOccurrences(of: "_", with: " "))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(stateColor)
            }
            if let context = mission.context, !context.isEmpty {
                Text(context)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Text("Pronto: \(mission.definitionOfDone)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if !fronts.isEmpty {
                Divider()
                ForEach(fronts, id: \.id) { front in
                    HStack(spacing: 7) {
                        Circle()
                            .fill(frontColor(front.state))
                            .frame(width: 7, height: 7)
                        Text(front.title)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer()
                        Text(front.state.rawValue.replacingOccurrences(of: "_", with: " "))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            } else {
                Text("Adicione uma Frente para ativar esta missão.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(stateColor.opacity(0.65), lineWidth: 1.5))
        .shadow(color: .black.opacity(0.16), radius: 12, y: 5)
    }

    private var stateColor: SwiftUI.Color {
        switch mission.state {
        case .active: return .green
        case .blocked: return .orange
        case .inReview: return .blue
        case .completed: return .mint
        case .archived: return .gray
        case .draft: return .secondary
        }
    }

    private func frontColor(_ state: WorkstreamState) -> SwiftUI.Color {
        switch state {
        case .active: return .green
        case .blocked: return .orange
        case .waitingForReview: return .blue
        case .completed: return .mint
        case .canceled: return .gray
        case .notStarted: return .secondary
        }
    }
}

struct CanvasView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var presenceStore: CollaborationPresenceStore

    @State private var panStart: Viewport?
    @State private var canvasInteracting = false
    @State private var keyMonitor: Any?

    var body: some View {
        VStack(spacing: 0) {
            canvasModeBar
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                // Metal fica estritamente atrás da interação SwiftUI. A grade por
                // cima conserva a orientação espacial mesmo quando o efeito de
                // vidro está animado.
                CanvasMetalBackdrop(viewport: store.viewport, isInteracting: canvasInteracting)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                GridBackground(viewport: store.viewport)
                    .contentShape(Rectangle())
                    .gesture(panGesture)
                    .onTapGesture {
                        store.selection = nil
                        store.connectionSelection = nil
                        store.returnFocusToCanvas()
                    }
                if store.canvasViewMode == .missao {
                    MissionCanvasOverlay()
                    MissionSemanticLayer()
                }
                ConnectionsLayer(isInteracting: canvasInteracting)
                nodeLayer
                if store.canvasViewMode == .atencao {
                    attentionOverlay
                }
                RemotePresenceLayer()
                if store.ferramentaDesenho != nil {
                    DrawingLayer()
                }
                MinimapView()
                    .frame(width: 180, height: 120)
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
            .clipped()
            .coordinateSpace(name: CanvasSpace.nome)
            // Navegação universal (§18.2): pinch/⌥-scroll/⌘-scroll/Espaço+drag
            // funcionam SOBRE webview e terminal — NSEvent monitors por janela
            // (CanvasNavigation.swift). O pinch SwiftUI foi substituído por lá
            // (ancorado no cursor; o gesto antigo nem dispararia, consumido).
            .background(CanvasEventBridge(
                store: store,
                onInteractionChanged: { active in
                    canvasInteracting = active
                }
            ) { screenPoint in
                let world = CanvasMath.telaParaMundo(screenPoint, viewport: store.viewport)
                presenceStore.updateLocal(
                    cursor: world, viewport: store.viewport,
                    selectedNodeID: store.selection
                )
            })
            .onAppear {
                store.canvasSize = geo.size
                installKeyMonitor()
            }
            .onDisappear(perform: removeMonitors)
            .onChange(of: geo.size) { _, novo in
                store.canvasSize = novo
            }
            .onChange(of: store.selection) { _, selection in
                presenceStore.updateContext(viewport: store.viewport, selectedNodeID: selection)
            }
            .onChange(of: store.viewport) { _, viewport in
                presenceStore.updateContext(viewport: viewport, selectedNodeID: store.selection, immediate: false)
            }
            .onChange(of: store.canvasViewMode) { _, mode in
                if mode == .atencao {
                    // A visão Atenção é uma visão operacional, não apenas um
                    // filtro: ao entrar nela, leva os cartões para a câmera.
                    store.focusAttention()
                }
            }
            }
        }
    }

    private var canvasModeBar: some View {
        HStack(spacing: 6) {
            ForEach(CanvasViewMode.allCases) { mode in
                Button {
                    store.canvasViewMode = mode
                } label: {
                    Label(mode.titulo, systemImage: mode.simbolo)
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(store.canvasViewMode == mode ? .accentColor : .secondary)
            }
            Spacer()
            if store.canvasViewMode == .missao && !store.missions.isEmpty {
                Menu {
                    Button("Todas as missões") { store.canvasFiltroMissao = nil }
                    Divider()
                    ForEach(store.missions, id: \.id) { mission in
                        Button {
                            store.canvasFiltroMissao = mission.id
                        } label: {
                            Label(mission.title, systemImage: mission.id == store.canvasFiltroMissao ? "checkmark" : "flag")
                        }
                    }
                } label: {
                    Label(
                        store.canvasMission?.title ?? "Selecionar missão",
                        systemImage: "flag.checkered")
                        .font(.caption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            if store.canvasFiltroMissao != nil {
                Button("Limpar filtro de missão") {
                    store.canvasFiltroMissao = nil
                }
                .font(.caption)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.thinMaterial)
    }

    private var visibleWorldRect: CGRect {
        let v = store.viewport
        return CGRect(
            x: v.x, y: v.y,
            width: Double(store.canvasSize.width) / v.zoom,
            height: Double(store.canvasSize.height) / v.zoom
        )
    }

    private var nodeLayer: some View {
        let zoom = store.viewport.zoom
        let margin = CanvasPerformancePolicy.preloadMargin(zoom: zoom)
        let visible = visibleWorldRect.insetBy(dx: -margin, dy: -margin)
        let ordered = store.nodes.values
            .filter { store.nodeIsVisibleOnActiveFloor($0.id) }
            .filter { store.matchesCanvasViewMode($0) }
            .filter { store.matchesSelectedMission($0) }
            .filter {
                visible.intersects(CGRect(
                    x: $0.posicao.x,
                    y: $0.posicao.y,
                    width: $0.tamanho.w,
                    height: $0.tamanho.h
                ))
            }
            .sorted { ($0.z, $0.id.string) < ($1.z, $1.id.string) }
        return ForEach(ordered, id: \.id) { node in
            let worldFrame = CGRect(x: node.posicao.x, y: node.posicao.y, width: node.tamanho.w, height: node.tamanho.h)
            NodeContainerView(
                node: node,
                zoom: zoom,
                conteudoVisivel: visible.intersects(worldFrame),
                isInteracting: canvasInteracting,
                onInteractionChanged: { active in
                    canvasInteracting = active
                }
            )
            .frame(width: node.tamanho.w, height: node.tamanho.h)
            .scaleEffect(zoom, anchor: .topLeading)
            .offset(
                x: (node.posicao.x - store.viewport.x) * zoom,
                y: (node.posicao.y - store.viewport.y) * zoom
            )
            .opacity(store.floorOpacity(for: node.id))
            .allowsHitTesting(store.floorOpacity(for: node.id) >= 0.99)
        }
    }

    private var attentionOverlay: some View {
        let agentCount = store.nodes.values.filter {
            store.nodeIsVisibleOnActiveFloor($0.id) && store.matchesCanvasViewMode($0)
        }.count
        let otherCount = store.pendingApprovals.count
            + store.openDecisions.count
            + store.deliveries.filter { $0.estado == .proposed || $0.estado == .reopened }.count
        let count = agentCount + otherCount
        return VStack {
            Spacer()
            HStack(spacing: 9) {
                Image(systemName: count == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(count == 0 ? Color.green : Color.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(count == 0 ? "Nothing needs attention" : "\(count) agent\(count == 1 ? "" : "s") need attention")
                        .font(.caption.weight(.semibold))
                    Text(count == 0
                         ? "Approvals, human input, and review requests will appear here."
                         : "These agents are waiting for approval or human input.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("Agora") {
                    NotificationCenter.default.post(name: .colmeiaShowNow, object: nil)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.quaternary, lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 14, y: 5)
            .padding(16)
        }
        .allowsHitTesting(true)
    }

    // MARK: - Gestos

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                canvasInteracting = true
                if panStart == nil { panStart = store.viewport }
                guard var v = panStart else { return }
                v.x -= Double(value.translation.width) / v.zoom
                v.y -= Double(value.translation.height) / v.zoom
                store.setViewport(v)
            }
            .onEnded { _ in
                panStart = nil
                canvasInteracting = false
            }
    }

    /// Esc duplo com um terminal focado devolve o foco ao canvas (Apêndice B).
    /// O primeiro Esc segue para o PTY (agentes usam Esc); keyDown do SwiftTerm
    /// não é `open`, então a interceptação é por monitor local.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        let store = self.store
        let lastEscBox = LastEscBox()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 51 || event.keyCode == 117,
               let window = event.window, window.isKeyWindow,
               let connID = store.connectionSelection,
               !(window.firstResponder is NSText),
               (window.firstResponder as? NSView).flatMap(terminalAncestral(of:)) == nil {
                store.deleteConnection(connID)
                return nil
            }
            guard event.keyCode == 53,
                  let window = event.window,
                  let responder = window.firstResponder as? NSView,
                  terminalAncestral(of: responder) != nil else {
                return event
            }
            if let last = lastEscBox.value, Date().timeIntervalSince(last) < 0.5 {
                lastEscBox.value = nil
                window.makeFirstResponder(nil)
                store.returnFocusToCanvas()
                return nil
            }
            lastEscBox.value = Date()
            return event
        }
    }

    private func removeMonitors() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }
}

private final class LastEscBox {
    var value: Date?
}

private func terminalAncestral(of view: NSView) -> TerminalView? {
    var atual: NSView? = view
    while let v = atual {
        if let terminal = v as? TerminalView { return terminal }
        atual = v.superview
    }
    return nil
}

/// Grade sutil indicando escala (§18.2).
struct GridBackground: View {
    let viewport: Viewport

    var body: some View {
        Canvas { context, size in
            let step = 100.0 * viewport.zoom
            guard step > 8 else { return }
            let offsetX = step - (viewport.x * viewport.zoom).truncatingRemainder(dividingBy: step)
            let offsetY = step - (viewport.y * viewport.zoom).truncatingRemainder(dividingBy: step)
            var path = Path()
            var x = offsetX.truncatingRemainder(dividingBy: step)
            while x < size.width {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                x += step
            }
            var y = offsetY.truncatingRemainder(dividingBy: step)
            while y < size.height {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                y += step
            }
            context.stroke(path, with: .color(.primary.opacity(0.06)), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

/// Chrome comum: arrasto (node.move), redimensionamento (node.resize), seleção,
/// alça de conexão (§5.3). Gestos medem no espaço nomeado do canvas: a base é
/// capturada no primeiro onChanged e a translação (tela ÷ zoom) aplicada sobre ela —
/// nunca sobre a posição corrente, que muda durante o gesto.
struct NodeContainerView: View {
    let node: Node
    let zoom: Double
    let conteudoVisivel: Bool
    let isInteracting: Bool
    let onInteractionChanged: (Bool) -> Void

    @EnvironmentObject private var store: AppStore
    @State private var dragBase: Ponto?
    @State private var resizeBase: Tamanho?
    @State private var redimensionando = false
    @State private var hovering = false
    @State private var conectando = false

    var body: some View {
        content
            .overlay(alignment: .bottomTrailing) { resizeHandle }
            .overlay(alignment: .trailing) { connectionHandle }
            .overlay {
                if store.selection == node.id {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.accentColor, lineWidth: 2 / zoom)
                }
            }
            .onTapGesture {
                store.selection = node.id
                store.connectionSelection = nil
            }
            .onHover { dentro in
                hovering = dentro
            }
    }

    @ViewBuilder
    private var content: some View {
        switch node {
        case .terminal(let terminal):
            TerminalNodeView(
                node: terminal,
                controller: store.terminalController(for: terminal.id),
                zoom: zoom,
                conteudoVisivel: conteudoVisivel,
                isInteracting: isInteracting,
                dragGesture: moveGesture
            )
        case .nota(let nota):
            NotaNodeView(node: nota, controller: store.notaController(for: nota), dragGesture: moveGesture)
        case .desenho(let desenho):
            DesenhoNodeView(node: desenho, dragGesture: moveGesture)
        case .portal(let portal):
            PortalNodeView(node: portal, controller: store.portalController(for: portal), dragGesture: moveGesture)
        }
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(CanvasSpace.nome))
            .onChanged { value in
                if dragBase == nil {
                    onInteractionChanged(true)
                    store.beginNodeDrag(node.id)
                    dragBase = store.nodeDragBase
                }
                guard let base = dragBase,
                      let destino = CanvasMath.destinoDoDrag(
                        base: base,
                        translacaoTela: Ponto(x: value.translation.width, y: value.translation.height),
                        zoom: zoom
                      ) else { return }
                store.dragNode(node.id, to: destino)
            }
            .onEnded { value in
                let base = dragBase
                dragBase = nil
                guard let base else { return }
                guard let destino = CanvasMath.destinoDoDrag(
                    base: base,
                    translacaoTela: Ponto(x: value.translation.width, y: value.translation.height),
                    zoom: zoom
                ) else {
                    store.cancelNodeDrag()
                    onInteractionChanged(false)
                    return
                }
                store.endNodeDrag(node.id, at: destino)
                onInteractionChanged(false)
            }
    }

    private var resizeHandle: some View {
        Group {
            if hovering || redimensionando || store.selection == node.id {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(6)
                    .background(.regularMaterial, in: Circle())
                    .contentShape(Circle())
                    .help("Arraste para redimensionar")
                    .accessibilityLabel("Redimensionar nó")
                    .accessibilityHint("Arraste para alterar largura e altura")
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .named(CanvasSpace.nome))
                            .onChanged { _ in
                                onInteractionChanged(true)
                                redimensionando = true
                                if resizeBase == nil { resizeBase = node.tamanho }
                            }
                            .onEnded { value in
                                let base = resizeBase ?? node.tamanho
                                resizeBase = nil
                                redimensionando = false
                                let minimo = tamanhoMinimo
                                let tamanho = Tamanho(
                                    w: max(minimo.w, base.w + Double(value.translation.width) / zoom),
                                    h: max(minimo.h, base.h + Double(value.translation.height) / zoom)
                                )
                                store.resizeNode(node.id, to: tamanho)
                                onInteractionChanged(false)
                            }
                    )
            }
        }
    }

    private var tamanhoMinimo: Tamanho {
        switch node {
        case .terminal: return Tamanho(w: 320, h: 200)
        case .nota: return Tamanho(w: 180, h: 120)
        case .portal: return Tamanho(w: 320, h: 220)
        case .desenho(let desenho) where desenho.texto != nil: return Tamanho(w: 32, h: 24)
        case .desenho: return Tamanho(w: 80, h: 60)
        }
    }

    /// Alça de conexão (§5.3): aparece no hover; arrastar até outro nó cria a
    /// Connection com a semântica do par (terminal→nota = escrita-de-nota,
    /// terminal→terminal = conversa, resto = visual).
    @ViewBuilder
    private var connectionHandle: some View {
        if hovering || conectando {
            ZStack {
                Circle()
                    .fill(Color(nsColor: .windowBackgroundColor))
                Circle()
                    .stroke(Color.accentColor, lineWidth: 1.5)
                Image(systemName: "link")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 16, height: 16)
            .contentShape(Circle().inset(by: -6))
            .offset(x: 8)
            .help("Arraste até outro nó para conectar")
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named(CanvasSpace.nome))
                    .onChanged { value in
                        conectando = true
                        let mundo = CanvasMath.telaParaMundo(
                            Ponto(x: value.location.x, y: value.location.y),
                            viewport: store.viewport
                        )
                        store.conexaoPendente = ConexaoPendente(de: node.id, ateMundo: mundo)
                    }
                    .onEnded { value in
                        conectando = false
                        store.conexaoPendente = nil
                        let mundo = CanvasMath.telaParaMundo(
                            Ponto(x: value.location.x, y: value.location.y),
                            viewport: store.viewport
                        )
                        if let alvo = store.node(atWorldPoint: mundo, excluindo: node.id) {
                            store.connect(from: node.id, to: alvo)
                        }
                    }
            )
        }
    }
}

/// Minimapa com indicador de viewport e pontos coloridos por estado (§18.2, PODE).
struct MinimapView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, size in
                let nodes = Array(store.nodes.values).filter { store.nodeIsVisibleOnActiveFloor($0.id) }
                guard !nodes.isEmpty else { return }
                func nodeRect(_ node: Node) -> CGRect {
                    CGRect(x: node.posicao.x, y: node.posicao.y, width: node.tamanho.w, height: node.tamanho.h)
                }
            var world = nodes.reduce(CGRect.null) { acc, node in
                acc.union(CGRect(x: node.posicao.x, y: node.posicao.y, width: node.tamanho.w, height: node.tamanho.h))
            }
            let viewRect = CGRect(
                x: store.viewport.x, y: store.viewport.y,
                width: Double(store.canvasSize.width) / store.viewport.zoom,
                height: Double(store.canvasSize.height) / store.viewport.zoom
            )
            world = world.union(viewRect).insetBy(dx: -200, dy: -200)
            let scale = min((size.width - 12) / world.width, (size.height - 12) / world.height)
            let originX = (size.width - world.width * scale) / 2
            let originY = (size.height - world.height * scale) / 2
            func map(_ rect: CGRect) -> CGRect {
                CGRect(
                    x: originX + (rect.minX - world.minX) * scale,
                    y: originY + (rect.minY - world.minY) * scale,
                    width: max(2, rect.width * scale),
                    height: max(2, rect.height * scale)
                )
            }
                // A miniatura também mostra a topologia — é muito mais útil para
                // encontrar um worker distante do que apenas uma nuvem de caixas.
                for connection in store.connections.values {
                    guard let from = store.nodes[connection.de], let to = store.nodes[connection.para],
                          store.nodeIsVisibleOnActiveFloor(from.id), store.nodeIsVisibleOnActiveFloor(to.id) else { continue }
                    let a = CGPoint(x: map(nodeRect(from)).midX, y: map(nodeRect(from)).midY)
                    let b = CGPoint(x: map(nodeRect(to)).midX, y: map(nodeRect(to)).midY)
                    var path = Path()
                    path.move(to: a)
                    path.addLine(to: b)
                    context.stroke(path, with: .color(.secondary.opacity(0.24)), lineWidth: 0.7)
                }
            for node in nodes {
                let rect = map(CGRect(x: node.posicao.x, y: node.posicao.y, width: node.tamanho.w, height: node.tamanho.h))
                let cor: SwiftUI.Color
                if case .terminal = node, let estado = store.terminalControllers[node.id]?.estado {
                    cor = EstadoStyle.cor(estado)
                } else {
                    cor = .secondary
                }
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(cor.opacity(0.8)))
            }
                context.fill(Path(roundedRect: map(viewRect), cornerRadius: 2), with: .color(.accentColor.opacity(0.10)))
                context.stroke(Path(roundedRect: map(viewRect), cornerRadius: 2), with: .color(.accentColor.opacity(0.9)), lineWidth: 1.2)
            }
            .padding(5)
            HStack(spacing: 4) {
                Image(systemName: "map")
                Text("MAPA")
            }
            .font(.system(size: 8, weight: .bold, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(8)
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.white.opacity(0.42), lineWidth: 0.8))
        .shadow(color: .black.opacity(0.10), radius: 12, y: 5)
        .opacity(0.94)
        .allowsHitTesting(false)
    }
}

/// Cores por estado (§18.3).
enum EstadoStyle {
    static func cor(_ estado: SessionEstado?) -> SwiftUI.Color {
        switch estado {
        case .rodando: return .green
        case .iniciando: return .teal
        case .esperandoHumano: return .orange
        case .aprovacaoPendente: return .red
        case .ociosa: return .secondary
        case .encerrada, .morta, .none: return .gray
        }
    }

    static func rotulo(_ estado: SessionEstado?) -> String {
        switch estado {
        case .rodando: return "rodando"
        case .iniciando: return "iniciando"
        case .esperandoHumano: return "aguardando"
        case .aprovacaoPendente: return "aprovação"
        case .ociosa: return "ociosa"
        case .encerrada: return "encerrada"
        case .morta: return "morta"
        case .none: return "sem sessão"
        }
    }
}
