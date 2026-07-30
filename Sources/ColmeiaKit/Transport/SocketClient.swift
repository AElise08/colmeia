import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
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

        let cleanPath = socketPath.replacingOccurrences(of: "ws://", with: "").replacingOccurrences(of: "wss://", with: "")

        if cleanPath.contains(":") || (!cleanPath.hasPrefix("/") && cleanPath.contains(".")) {
            let parts = cleanPath.split(separator: ":")
            let host = parts.count > 0 ? String(parts[0]) : "127.0.0.1"
            let port = parts.count > 1 ? (UInt16(parts[1]) ?? 9620) : 9620

            var hints = addrinfo()
            hints.ai_family = AF_INET
            #if canImport(Darwin)
            hints.ai_socktype = SOCK_STREAM
            #else
            hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
            #endif

            var res: UnsafeMutablePointer<addrinfo>?
            let portStr = String(port)
            let status = host.withCString { h in
                portStr.withCString { p in
                    getaddrinfo(h, p, &hints, &res)
                }
            }
            guard status == 0, let info = res else {
                throw SocketClientError.syscallFailed("getaddrinfo(\(socketPath))", errno: status)
            }
            defer { freeaddrinfo(res) }

            let newFD = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            guard newFD >= 0 else { throw SocketClientError.syscallFailed("socket", errno: errno) }

            #if canImport(Darwin)
            var one: Int32 = 1
            setsockopt(newFD, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            let connRes = Darwin.connect(newFD, info.pointee.ai_addr, info.pointee.ai_addrlen)
            #else
            let connRes = Glibc.connect(newFD, info.pointee.ai_addr, info.pointee.ai_addrlen)
            #endif

            guard connRes == 0 else {
                #if canImport(Darwin)
                _ = Darwin.close(newFD)
                #else
                _ = Glibc.close(newFD)
                #endif
                throw SocketClientError.syscallFailed("connect(\(socketPath))", errno: errno)
            }

            self.fd = newFD
            readQueue.async { [weak self] in self?.readLoop(fd: newFD) }
            return
        }

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
        #if os(macOS) || os(iOS)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif

        #if canImport(Darwin)
        let sockType = SOCK_STREAM
        #else
        let sockType = Int32(SOCK_STREAM.rawValue)
        #endif

        let newFD = socket(AF_UNIX, sockType, 0)
        guard newFD >= 0 else { throw SocketClientError.syscallFailed("socket", errno: errno) }

        // Sem SIGPIPE ao escrever num engine que caiu — o erro volta como EPIPE.
        #if canImport(Darwin)
        var one: Int32 = 1
        _ = setsockopt(newFD, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif

        let rc = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                #if canImport(Darwin)
                return Darwin.connect(newFD, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
                #elseif canImport(Glibc)
                return Glibc.connect(newFD, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
                #endif
            }
        }
        guard rc == 0 else {
            let code = errno
            #if canImport(Darwin)
            _ = Darwin.close(newFD)
            #elseif canImport(Glibc)
            _ = Glibc.close(newFD)
            #endif
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
            _ = shutdown(currentFD, Int32(SHUT_RDWR))
        }
    }

    // MARK: - Requests

    /// Handshake obrigatório como primeira mensagem de todo cliente (§6.3).
    @discardableResult
    public func hello(
        client: String,
        author: Author = .humanoLocal,
        protocolVersion: Int = ColmeiaVersion.protocolVersion,
        token: String? = nil
    ) async throws -> HelloResult {
        try await call(
            .hello,
            params: HelloParams(protocolVersion: protocolVersion, client: client, author: author, token: token),
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

        #if canImport(Darwin)
        _ = Darwin.close(disconnectedFD)
        #elseif canImport(Glibc)
        _ = Glibc.close(disconnectedFD)
        #endif
        for (_, continuation) in orphans {
            continuation.resume(throwing: SocketClientError.connectionClosed)
        }
        eventContinuation.finish()
    }
}
