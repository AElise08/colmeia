import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Content-addressable storage

public struct CASBlob: Codable, Equatable, Sendable {
    public let sha256: String
    public let byteCount: Int

    public init(sha256: String, byteCount: Int) {
        self.sha256 = sha256
        self.byteCount = byteCount
    }
}

public enum CASStoreError: Error, Equatable, Sendable, LocalizedError {
    case invalidHash(String)
    case blobNotFound(String)
    case integrityMismatch(expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case .invalidHash(let value): return "hash SHA-256 inválido: \(value)"
        case .blobNotFound(let value): return "blob CAS não encontrado: \(value)"
        case .integrityMismatch(let expected, let actual):
            return "integridade CAS inválida: esperado \(expected), recebido \(actual)"
        }
    }
}

/// CAS local. O actor serializa criação/leitura de blobs e mantém o filesystem
/// host fora do protocolo: a única identidade pública de um conteúdo é seu hash.
public actor ContentAddressedStore {
    private let paths: ColmeiaPaths
    private let fileManager = FileManager.default

    public init(paths: ColmeiaPaths) {
        self.paths = paths
    }

    public func put(_ data: Data) throws -> CASBlob {
        let hash = SHA256Digest.hex(data)
        let destination = try destination(for: hash)
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) {
            let existing = try Data(contentsOf: destination)
            let actual = SHA256Digest.hex(existing)
            guard actual == hash else {
                throw CASStoreError.integrityMismatch(expected: hash, actual: actual)
            }
            return CASBlob(sha256: hash, byteCount: existing.count)
        }

        let temporary = destination.appendingPathExtension("tmp-\(ULID.generate().string)")
        try data.write(to: temporary, options: [.atomic])
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        do {
            try fileManager.moveItem(at: temporary, to: destination)
        } catch CocoaError.fileWriteFileExists {
            // Outro escritor pode ter vencido a corrida. O conteúdo é aceito
            // somente depois da mesma validação de integridade.
            let existing = try Data(contentsOf: destination)
            let actual = SHA256Digest.hex(existing)
            guard actual == hash else {
                throw CASStoreError.integrityMismatch(expected: hash, actual: actual)
            }
        }
        return CASBlob(sha256: hash, byteCount: data.count)
    }

    public func putFile(at url: URL) throws -> CASBlob {
        try put(Data(contentsOf: url))
    }

    public func contains(_ hash: String) -> Bool {
        guard let url = try? destination(for: hash) else { return false }
        return fileManager.fileExists(atPath: url.path)
    }

    public func read(_ hash: String) throws -> Data {
        let url = try destination(for: hash)
        guard fileManager.fileExists(atPath: url.path) else {
            throw CASStoreError.blobNotFound(hash)
        }
        let data = try Data(contentsOf: url)
        let actual = SHA256Digest.hex(data)
        guard actual == hash.lowercased() else {
            throw CASStoreError.integrityMismatch(expected: hash.lowercased(), actual: actual)
        }
        return data
    }

    public func url(for hash: String) throws -> URL {
        try destination(for: hash)
    }

    private func destination(for hash: String) throws -> URL {
        let normalized = hash.lowercased()
        guard normalized.count == 64,
              normalized.unicodeScalars.allSatisfy({ "0123456789abcdef".unicodeScalars.contains($0) })
        else { throw CASStoreError.invalidHash(hash) }
        return paths.casBucket(String(normalized.prefix(2))).appendingPathComponent(normalized)
    }
}

public struct MerkleEntry: Codable, Equatable, Sendable {
    public let path: String
    public let sha256: String

    public init(path: String, sha256: String) {
        self.path = path
        self.sha256 = sha256
    }
}

public struct MerkleTree: Codable, Equatable, Sendable {
    public let entries: [MerkleEntry]
    public let rootHash: String

    public init(entries: [MerkleEntry]) {
        self.entries = entries.sorted { $0.path < $1.path }
        let canonical = self.entries.map { "\($0.path)\0\($0.sha256)" }.joined(separator: "\n")
        self.rootHash = SHA256Digest.hex(Data(canonical.utf8))
    }

    public static func fromFiles(at root: URL) throws -> MerkleTree {
        let fm = FileManager.default
        var entries: [MerkleEntry] = []
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return MerkleTree(entries: [])
        }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            entries.append(MerkleEntry(path: relative, sha256: SHA256Digest.hex(try Data(contentsOf: url))))
        }
        return MerkleTree(entries: entries)
    }
}

// MARK: - CRDT WAL and checksummed snapshots

public enum CRDTPersistenceError: Error, Equatable, Sendable, LocalizedError {
    case corruptSnapshot
    case malformedWAL(line: Int)

    public var errorDescription: String? {
        switch self {
        case .corruptSnapshot: return "snapshot CRDT corrompido"
        case .malformedWAL(let line): return "operação CRDT inválida na linha \(line)"
        }
    }
}

public actor CRDTOperationWAL {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func append(_ record: Data) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(fd) }
        var framed = record
        if framed.last != 0x0A { framed.append(0x0A) }
        try AtomicFile.writeAll(framed, to: fd, operation: "append crdt_ops.wal")
        _ = fsync(fd)
    }

    public func records() throws -> [Data] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        var result: [Data] = []
        var start = data.startIndex
        var line = 1
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: 0x0A) ?? data.endIndex
            let value = data[start..<end]
            if !value.isEmpty { result.append(Data(value)) }
            if end == data.endIndex { break }
            start = data.index(after: end)
            line += 1
        }
        return result
    }
}

