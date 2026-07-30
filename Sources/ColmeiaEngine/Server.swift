import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import ColmeiaKit

/// Servidor NDJSON no Unix domain socket (§6.1). Socket com permissão 0600 (§23.2).
/// Opcionalmente também escuta em TCP (para túnel remoto Engine → Hub VPS).
final class SocketServer {
    private let path: String
    private let tcpPort: UInt16
    private weak var engine: Engine?
    private var listenFD: Int32 = -1
    private var tcpListenFD: Int32 = -1
    private let acceptQueue = DispatchQueue(label: "colmeia.server.accept")
    private let tcpAcceptQueue = DispatchQueue(label: "colmeia.server.tcp.accept")

    init(path: String, tcpPort: UInt16 = 0, engine: Engine) {
        self.path = path
        self.tcpPort = tcpPort
        self.engine = engine
    }

    func start() throws {
        try startUnix()
        try startTCP()
    }

    private func startUnix() throws {
        unlink(path)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= capacity else {
            throw EngineFailure.io("socket path longo demais: \(path)", ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            pathBytes.withUnsafeBytes { source in
                destination.baseAddress!.copyMemory(from: source.baseAddress!, byteCount: source.count)
            }
        }
        #if os(macOS)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif

        #if canImport(Darwin)
        let sockType = SOCK_STREAM
        #else
        let sockType = Int32(SOCK_STREAM.rawValue)
        #endif
        let fd = socket(AF_UNIX, sockType, 0)
        guard fd >= 0 else { throw EngineFailure.io("socket", errno) }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw EngineFailure.io("bind \(path)", code)
        }
        _ = chmod(path, 0o600)
        guard listen(fd, 32) == 0 else {
            let code = errno
            close(fd)
            throw EngineFailure.io("listen", code)
        }
        listenFD = fd
        acceptQueue.async { [weak self] in
            self?.acceptLoop(fd: fd)
        }
    }

    private func startTCP() throws {
        guard tcpPort > 0 else { return }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw EngineFailure.io("tcp socket", errno) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        #if canImport(Darwin)
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = CFSwapInt16HostToBig(tcpPort)
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw EngineFailure.io("bind tcp :\(tcpPort)", code)
        }
        guard listen(fd, 16) == 0 else {
            let code = errno
            close(fd)
            throw EngineFailure.io("listen tcp :\(tcpPort)", code)
        }
        tcpListenFD = fd
        engine?.log.info("engine_tcp", "TCP escutando na porta \(tcpPort)")
        tcpAcceptQueue.async { [weak self] in
            self?.acceptLoop(fd: fd)
        }
    }

    private func acceptLoop(fd: Int32) {
        while true {
            let clientFD = accept(fd, nil, nil)
            if clientFD < 0 {
                if errno == EINTR { continue }
                return // listen fd fechado (stop)
            }
            #if canImport(Darwin)
            var one: Int32 = 1
            _ = setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            #endif
            guard let engine else {
                close(clientFD)
                return
            }
            engine.stateQueue.async {
                engine.addClient(fd: clientFD)
            }
        }
    }

    func stop() {
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        if tcpListenFD >= 0 {
            close(tcpListenFD)
            tcpListenFD = -1
        }
        unlink(path)
    }
}

/// Uma conexão de cliente (§3.3: múltiplos simultâneos). Estado de assinatura e
/// attachment vive aqui; mutações só na stateQueue do Engine.
final class ClientConnection {
    let fd: Int32
    private(set) weak var engine: Engine?
    private let readQueue: DispatchQueue
    private let writeQueue: DispatchQueue
    private let writerEnabled: Bool
    private let writeLock = NSLock()
    private var writeClosed = false
    private var outbox: [Outbound] = []
    private var queuedBytes = 0
    private var drainScheduled = false
    private var backpressureDisconnectScheduled = false
    private var backpressureWarningEnqueued = false

