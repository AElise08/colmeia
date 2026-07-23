import Foundation
import Darwin
import Dispatch

public enum SocketClientError: Error, CustomStringConvertible {
    case notConnected
    case alreadyConnected
    case pathTooLong(String)
    case syscallFailed(String, errno: Int32)
    case connectionClosed

    public var description: String {
        switch self {
        case .notConnected: return "cliente não conectado"
        case .alreadyConnected: return "cliente já conectado"
        case .pathTooLong(let path): return "path de socket longo demais: \(path)"
        case .syscallFailed(let call, let code):
            return "\(call) falhou: \(String(cString: strerror(code)))"
        case .connectionClosed: return "conexão com o engine fechada"
        }
    }
}

/// Cliente NDJSON sobre Unix domain socket (§4.7/§6.1) — a ÚNICA via de acesso ao
/// engine para UI e CLI (regra de ouro §3.2). Requests recebem exatamente uma response,
/// correlacionada por `id`; eventos chegam pelo stream `events`.
///
/// `events` é um AsyncStream de consumidor único: quem precisar de fan-out redistribui.
public final class SocketClient: @unchecked Sendable {
    private let stateLock = NSLock()
    private let writeLock = NSLock()
    private var fd: Int32 = -1
    private var closed = false
    private var pending: [String: CheckedContinuation<ResponseMessage, Error>] = [:]
    private var requestCounter: UInt64 = 0
    private let readQueue = DispatchQueue(label: "colmeia.socket-client.read")

    public let events: AsyncStream<EventMessage>
    private let eventContinuation: AsyncStream<EventMessage>.Continuation

    public init() {
        let (stream, continuation) = AsyncStream<EventMessage>.makeStream(
            of: EventMessage.self,
            bufferingPolicy: .unbounded
        )
        self.events = stream
        self.eventContinuation = continuation
    }

    deinit {
        close()
    }

    // MARK: - Conexão

    public func connect(to socketPath: String) throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard fd < 0, !closed else { throw SocketClientError.alreadyConnected }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= capacity else { throw SocketClientError.pathTooLong(socketPath) }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            pathBytes.withUnsafeBytes { source in
                destination.baseAddress!.copyMemory(from: source.baseAddress!, byteCount: source.count)
            }
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let newFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard newFD >= 0 else { throw SocketClientError.syscallFailed("socket", errno: errno) }

        // Sem SIGPIPE ao escrever num engine que caiu — o erro volta como EPIPE.
        var one: Int32 = 1
        _ = setsockopt(newFD, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        let rc = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(newFD, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            let code = errno
            _ = Darwin.close(newFD)
            throw SocketClientError.syscallFailed("connect", errno: code)
        }

        fd = newFD
        readQueue.async { [weak self] in
            self?.readLoop(fd: newFD)
        }
    }

    public var isConnected: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return fd >= 0 && !closed
    }

    /// `shutdown` acorda o read loop bloqueado; o loop faz a limpeza dos pendentes.
    public func close() {
        stateLock.lock()
        let currentFD = fd
        closed = true
        stateLock.unlock()
        if currentFD >= 0 {
            _ = shutdown(currentFD, SHUT_RDWR)
        }
    }

    // MARK: - Requests

    /// Handshake obrigatório como primeira mensagem de todo cliente (§6.3).
    @discardableResult
    public func hello(
        client: String,
        author: Author = .humanoLocal,
        protocolVersion: Int = ColmeiaVersion.protocolVersion
    ) async throws -> HelloResult {
        try await call(
            .hello,
            params: HelloParams(protocolVersion: protocolVersion, client: client, author: author),
            expecting: HelloResult.self
        )
    }

    @discardableResult
    public func call(_ method: ColmeiaMethod, params: JSONValue? = nil) async throws -> JSONValue {
        try await callRaw(method: method.rawValue, params: params)
    }

    @discardableResult
    public func call(_ method: ColmeiaMethod, params: some Encodable) async throws -> JSONValue {
        try await callRaw(method: method.rawValue, params: JSONValue(encoding: params))
    }

    public func call<R: Decodable>(_ method: ColmeiaMethod, expecting: R.Type) async throws -> R {
        try await callRaw(method: method.rawValue, params: nil).decode(as: R.self)
    }

    public func call<R: Decodable>(
        _ method: ColmeiaMethod,
        params: some Encodable,
        expecting: R.Type
    ) async throws -> R {
        try await callRaw(method: method.rawValue, params: JSONValue(encoding: params)).decode(as: R.self)
    }

    /// Método como String para extensões fora do inventário §6.4.
    public func callRaw(method: String, params: JSONValue?) async throws -> JSONValue {
        let response = try await perform(method: method, params: params)
        if response.ok {
            return response.result ?? .object([:])
        }
        throw response.error ?? ProtocolError(name: .internal_error, message: "response !ok sem error")
    }

    private func perform(method: String, params: JSONValue?) async throws -> ResponseMessage {
        let requestID = nextRequestID()
        let request = RequestMessage(id: requestID, method: method, params: params)
        let line = try SocketFraming.encodeLine(Envelope.request(request))

        return try await withCheckedThrowingContinuation { continuation in
            stateLock.lock()
            guard fd >= 0, !closed else {
                stateLock.unlock()
                continuation.resume(throwing: SocketClientError.notConnected)
                return
            }
            let currentFD = fd
            pending[requestID] = continuation
            stateLock.unlock()

            writeLock.lock()
            do {
                try SocketFraming.writeLine(fd: currentFD, line)
                writeLock.unlock()
            } catch {
                writeLock.unlock()
                stateLock.lock()
                let orphan = pending.removeValue(forKey: requestID)
                stateLock.unlock()
                orphan?.resume(throwing: error)
            }
        }
    }

    private func nextRequestID() -> String {
        stateLock.lock()
        defer { stateLock.unlock() }
        requestCounter += 1
        return "r-\(requestCounter)-\(ULID.generate().string)"
    }

    // MARK: - Read loop

    private func readLoop(fd: Int32) {
        let lineBuffer = SocketFraming.LineBuffer()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        loop: while true {
            let count = read(fd, &chunk, chunk.count)
            if count > 0 {
                for line in lineBuffer.append(Data(bytes: chunk, count: count)) {
                    handle(line: line)
                }
            } else if count == 0 {
                break loop
            } else if errno == EINTR {
                continue
            } else {
                break loop
            }
        }
        handleDisconnect(fd: fd)
    }

    /// Linhas ilegíveis/kinds desconhecidos são ignorados (forward compatibility, §0).
    private func handle(line: Data) {
        guard let envelope = try? SocketFraming.decodeLine(Envelope.self, from: line) else { return }
        switch envelope {
        case .response(let response):
            stateLock.lock()
            let continuation = pending.removeValue(forKey: response.id)
            stateLock.unlock()
            continuation?.resume(returning: response)
        case .event(let event):
            eventContinuation.yield(event)
        case .request:
            break
        }
    }

    private func handleDisconnect(fd disconnectedFD: Int32) {
        stateLock.lock()
        let orphans = pending
        pending.removeAll()
        if fd == disconnectedFD {
            fd = -1
        }
        closed = true
        stateLock.unlock()

        _ = Darwin.close(disconnectedFD)
        for (_, continuation) in orphans {
            continuation.resume(throwing: SocketClientError.connectionClosed)
        }
        eventContinuation.finish()
    }
}
