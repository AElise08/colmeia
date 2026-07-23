import Foundation
import Darwin

public enum SocketFramingError: Error, Equatable, CustomStringConvertible {
    case writeFailed(errno: Int32)
    case connectionClosed

    public var description: String {
        switch self {
        case .writeFailed(let code):
            return "write falhou: \(String(cString: strerror(code)))"
        case .connectionClosed:
            return "conexão fechada"
        }
    }
}

/// Framing NDJSON (§6.1): uma mensagem JSON por linha `\n`, UTF-8, sem `\n` interno cru.
/// Utilitário compartilhado por cliente (SocketClient) e servidor (engine).
public enum SocketFraming {
    /// JSON de linha única — o JSONEncoder sem pretty-print nunca emite `\n` cru.
    public static func encodeLine(_ value: some Encodable) throws -> Data {
        try ColmeiaJSON.encoder().encode(value)
    }

    public static func decodeLine<T: Decodable>(_ type: T.Type, from line: Data) throws -> T {
        try ColmeiaJSON.decoder().decode(type, from: line)
    }

    /// Escreve `data` + `\n`, tolerando escritas parciais e EINTR.
    public static func writeLine(fd: Int32, _ data: Data) throws {
        var frame = data
        frame.append(0x0A)
        try frame.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < buffer.count {
                let written = write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0 && errno == EINTR {
                    continue
                } else {
                    throw SocketFramingError.writeFailed(errno: errno)
                }
            }
        }
    }

    /// Acumula chunks e devolve linhas completas (sem o `\n`). Linhas vazias são descartadas.
    public final class LineBuffer {
        private var buffer = Data()

        public init() {}

        public func append(_ chunk: Data) -> [Data] {
            buffer.append(chunk)
            var lines: [Data] = []
            while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<newlineIndex)
                buffer.removeSubrange(buffer.startIndex...newlineIndex)
                if !line.isEmpty {
                    lines.append(line)
                }
            }
            return lines
        }
    }
}