    // Tudo abaixo: só na stateQueue do Engine.
    var helloDone = false
    var author: Author = .humanoLocal
    var clientName = "?"
    /// topic → filtro de workspaces (nil = todos).
    var subscriptions: [ColmeiaTopic: Set<ULID>?] = [:]
    var attached: Set<ULID> = []
    /// Piso de seq por sessão attachada — emenda replay+vivo sem buraco nem duplicata (§8.4).
    var outputFloor: [ULID: UInt64] = [:]
    var malformedTimestamps: [Date] = []

    /// Backpressure §6.5. A partir do limite suave só `session.output` adjacente da
    /// mesma sessão é coalescido; os demais tópicos preservam ordem e nunca somem.
    static let coalesceAfter = 128
    static let maxQueuedEvents = 1_024
    /// Mesmo com coalescência, um consumidor completamente travado não pode fazer
    /// um único `session.output` crescer sem limite na memória do engine.
    static let maxQueuedBytes = 8 * 1024 * 1024

    private enum Outbound {
        case bytes(Data)
        case output(sessionID: ULID, seq: UInt64, bytes: Data)

        func encoded() -> Data? {
            switch self {
            case .bytes(let data): return data
            case .output(let sessionID, let seq, let bytes):
                guard let params = try? JSONValue(encoding: SessionOutputTopicPayload(
                    sessionID: sessionID, seq: seq, dataB64: bytes.base64EncodedString()))
                else { return nil }
                return try? SocketFraming.encodeLine(Envelope.event(
                    EventMessage(topic: .sessionOutput, params: params)))
            }
        }

        var byteCount: Int {
            switch self {
            case .bytes(let data): return data.count
            case .output(_, _, let bytes): return bytes.count
            }
        }
    }

    init(fd: Int32, engine: Engine, writerEnabled: Bool = true) {
        self.fd = fd
        self.engine = engine
        self.writerEnabled = writerEnabled
        self.readQueue = DispatchQueue(label: "colmeia.client.read.\(fd)")
        self.writeQueue = DispatchQueue(label: "colmeia.client.write.\(fd)")
    }

    func startReading() {
        readQueue.async { [weak self] in
            self?.readLoop()
        }
    }

