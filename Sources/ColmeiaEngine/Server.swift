import Foundation
import Darwin
import ColmeiaKit

/// Servidor NDJSON no Unix domain socket (§6.1). Socket com permissão 0600 (§23.2).
final class SocketServer {
    private let path: String
    private weak var engine: Engine?
    private var listenFD: Int32 = -1
    private let acceptQueue = DispatchQueue(label: "colmeia.server.accept")

    init(path: String, engine: Engine) {
        self.path = path
        self.engine = engine
    }

    func start() throws {
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
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
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

    private func acceptLoop(fd: Int32) {
        while true {
            let clientFD = accept(fd, nil, nil)
            if clientFD < 0 {
                if errno == EINTR { continue }
                return // listen fd fechado (stop)
            }
            var one: Int32 = 1
            _ = setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
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
    private let writeLock = NSLock()
    private var writeClosed = false
    private var pendingWrites = 0

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

    /// Limite de backpressure (§6.5) — cliente que não drena é desconectado com aviso.
    static let maxPendingWrites = 5000

    init(fd: Int32, engine: Engine) {
        self.fd = fd
        self.engine = engine
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
        guard let data = try? SocketFraming.encodeLine(envelope) else { return }
        writeLock.lock()
        if writeClosed {
            writeLock.unlock()
            return
        }
        pendingWrites += 1
        let backlog = pendingWrites
        writeLock.unlock()
        if backlog > ClientConnection.maxPendingWrites {
            // §6.5: aviso prévio + desconexão; o journal garante que nada se perde.
            engine?.stateQueue.async { [weak self] in
                guard let self, let engine = self.engine else { return }
                engine.dropClient(self, motivo: "backpressure: cliente não drena eventos")
            }
            return
        }
        writeQueue.async { [weak self] in
            guard let self else { return }
            self.writeLock.lock()
            self.pendingWrites -= 1
            let closed = self.writeClosed
            self.writeLock.unlock()
            guard !closed else { return }
            do {
                try SocketFraming.writeLine(fd: self.fd, data)
            } catch {
                self.engine?.stateQueue.async { [weak self] in
                    guard let self, let engine = self.engine else { return }
                    engine.dropClient(self, motivo: "erro de escrita")
                }
            }
        }
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
        _ = shutdown(fd, SHUT_RDWR)
        // close depois de drenar a write queue
        writeQueue.async { [fd] in
            _ = Darwin.close(fd)
        }
    }
}
