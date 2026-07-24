import SwiftUI
import ColmeiaKit

/// §5.3 — conexões como linhas entre as bordas dos nós (tracejada/sólida), vivas
/// durante drag/pan/zoom (posições vêm do espelho do store). Clique seleciona
/// (Delete apaga); menu de contexto apaga direto.
struct ConnectionsLayer: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(store.connections.values), id: \.id) { connection in
                ConnectionLineView(connection: connection)
            }
            pendingLine
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

    @EnvironmentObject private var store: AppStore

    private func tela(_ p: CGPoint) -> CGPoint {
        let convertido = CanvasMath.mundoParaTela(Ponto(x: p.x, y: p.y), viewport: store.viewport)
        return CGPoint(x: convertido.x, y: convertido.y)
    }

    var body: some View {
        if let de = store.nodes[connection.de], let para = store.nodes[connection.para] {
            let (a, b) = CanvasMath.ancorasDeConexao(de: worldRect(de), para: worldRect(para))
            let inicio = tela(a)
            let fim = tela(b)
            let selecionada = store.connectionSelection == connection.id
            let caminho = linha(inicio, fim)

            caminho
                .stroke(cor.opacity(selecionada ? 1 : 0.65), style: StrokeStyle(
                    lineWidth: selecionada ? 3 : 2,
                    lineCap: .round,
                    dash: connection.estilo == .tracejada ? [6, 5] : []
                ))
                .overlay(seta(em: fim, vindoDe: inicio))
                .contentShape(caminho.strokedPath(StrokeStyle(lineWidth: 14, lineCap: .round)))
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
        }
    }

    private func linha(_ inicio: CGPoint, _ fim: CGPoint) -> Path {
        Path { path in
            path.move(to: inicio)
            path.addLine(to: fim)
        }
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
        case .escritaDeNota: return .orange
        case .conversa: return .blue
        case .visual: return .secondary
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
