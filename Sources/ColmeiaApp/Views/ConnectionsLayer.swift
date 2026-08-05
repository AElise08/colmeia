import SwiftUI
import ColmeiaKit

/// §5.3 — conexões como linhas entre as bordas dos nós (tracejada/sólida), vivas
/// durante drag/pan/zoom (posições vêm do espelho do store). Clique seleciona
/// (Delete apaga); menu de contexto apaga direto.
struct ConnectionsLayer: View {
    let isInteracting: Bool

    @EnvironmentObject private var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topLeading) {
            if !isInteracting && !reduceMotion && hasRecentActivity {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { timeline in
                    connectionLines(now: timeline.date)
                }
            } else {
                connectionLines(now: nil)
            }
            pendingLine
        }
    }

    @ViewBuilder
    private func connectionLines(now: Date?) -> some View {
        ForEach(visibleConnections, id: \.id) { connection in
            ConnectionLineView(connection: connection, isInteracting: isInteracting, now: now)
        }
    }

    private var hasRecentActivity: Bool {
        store.connectionActivities.values.contains {
            Date().timeIntervalSince($0.startedAt) < 1.5
        }
    }

    private var visibleConnections: [Connection] {
        let viewport = CGRect(
            x: store.viewport.x,
            y: store.viewport.y,
            width: Double(store.canvasSize.width) / store.viewport.zoom,
            height: Double(store.canvasSize.height) / store.viewport.zoom
        ).insetBy(dx: CanvasPerformancePolicy.preloadMargin(zoom: store.viewport.zoom),
                  dy: CanvasPerformancePolicy.preloadMargin(zoom: store.viewport.zoom))

        return store.connections.values.filter { connection in
            guard let from = store.nodes[connection.de], let to = store.nodes[connection.para],
                  store.nodeIsVisibleOnActiveFloor(from.id), store.nodeIsVisibleOnActiveFloor(to.id) else {
                return false
            }
            let fromRect = worldRect(from)
            let toRect = worldRect(to)
            return viewport.intersects(fromRect) || viewport.intersects(toRect)
        }
    }

    @ViewBuilder
    private var pendingLine: some View {
        if let pendente = store.conexaoPendente, let origem = store.nodes[pendente.de] {
            let rect = worldRect(origem)
            let alvo = CGPoint(x: pendente.ateMundo.x, y: pendente.ateMundo.y)
            let de = CanvasMath.pontoDeBorda(rect: rect, em: alvo)
            Path { path in
                path.move(to: tela(de))
                path.addLine(to: tela(alvo))
            }
            .stroke(
                Color.accentColor.opacity(0.7),
                style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 4])
            )
            .allowsHitTesting(false)
        }
    }

    private func tela(_ p: CGPoint) -> CGPoint {
        let convertido = CanvasMath.mundoParaTela(Ponto(x: p.x, y: p.y), viewport: store.viewport)
        return CGPoint(x: convertido.x, y: convertido.y)
    }
}

private func worldRect(_ node: Node) -> CGRect {
    CGRect(x: node.posicao.x, y: node.posicao.y, width: node.tamanho.w, height: node.tamanho.h)
}

struct ConnectionLineView: View {
    let connection: Connection
    let isInteracting: Bool
    let now: Date?

    @EnvironmentObject private var store: AppStore

    private func tela(_ p: CGPoint) -> CGPoint {
        let convertido = CanvasMath.mundoParaTela(Ponto(x: p.x, y: p.y), viewport: store.viewport)
        return CGPoint(x: convertido.x, y: convertido.y)
    }

    var body: some View {
        if store.nodeIsVisibleOnActiveFloor(connection.de),
           store.nodeIsVisibleOnActiveFloor(connection.para),
           let de = store.nodes[connection.de],
           let para = store.nodes[connection.para] {
            if let activity, let now, !isInteracting,
               now.timeIntervalSince(activity.startedAt) < 1.5 {
                let elapsed = max(0, now.timeIntervalSince(activity.startedAt))
                let pulse = max(0, 1 - elapsed / 1.5)
                rope(de: de, para: para, time: elapsed, pulse: pulse, activity: activity.activity)
            } else {
                rope(de: de, para: para, time: 0, pulse: 0, activity: nil)
            }
        }
    }

