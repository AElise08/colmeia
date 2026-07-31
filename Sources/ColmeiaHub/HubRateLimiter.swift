import Foundation

/// Limite simples por conexão para impedir que um cliente monopolize o Hub com
/// NDJSON ou frames muito grandes. A janela é deslizante e protegida porque a
/// leitura e a resposta de uma conexão usam filas diferentes.
public final class HubRateLimiter: @unchecked Sendable {
    public let maxRequestsPerSecond: Int
    public let maxBytesPerSecond: Int
    public let maxRequestBytes: Int

    private let lock = NSLock()
    private var requests: [Date] = []
    private var byteSamples: [(Date, Int)] = []

    public init(
        maxRequestsPerSecond: Int = 120,
        maxBytesPerSecond: Int = 2 * 1024 * 1024,
        maxRequestBytes: Int = 1 * 1024 * 1024
    ) {
        self.maxRequestsPerSecond = max(1, maxRequestsPerSecond)
        self.maxBytesPerSecond = max(1, maxBytesPerSecond)
        self.maxRequestBytes = max(1, maxRequestBytes)
    }

    public func allow(bytes: Int, now: Date = Date()) -> Bool {
        guard bytes >= 0, bytes <= maxRequestBytes else { return false }
        let cutoff = now.addingTimeInterval(-1)
        lock.lock()
        defer { lock.unlock() }
        requests.removeAll { $0 < cutoff }
        byteSamples.removeAll { $0.0 < cutoff }
        let totalBytes = byteSamples.reduce(0) { $0 + $1.1 }
        guard requests.count < maxRequestsPerSecond,
              totalBytes + bytes <= maxBytesPerSecond else { return false }
        requests.append(now)
        byteSamples.append((now, bytes))
        return true
    }
}
