import SwiftUI
import ColmeiaKit

/// Linguagem visual compartilhada pelo canvas. O ambiente fica escuro e calmo;
/// a cor só aparece quando comunica uma condição operacional.
enum ColmeiaCanvasTheme {
    static let ink = Color(red: 0.93, green: 0.95, blue: 0.98)
    static let mutedInk = Color(red: 0.57, green: 0.62, blue: 0.69)
    static let canvas = Color(red: 0.035, green: 0.045, blue: 0.06)
    static let surface = Color(red: 0.075, green: 0.09, blue: 0.115)
    static let surfaceRaised = Color(red: 0.105, green: 0.125, blue: 0.155)
    static let line = Color.white.opacity(0.11)
    static let amber = Color(red: 1.0, green: 0.68, blue: 0.22)
    static let cyan = Color(red: 0.28, green: 0.78, blue: 0.92)
    static let violet = Color(red: 0.62, green: 0.47, blue: 0.96)

    static func status(_ status: SessionEstado?) -> Color {
        switch status {
        case .rodando: return Color(red: 0.30, green: 0.84, blue: 0.56)
        case .iniciando: return cyan
        case .esperandoHumano: return amber
        case .aprovacaoPendente: return Color(red: 1.0, green: 0.32, blue: 0.34)
        case .ociosa: return mutedInk
        case .encerrada, .morta, .none: return Color(red: 0.40, green: 0.44, blue: 0.50)
        }
    }
}

/// Atmosfera azul leve, sem competir com notas, terminais ou alertas. É uma
/// camada estática segura para máquinas sem Metal; o renderer GPU acrescenta o
/// movimento sutil quando disponível.
struct CanvasAtmosphere: View {
    var body: some View {
        ZStack {
            ColmeiaCanvasTheme.canvas
            RadialGradient(
                colors: [ColmeiaCanvasTheme.cyan.opacity(0.13), .clear],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 620
            )
            RadialGradient(
                colors: [Color(red: 0.10, green: 0.18, blue: 0.42).opacity(0.12), .clear],
                center: .bottomLeading,
                startRadius: 30,
                endRadius: 760
            )
        }
    }
}

struct CanvasSurface<Content: View>: View {
    let content: Content
    var padding: CGFloat = 12
    var radius: CGFloat = 14

    init(padding: CGFloat = 12, radius: CGFloat = 14, @ViewBuilder content: () -> Content) {
        self.content = content()
        self.padding = padding
        self.radius = radius
    }

    var body: some View {
        content
            .padding(padding)
            .background(ColmeiaCanvasTheme.surface.opacity(0.94), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(ColmeiaCanvasTheme.line, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
    }
}