    @ViewBuilder
    private func rope(
        de: Node, para: Node, time: TimeInterval, pulse: Double,
        activity: ConnectionActivityKind?
    ) -> some View {
        let (a, b) = CanvasMath.ancorasDeConexao(de: worldRect(de), para: worldRect(para))
        let inicio = tela(a)
        let fim = tela(b)
        let selecionada = store.connectionSelection == connection.id
        let geometria = linha(inicio, fim, time: time, pulse: pulse)
        let opacidade = min(store.floorOpacity(for: connection.de), store.floorOpacity(for: connection.para))

        geometria.path
            // Halo translúcido: dá a sensação de corda sobre o vidro sem tornar
            // as conexões pesadas no canvas com muitos nós.
            .stroke(pulseColor(activity).opacity(selecionada ? 0.30 : 0.14 + pulse * 0.20),
                    style: StrokeStyle(lineWidth: selecionada ? 8 : 6 + pulse * 4, lineCap: .round))
            .overlay {
                geometria.path.stroke(pulseColor(activity).opacity(selecionada ? 1 : 0.72 + pulse * 0.28), style: StrokeStyle(
                    lineWidth: selecionada ? 3 : 2 + pulse * 1.5,
                    lineCap: .round,
                    dash: connection.estilo == .tracejada ? [6, 5] : []
                ))
            }
            .overlay(seta(em: fim, vindoDe: geometria.controleFinal))
            .contentShape(geometria.path.strokedPath(StrokeStyle(lineWidth: 16, lineCap: .round)))
            .onTapGesture {
                store.connectionSelection = connection.id
                store.selection = nil
            }
            .contextMenu {
                Text(rotulo)
                Button("Apagar conexão", role: .destructive) {
                    store.deleteConnection(connection.id)
                }
            }
            .opacity(opacidade)
            .allowsHitTesting(opacidade >= 0.99)
    }

    /// Curva cúbica com uma oscilação pequena no eixo perpendicular. Nos nós
    /// próximos ela se aproxima de uma reta; nos distantes, ganha a folga de uma
    /// corda. O phase é estável por conexão, então as linhas não pulam ao render.
    private func linha(
        _ inicio: CGPoint, _ fim: CGPoint, time: TimeInterval, pulse: Double
    ) -> (path: Path, controleFinal: CGPoint) {
        let dx = fim.x - inicio.x
        let dy = fim.y - inicio.y
        let distance = max(1, hypot(dx, dy))
        let perpendicular = CGPoint(x: -dy / distance, y: dx / distance)
        let phase = Double(connection.id.string.unicodeScalars.reduce(0) { ($0 &* 33) &+ Int($1.value) } % 628) / 100
        let amplitude = min(11, max(2, distance * 0.025)) * pulse * sin(time * 8 + phase)
        let sag = min(22, distance * 0.07)
        let middle = CGPoint(x: (inicio.x + fim.x) / 2, y: (inicio.y + fim.y) / 2 + sag)
        let control1 = CGPoint(x: inicio.x + dx * 0.30 + perpendicular.x * amplitude, y: inicio.y + dy * 0.30 + perpendicular.y * amplitude + sag * 0.55)
        let control2 = CGPoint(x: fim.x - dx * 0.30 - perpendicular.x * amplitude, y: fim.y - dy * 0.30 - perpendicular.y * amplitude + sag * 0.55)
        // Recentrar ligeiramente os controles impede que uma corda quase vertical
        // pareça uma parábola muito pesada.
        let finalControl = CGPoint(x: (control2.x + middle.x) / 2, y: (control2.y + middle.y) / 2)
        let path = Path { path in
            path.move(to: inicio)
            path.addCurve(to: fim, control1: control1, control2: finalControl)
        }
        return (path, finalControl)
    }

    private func seta(em ponta: CGPoint, vindoDe origem: CGPoint) -> some View {
        let angulo = atan2(ponta.y - origem.y, ponta.x - origem.x)
        let tamanho = 8.0
        return Path { path in
            for delta in [Double.pi * 0.85, -Double.pi * 0.85] {
                path.move(to: ponta)
                path.addLine(to: CGPoint(
                    x: ponta.x + cos(angulo + delta) * tamanho,
                    y: ponta.y + sin(angulo + delta) * tamanho
                ))
            }
        }
        .stroke(cor.opacity(0.8), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        .allowsHitTesting(false)
    }

    private var cor: Color {
        switch connection.semantica {
        case .escritaDeNota: return ColmeiaCanvasTheme.amber
        case .conversa: return ColmeiaCanvasTheme.cyan
        case .visual: return ColmeiaCanvasTheme.mutedInk
        }
    }

    private var activity: ConnectionActivityEvent? {
        store.connectionActivities[connection.id]
    }

    private func pulseColor(_ activity: ConnectionActivityKind?) -> Color {
        switch activity {
        case .message: return ColmeiaCanvasTheme.cyan
        case .delegation: return ColmeiaCanvasTheme.violet
        case .contextTransfer: return Color.teal
        case .delivery: return Color.green
        case .approval: return ColmeiaCanvasTheme.amber
        case .error: return .red
        case nil: return cor
        }
    }

    private var rotulo: String {
        switch connection.semantica {
        case .escritaDeNota: return "escrita-de-nota"
        case .conversa: return "conversa"
        case .visual: return "visual"
        }
    }
}
