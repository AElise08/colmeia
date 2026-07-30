import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Coders canônicos do projeto. Timestamps são ISO-8601 UTC com milissegundos (§0);
/// na leitura aceita-se também sem fração. Todo JSON do protocolo/storage DEVE passar por aqui.
public enum ColmeiaJSON {
    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    public static func string(from date: Date) -> String {
        isoFractional.string(from: date)
    }

    public static func date(from string: String) -> Date? {
        isoFractional.date(from: string) ?? isoPlain.date(from: string)
    }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(string(from: date))
        }
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let date = date(from: raw) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "timestamp não é ISO-8601: \(raw)"
                )
            }
            return date
        }
        return decoder
    }
}

public enum EngineFailure: Error, CustomStringConvertible, Equatable, Sendable {
    case io(String, Int32)

    public var description: String {
        switch self {
        case .io(let what, let code):
            return "\(what): \(String(cString: strerror(code)))"
        }
    }
}

public final class StorageHealth: @unchecked Sendable {
    public static let shared = StorageHealth()

    private let lock = NSLock()
    private var _readOnlyForNewSessions = false
    private var _lastFailure: (code: Int32, operation: String)?

    public var readOnlyForNewSessions: Bool {
        lock.lock(); defer { lock.unlock() }
        return _readOnlyForNewSessions
    }

    public var lastFailure: (code: Int32, operation: String)? {
        lock.lock(); defer { lock.unlock() }
        return _lastFailure
    }

    public func recordWriteFailure(_ code: Int32, operation: String) {
        guard code == ENOSPC || code == EDQUOT else { return }
        lock.lock()
        _readOnlyForNewSessions = true
        _lastFailure = (code, operation)
        lock.unlock()
    }

    public func clearAfterSuccessfulWrite() {
        lock.lock()
        _readOnlyForNewSessions = false
        _lastFailure = nil
        lock.unlock()
    }

    public func resetForTesting() {
        lock.lock()
        _readOnlyForNewSessions = false
        _lastFailure = nil
        lock.unlock()
    }
}

public enum StorageFaultInjection {
    private struct Failure {
        let errno: Int32
        let operationContaining: String?
    }
    private static let lock = NSLock()
    private static var nextWriteFailure: Failure?

    public static func failNextWriteForTesting(errno: Int32, operationContaining: String? = nil) {
        lock.lock()
        nextWriteFailure = Failure(errno: errno, operationContaining: operationContaining)
        lock.unlock()
    }

    public static func consumeWriteFailure(operation: String) -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        guard let failure = nextWriteFailure,
              failure.operationContaining.map({ operation.contains($0) }) ?? true
        else { return nil }
        nextWriteFailure = nil
        return failure.errno
    }
}

public enum AtomicFile {
    public static func replace(_ data: Data, at url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temp = directory.appendingPathComponent(
            ".\(url.lastPathComponent).tmp-\(getpid())-\(UUID().uuidString)")
        var fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw EngineFailure.io("open \(temp.lastPathComponent)", errno) }
        do {
            try writeAll(data, to: fd, operation: "write \(url.lastPathComponent)")
            guard fsync(fd) == 0 else {
                StorageHealth.shared.recordWriteFailure(errno, operation: "fsync \(url.lastPathComponent)")
                throw EngineFailure.io("fsync \(temp.lastPathComponent)", errno)
            }
            #if canImport(Darwin)
            let closeResult = Darwin.close(fd)
            #elseif canImport(Glibc)
            let closeResult = Glibc.close(fd)
            #endif
            fd = -1
            guard closeResult == 0 else { throw EngineFailure.io("close \(temp.lastPathComponent)", errno) }
            if rename(temp.path, url.path) != 0 {
                StorageHealth.shared.recordWriteFailure(errno, operation: "rename \(url.lastPathComponent)")
                throw EngineFailure.io("rename \(url.lastPathComponent)", errno)
            }
            try syncDirectory(directory)
            StorageHealth.shared.clearAfterSuccessfulWrite()
        } catch {
            if fd >= 0 {
                #if canImport(Darwin)
                _ = Darwin.close(fd)
                #elseif canImport(Glibc)
                _ = Glibc.close(fd)
                #endif
            }
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    public static func writeAll(_ data: Data, to fd: Int32, operation: String) throws {
        if let injected = StorageFaultInjection.consumeWriteFailure(operation: operation) {
            StorageHealth.shared.recordWriteFailure(injected, operation: operation)
            throw EngineFailure.io(operation, injected)
        }
        var failure: Int32?
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < buffer.count {
                let written = write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if written > 0 { offset += written }
                else if written < 0 && errno == EINTR { continue }
                else { failure = errno; return }
            }
        }
        if let failure {
            StorageHealth.shared.recordWriteFailure(failure, operation: operation)
            throw EngineFailure.io(operation, failure)
        }
    }

    public static func syncDirectory(_ directory: URL) throws {
        let fd = open(directory.path, O_RDONLY)
        guard fd >= 0 else { throw EngineFailure.io("open diretório \(directory.lastPathComponent)", errno) }
        defer {
            #if canImport(Darwin)
            _ = Darwin.close(fd)
            #elseif canImport(Glibc)
            _ = Glibc.close(fd)
            #endif
        }
        guard fsync(fd) == 0 else { throw EngineFailure.io("fsync diretório \(directory.lastPathComponent)", errno) }
    }
}

public enum AtomicJSON {
    public static func write(_ value: some Encodable, to url: URL) throws {
        let data = try ColmeiaJSON.encoder().encode(value)
        try AtomicFile.replace(data, at: url)
    }

    public static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        return try ColmeiaJSON.decoder().decode(type, from: data)
    }
}
