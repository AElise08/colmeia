import Foundation

// §11.4 — entrada da fila offline durável do Hub. Append-only em
// `rooms/<id>/outbox.jsonl`; sobrevive a reinício e a rede intermitente.
public struct HubOutboxEntry: Codable, Equatable, Sendable {
    public var id: ULID
    public var enqueuedAt: Date
    public var method: ColmeiaMethod
    public var paramsJSON: Data
    /// Reutilizado no replay para que o Hub possa devolver a resposta já
    /// aplicada quando a conexão caiu depois da mutação.
    public var requestID: String?
    public var tentativas: Int
    public var ultimoErro: String?

    enum CodingKeys: String, CodingKey {
        case id, method, requestID = "request_id", tentativas
        case enqueuedAt = "enqueued_at"
        case paramsJSON = "params_json"
        case ultimoErro = "ultimo_erro"
    }

    public init(
        id: ULID = ULID.generate(),
        enqueuedAt: Date = Date(),
        method: ColmeiaMethod,
        paramsJSON: Data,
        requestID: String? = nil,
        tentativas: Int = 0,
        ultimoErro: String? = nil
    ) {
        self.id = id
        self.enqueuedAt = enqueuedAt
        self.method = method
        self.paramsJSON = paramsJSON
        self.requestID = requestID
        self.tentativas = tentativas
        self.ultimoErro = ultimoErro
    }
}

/// Fila durável por sala. A UI DEVE exibir entradas pendentes (§11.4).
public final class HubOutbox: @unchecked Sendable {
    public let roomID: ULID
    public let paths: ColmeiaPaths
    private let lock = NSLock()
    private var entries: [HubOutboxEntry]

    public init(roomID: ULID, paths: ColmeiaPaths) {
        self.roomID = roomID
        self.paths = paths
        self.entries = HubOutbox.loadEntries(roomID: roomID, paths: paths)
    }

    /// Enfileira a entrada (durable: fsync após escrita).
    @discardableResult
    public func enqueue(
        method: ColmeiaMethod,
        paramsJSON: Data,
        requestID: String? = nil
    ) throws -> HubOutboxEntry {
        let entry = HubOutboxEntry(method: method, paramsJSON: paramsJSON, requestID: requestID)
        lock.lock(); defer { lock.unlock() }
        entries.append(entry)
        try persistLocked()
        return entry
    }

    public func pending() -> [HubOutboxEntry] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }

    public func remove(id: ULID) throws {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll { $0.id == id }
        try persistLocked()
    }

    public func markFailure(id: ULID, error: String) throws {
        lock.lock(); defer { lock.unlock() }
        if let i = entries.firstIndex(where: { $0.id == id }) {
            entries[i].tentativas += 1
            entries[i].ultimoErro = error
            try persistLocked()
        }
    }

    public var pendingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }

    private func persistLocked() throws {
        let dir = paths.roomDir(roomID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = paths.roomOutboxFile(roomID)
        var data = Data()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        for entry in entries {
            let line = try encoder.encode(entry)
            data.append(line)
            data.append(0x0A) // \n
        }
        try data.write(to: fileURL, options: [.atomic])
    }

    private static func loadEntries(roomID: ULID, paths: ColmeiaPaths) -> [HubOutboxEntry] {
        let url = paths.roomOutboxFile(roomID)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let raw = (try? Data(contentsOf: url)) ?? Data()
        var entries: [HubOutboxEntry] = []
        var start = raw.startIndex
        while start < raw.endIndex {
            guard let end = raw[start...].firstIndex(of: 0x0A) else { break }
            let line = raw[start..<end]
            if let entry = try? decoder.decode(HubOutboxEntry.self, from: line) {
                entries.append(entry)
            }
            start = raw.index(after: end)
        }
        return entries
    }
}
