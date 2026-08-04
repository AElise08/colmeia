import Foundation

/// Políticas puras de renderização do canvas. A UI usa estas decisões para
/// manter a cena útil sem montar conteúdo caro fora do viewport.
public enum CanvasDetailLevel: String, Codable, Sendable {
    case full
    case compact
    case minimal
}

public enum CanvasPerformancePolicy {
    public static func preloadMargin(zoom: Double) -> Double {
        switch zoom {
        case ..<0.4: return 600
        case ..<0.8: return 400
        default: return 240
        }
    }

    public static func detailLevel(zoom: Double, interacting: Bool) -> CanvasDetailLevel {
        if interacting || zoom < 0.4 { return .minimal }
        if zoom < 0.8 { return .compact }
        return .full
    }

    public static func shouldAnimateConnections(interacting: Bool, reduceMotion: Bool) -> Bool {
        !interacting && !reduceMotion
    }
}