    private func readLoop() {
        let lineBuffer = SocketFraming.LineBuffer()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count > 0 {
                for line in lineBuffer.append(Data(bytes: chunk, count: count)) {
                    let data = line
                    engine?.stateQueue.async { [weak self] in
                        guard let self, let engine = self.engine else { return }
                        engine.receive(line: data, from: self)
                    }
                }
            } else if count < 0 && errno == EINTR {
                continue
            } else {
                break
            }
        }
        engine?.stateQueue.async { [weak self] in
            guard let self, let engine = self.engine else { return }
            engine.dropClient(self, motivo: "desconectou")
        }
    }

    func send(_ envelope: Envelope) {
        guard let outbound = makeOutbound(envelope) else { return }
        writeLock.lock()
        if writeClosed {
            writeLock.unlock()
            return
        }
        enqueueLocked(outbound)
        let overflow = (
            outbox.count > ClientConnection.maxQueuedEvents ||
            queuedBytes > ClientConnection.maxQueuedBytes
        ) && !backpressureDisconnectScheduled
        if overflow {
            backpressureDisconnectScheduled = true
            // Entra antes do backlog que ainda não foi escrito. É melhor-esforço
            // (um socket completamente bloqueado não consegue receber nada), mas
            // é sempre enfileirado ANTES da desconexão exigida em §6.5.
            let warning = EngineWarningTopicPayload(
                name: "client_backpressure",
                message: "cliente não está drenando eventos; reconecte para reattach do journal")
            if let params = try? JSONValue(encoding: warning),
               let data = try? SocketFraming.encodeLine(Envelope.event(
                EventMessage(topic: .engineWarning, params: params))) {
                outbox.insert(.bytes(data), at: 0)
                queuedBytes += data.count
                backpressureWarningEnqueued = true
            }
        }
        let shouldSchedule = !drainScheduled
        if shouldSchedule { drainScheduled = true }
        writeLock.unlock()

        if shouldSchedule, writerEnabled { scheduleDrain() }
        if overflow {
            // Dá ao warning a primeira chance de sair, sem deixar uma conexão
            // travada reter memória. Os outputs continuam íntegros no journal.
            engine?.stateQueue.async { [weak self] in
                guard let self, let engine = self.engine else { return }
                engine.stateQueue.asyncAfter(deadline: .now() + .milliseconds(250)) { [weak self, weak engine] in
                    guard let self, let engine else { return }
                    engine.dropClient(self, motivo: "backpressure: cliente não drena eventos")
                }
            }
        }
    }

    private func makeOutbound(_ envelope: Envelope) -> Outbound? {
        if case .event(let event) = envelope,
           event.knownTopic == .sessionOutput,
           let payload = try? event.decodeParams(SessionOutputTopicPayload.self),
           let bytes = Data(base64Encoded: payload.dataB64) {
            return .output(sessionID: payload.sessionID, seq: payload.seq, bytes: bytes)
        }
        guard let data = try? SocketFraming.encodeLine(envelope) else { return nil }
        return .bytes(data)
    }

    private func enqueueLocked(_ new: Outbound) {
        if outbox.count >= ClientConnection.coalesceAfter,
           case .output(let newSession, let newSeq, let newBytes) = new,
           case .output(let oldSession, _, let oldBytes)? = outbox.last,
           oldSession == newSession {
            // `seq` vira o último byte incorporado; em caso de queda o cliente
            // reatacha de `seq + 1`, e o terminal já recebeu todos os bytes unidos.
            outbox[outbox.count - 1] = .output(
                sessionID: newSession, seq: newSeq, bytes: oldBytes + newBytes)
            queuedBytes += newBytes.count
        } else {
            outbox.append(new)
            queuedBytes += new.byteCount
        }
    }

    private func scheduleDrain() {
        writeQueue.async { [weak self] in
            guard let self else { return }
            self.drainWrites()
        }
    }

    private func drainWrites() {
        while true {
            writeLock.lock()
            let closed = writeClosed
            let next = outbox.isEmpty ? nil : outbox.removeFirst()
            if let next { queuedBytes -= next.byteCount }
            if next == nil { drainScheduled = false }
            writeLock.unlock()
            guard !closed, let next, let data = next.encoded() else { return }
            do {
                try SocketFraming.writeLine(fd: fd, data)
            } catch {
                engine?.stateQueue.async { [weak self] in
                    guard let self, let engine = self.engine else { return }
                    engine.dropClient(self, motivo: "erro de escrita")
                }
                return
            }
        }
    }

    /// Visibilidade determinística para testes de limites, sem expor o buffer ao engine.
    var queuedEventCountForTesting: Int {
        writeLock.lock(); defer { writeLock.unlock() }
        return outbox.count
    }

    var queuedByteCountForTesting: Int {
        writeLock.lock(); defer { writeLock.unlock() }
        return queuedBytes
    }

    var backpressureScheduledForTesting: Bool {
        writeLock.lock(); defer { writeLock.unlock() }
        return backpressureDisconnectScheduled
    }

    var backpressureWarningEnqueuedForTesting: Bool {
        writeLock.lock(); defer { writeLock.unlock() }
        return backpressureWarningEnqueued
    }

    func respond(id: String, result: JSONValue?) {
        send(.response(ResponseMessage(id: id, result: result)))
    }

    func respond(id: String, error: ProtocolError) {
        send(.response(ResponseMessage(id: id, error: error)))
    }

    func closeConnection() {
        writeLock.lock()
        let alreadyClosed = writeClosed
        writeClosed = true
        writeLock.unlock()
        guard !alreadyClosed else { return }
        #if canImport(Darwin)
        _ = shutdown(fd, SHUT_RDWR)
        #else
        _ = shutdown(fd, Int32(SHUT_RDWR))
        #endif
        // close depois de drenar a write queue
        writeQueue.async { [fd] in
            #if canImport(Darwin)
            _ = Darwin.close(fd)
            #else
            _ = Glibc.close(fd)
            #endif
        }
    }
}
