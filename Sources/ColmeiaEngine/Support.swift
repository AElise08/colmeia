import Foundation
import Darwin
import ColmeiaKit

// MARK: - Log estruturado (§22.6)

/// `engine.log`: JSON por linha `{ts, nivel, name, session_id?, workspace_id?, message}`.
public final class EngineLog: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32 = -1
    private let mirrorToStderr: Bool

    public init(url: URL?, mirrorToStderr: Bool = false) {
        self.mirrorToStderr = mirrorToStderr
        if let url {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        }
    }

    public func log(
        _ nivel: String, _ name: String, _ message: String,
        sessionID: ULID? = nil, workspaceID: ULID? = nil
    ) {
        var object: [String: JSONValue] = [
            "ts": .string(ColmeiaJSON.string(from: Date())),
            "nivel": .string(nivel),
            "name": .string(name),
            "message": .string(message),
        ]
        if let sessionID { object["session_id"] = .string(sessionID.string) }
        if let workspaceID { object["workspace_id"] = .string(workspaceID.string) }
        guard var data = try? ColmeiaJSON.encoder().encode(JSONValue.object(object)) else { return }
        data.append(0x0A)
        lock.lock()
        defer { lock.unlock() }
        if fd >= 0 {
            data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let written = write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    if written > 0 { offset += written } else if written < 0 && errno == EINTR { continue } else { break }
                }
            }
        }
        if mirrorToStderr {
            FileHandle.standardError.write(data)
        }
    }

    public func info(_ name: String, _ message: String, sessionID: ULID? = nil, workspaceID: ULID? = nil) {
        log("info", name, message, sessionID: sessionID, workspaceID: workspaceID)
    }

    public func warn(_ name: String, _ message: String, sessionID: ULID? = nil, workspaceID: ULID? = nil) {
        log("warn", name, message, sessionID: sessionID, workspaceID: workspaceID)
    }

    public func error(_ name: String, _ message: String, sessionID: ULID? = nil, workspaceID: ULID? = nil) {
        log("error", name, message, sessionID: sessionID, workspaceID: workspaceID)
    }

    deinit {
        if fd >= 0 { close(fd) }
    }
}

// MARK: - Escrita atômica (§20.2)

enum AtomicJSON {
    /// temp + rename no mesmo diretório.
    static func write(_ value: some Encodable, to url: URL) throws {
        let data = try ColmeiaJSON.encoder().encode(value)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp-\(getpid())")
        try data.write(to: temp, options: [])
        if rename(temp.path, url.path) != 0 {
            let code = errno
            try? FileManager.default.removeItem(at: temp)
            throw EngineFailure.io("rename \(url.lastPathComponent)", code)
        }
    }

    static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        return try ColmeiaJSON.decoder().decode(type, from: data)
    }
}

// MARK: - Lock de instância única (§20.5)

enum InstanceLock {
    /// flock não-bloqueante + pid gravado. Retorna o fd detido, ou nil se outra instância vive.
    static func acquire(at url: URL) -> Int32? {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_WRONLY | O_CREAT, 0o600)
        guard fd >= 0 else { return nil }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return nil
        }
        _ = ftruncate(fd, 0)
        let pid = "\(getpid())\n"
        _ = pid.withCString { write(fd, $0, strlen($0)) }
        return fd
    }
}

// MARK: - Falhas internas

enum EngineFailure: Error, CustomStringConvertible {
    case io(String, Int32)

    var description: String {
        switch self {
        case .io(let what, let code):
            return "\(what): \(String(cString: strerror(code)))"
        }
    }
}

// MARK: - Texto

enum TerminalText {
    private static let ansiRegex = try! NSRegularExpression(
        // CSI, OSC (até BEL ou ST) e escapes de 2 bytes.
        pattern: "\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)|\u{1B}\\[[0-9;?]*[ -/]*[@-~]|\u{1B}[@-_]"
    )

    /// Remove escapes ANSI/OSC e controles (menos \n e \t) — para heurísticas e respostas de `ask`.
    static func stripANSI(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let cleaned = ansiRegex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        return String(cleaned.unicodeScalars.filter { scalar in
            scalar == "\n" || scalar == "\t" || scalar.value >= 0x20
        }).replacingOccurrences(of: "\r", with: "")
    }

    static func decodeLossy(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }
}

/// §23.3 — nomes usados em caminhos: `[a-z0-9-]`, tamanho limitado.
func sanitizarNome(_ nome: String) -> String {
    var out = ""
    for scalar in nome.lowercased().unicodeScalars {
        if (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9") || scalar == "-" {
            out.unicodeScalars.append(scalar)
        } else if scalar == " " || scalar == "_" || scalar == "/" {
            out.append("-")
        }
    }
    while out.hasPrefix("-") { out.removeFirst() }
    while out.hasSuffix("-") { out.removeLast() }
    return String(out.prefix(48))
}

/// §23.3 — containment: o caminho resolvido DEVE ser descendente da base esperada.
func caminhoContido(_ caminho: String, em base: String) -> Bool {
    let child = URL(fileURLWithPath: caminho).standardizedFileURL.path
    let parent = URL(fileURLWithPath: base).standardizedFileURL.path
    return child == parent || child.hasPrefix(parent + "/")
}

func which(_ binario: String) -> Bool {
    if binario.contains("/") {
        return FileManager.default.isExecutableFile(atPath: binario)
    }
    let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/local/bin"
    for dir in path.split(separator: ":") {
        if FileManager.default.isExecutableFile(atPath: "\(dir)/\(binario)") { return true }
    }
    return false
}
