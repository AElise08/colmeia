import Foundation

#if canImport(Darwin)
import Darwin
#endif

guard CommandLine.arguments.count == 3 else {
    print("uso: colmeia-tcp-bridge <listen-port> <unix-socket-path>")
    exit(1)
}

let port = UInt16(CommandLine.arguments[1]) ?? 9622
let unixPath = CommandLine.arguments[2]

var listenFD: Int32 = -1

func posixError(_ code: Int32) -> Error {
    NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: nil)
}

func makeListenSocket(port: UInt16) throws -> Int32 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw posixError(errno) }
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
    #if canImport(Darwin)
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    #endif
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = CFSwapInt16HostToBig(port)
    addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let bound = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bound == 0 else { throw posixError(errno) }
    guard listen(fd, 16) == 0 else { throw posixError(errno) }
    return fd
}

func connectUnixSocket(path: String) throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw posixError(errno) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = path.utf8CString
    withUnsafeMutableBytes(of: &addr.sun_path) { dst in
        bytes.withUnsafeBytes { src in
            dst.baseAddress!.copyMemory(from: src.baseAddress!, byteCount: min(src.count, dst.count))
        }
    }
    #if os(macOS)
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    #endif
    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard rc == 0 else { throw posixError(errno) }
    return fd
}

func bridge(from: Int32, to: Int32, label: String) {
    var total = 0
    let bufsize = 65536
    let buf = UnsafeMutableRawPointer.allocate(byteCount: bufsize, alignment: 16)
    defer { buf.deallocate() }
    while true {
        let n = read(from, buf, bufsize)
        guard n > 0 else {
            if n < 0 { fputs("bridge[\(label)]: read error \(errno)\n", stderr) }
            break
        }
        total += n
        var written = 0
        while written < n {
            let w = write(to, buf.advanced(by: written), n - written)
            guard w > 0 else {
                fputs("bridge[\(label)]: write error after \(total) bytes (errno=\(errno))\n", stderr)
                break
            }
            written += w
        }
    }
    fputs("bridge[\(label)]: done (\(total) bytes)\n", stderr)
}

signal(SIGPIPE, SIG_IGN)

do {
    listenFD = try makeListenSocket(port: port)
    print("tcp-bridge: listening on 127.0.0.1:\(port) -> \(unixPath)")

    while true {
        var clientAddr = sockaddr_storage()
        var clientLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let clientFD = withUnsafeMutablePointer(to: &clientAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                accept(listenFD, $0, &clientLen)
            }
        }
        guard clientFD >= 0 else {
            if errno == EINTR { continue }
            break
        }
        DispatchQueue.global().async {
            do {
                let engineFD = try connectUnixSocket(path: unixPath)
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    bridge(from: clientFD, to: engineFD, label: "c→e")
                    shutdown(engineFD, Int32(SHUT_WR))
                    group.leave()
                }
                group.enter()
                DispatchQueue.global().async {
                    bridge(from: engineFD, to: clientFD, label: "e→c")
                    shutdown(clientFD, Int32(SHUT_WR))
                    group.leave()
                }
                group.wait()
                close(clientFD)
                close(engineFD)
            } catch {
                close(clientFD)
            }
        }
    }
} catch {
    print("tcp-bridge error: \(error)")
    exit(1)
}