public enum CRDTSQLiteSchema {
    public static let createOperationsTable = """
    CREATE TABLE IF NOT EXISTS crdt_ops (
        op_id TEXT PRIMARY KEY,
        target_id TEXT NOT NULL,
        crdt_type TEXT NOT NULL,
        payload BLOB NOT NULL,
        causal_deps TEXT,
        created_at INTEGER DEFAULT (strftime('%s', 'now'))
    );
    CREATE INDEX IF NOT EXISTS idx_target ON crdt_ops(target_id);
    """
}

public struct CRDTSnapshotEnvelope: Codable, Equatable, Sendable {
    public let checksum: String
    public let payload: Data

    public init(payload: Data) {
        self.payload = payload
        self.checksum = SHA256Digest.hex(payload)
    }

    public func validatedPayload() throws -> Data {
        let actual = SHA256Digest.hex(payload)
        guard actual == checksum else { throw CRDTPersistenceError.corruptSnapshot }
        return payload
    }
}

public actor CRDTSnapshotStore {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func write(_ payload: Data) throws {
        let envelope = CRDTSnapshotEnvelope(payload: payload)
        let data = try JSONEncoder().encode(envelope)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }

    public func read() throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let envelope = try JSONDecoder().decode(CRDTSnapshotEnvelope.self, from: Data(contentsOf: url))
            return try envelope.validatedPayload()
        } catch {
            throw CRDTPersistenceError.corruptSnapshot
        }
    }

    public func remove() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}

public struct CRDTRecoveryResult: Sendable, Equatable {
    public let payload: Data
    public let rebuiltFromWAL: Bool

    public init(payload: Data, rebuiltFromWAL: Bool) {
        self.payload = payload
        self.rebuiltFromWAL = rebuiltFromWAL
    }
}

/// Recuperação normativa: snapshot válido é usado diretamente; snapshot
/// corrompido é removido e o estado é reconstruído exclusivamente do WAL.
public actor CRDTRecoveryCoordinator {
    private let snapshot: CRDTSnapshotStore
    private let wal: CRDTOperationWAL

    public init(snapshot: CRDTSnapshotStore, wal: CRDTOperationWAL) {
        self.snapshot = snapshot
        self.wal = wal
    }

    public func recover(
        rebuildFromWAL: @Sendable ([Data]) throws -> Data
    ) async throws -> CRDTRecoveryResult {
        do {
            if let payload = try await snapshot.read() {
                return CRDTRecoveryResult(payload: payload, rebuiltFromWAL: false)
            }
        } catch CRDTPersistenceError.corruptSnapshot {
            try? await snapshot.remove()
        }
        let records = try await wal.records()
        let rebuilt = try rebuildFromWAL(records)
        return CRDTRecoveryResult(payload: rebuilt, rebuiltFromWAL: true)
    }
}

// MARK: - Minimal portable SHA-256

enum SHA256Digest {
    private static let constants: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b,
        0x59f111f1, 0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01,
        0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7,
        0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
        0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152,
        0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
        0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc,
        0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819,
        0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116, 0x1e376c08,
        0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f,
        0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
        0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    ]

    static func hex(_ data: Data) -> String {
        var message = Array(data)
        let bitLength = UInt64(message.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            message.append(UInt8((bitLength >> UInt64(shift)) & 0xff))
        }

        var h: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
        ]
        for chunkStart in stride(from: 0, to: message.count, by: 64) {
            var words = [UInt32](repeating: 0, count: 64)
            for i in 0..<16 {
                let offset = chunkStart + i * 4
                words[i] = UInt32(message[offset]) << 24
                    | UInt32(message[offset + 1]) << 16
                    | UInt32(message[offset + 2]) << 8
                    | UInt32(message[offset + 3])
            }
            for i in 16..<64 {
                let s0 = words[i - 15].rotatedRight(7) ^ words[i - 15].rotatedRight(18) ^ (words[i - 15] >> 3)
                let s1 = words[i - 2].rotatedRight(17) ^ words[i - 2].rotatedRight(19) ^ (words[i - 2] >> 10)
                words[i] = words[i - 16] &+ s0 &+ words[i - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3]
            var e = h[4], f = h[5], g = h[6], i = h[7]
            for round in 0..<64 {
                let s1 = e.rotatedRight(6) ^ e.rotatedRight(11) ^ e.rotatedRight(25)
                let choose = (e & f) ^ ((~e) & g)
                let temp1 = i &+ s1 &+ choose &+ constants[round] &+ words[round]
                let s0 = a.rotatedRight(2) ^ a.rotatedRight(13) ^ a.rotatedRight(22)
                let majority = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ majority
                i = g; g = f; f = e; e = d &+ temp1
                d = c; c = b; b = a; a = temp1 &+ temp2
            }
            h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d
            h[4] &+= e; h[5] &+= f; h[6] &+= g; h[7] &+= i
        }

        return h.map { String(format: "%08x", $0) }.joined()
    }
}

private extension UInt32 {
    func rotatedRight(_ amount: UInt32) -> UInt32 {
        (self >> amount) | (self << (32 - amount))
    }
}
