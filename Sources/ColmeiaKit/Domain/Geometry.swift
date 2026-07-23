import Foundation

/// Coordenadas do canvas (§5.2).
public struct Ponto: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct Tamanho: Codable, Equatable, Sendable {
    public var w: Double
    public var h: Double

    public init(w: Double, h: Double) {
        self.w = w
        self.h = h
    }
}

/// §5.1 — zoom válido: 0.1–4.0.
public struct Viewport: Codable, Equatable, Sendable {
    public static let zoomRange: ClosedRange<Double> = 0.1...4.0

    public var x: Double
    public var y: Double
    public var zoom: Double

    public init(x: Double = 0, y: Double = 0, zoom: Double = 1.0) {
        self.x = x
        self.y = y
        self.zoom = zoom
    }
}
