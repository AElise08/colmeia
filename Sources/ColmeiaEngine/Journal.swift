import Foundation
import Darwin
import ColmeiaKit

/// §8.1 — journal append-only por sessão; o engine é o único escritor; `seq` desde 1 sem buracos.
/// Durabilidade: `write()` imediato no append (leitores do mesmo processo veem tudo) e
/// `fsync` pelo flusher do Engine em tick ≤ 1s.
public final class SessionJournal: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    private var fd: Int32 = -1
    private(set) var lastSeq: UInt64
    private var dirty = false
    private var sealed = false

    init(url: URL, lastSeq: UInt64 = 0) throws {
        self.url = url
        self.lastSeq = lastSeq
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { throw EngineFailure.io("open \(url.lastPathComponent)", errno) }
    }

    /// Retorna o Event gravado (com seq atribuído) ou nil se o journal já foi selado.
    @discardableResult
    func append(_ payload: EventPayload, author: Author, ts: Date = Date()) -> Event? {
        lock.lock()
        defer { lock.unlock() }
        guard !sealed, fd >= 0 else { return nil }
        let event = Event(seq: lastSeq + 1, ts: ts, author: author, payload: payload)
        guard var data = try? SocketFraming.encodeLine(event) else { return nil }
        data.append(0x0A)
        var ok = true
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < buffer.count {
                let written = write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0 && errno == EINTR {
                    continue
                } else {
                    ok = false
                    return
                }
            }
        }
        guard ok else { return nil }
        lastSeq += 1
        dirty = true
        return event
    }

    /// fsync se houver dados novos (flusher tick ≤ 1s, §8.1).
    func flush() {
        lock.lock()
        defer { lock.unlock() }
        guard dirty, fd >= 0 else { return }
        _ = fsync(fd)
        dirty = false
    }

    /// Journal de sessão encerrada é imutável (§8.1).
    func seal() {
        lock.lock()
        defer { lock.unlock() }
        if fd >= 0 {
            _ = fsync(fd)
            _ = close(fd)
            fd = -1
        }
        sealed = true
    }

    deinit { seal() }
}

struct JournalReadResult {
    var events: [Event]
    /// true se houve linha ilegível ou buraco de seq (§22.3).
    var corrupted: Bool
    var quarantinedBytes: Int
}

enum JournalReader {
    /// Lê o prefixo válido. Com `repair=true` (§22.3): o resto vai para `<arquivo>.quarantine`
    /// e o journal é reescrito só com as linhas boas — NUNCA apagar dados silenciosamente.
    static func read(url: URL, repair: Bool) -> JournalReadResult {
        guard let raw = try? Data(contentsOf: url) else {
            return JournalReadResult(events: [], corrupted: false, quarantinedBytes: 0)
        }
        var events: [Event] = []
        var goodBytes = 0
        var corrupted = false
        var cursor = raw.startIndex
        while cursor < raw.endIndex {
            let lineEnd = raw[cursor...].firstIndex(of: 0x0A) ?? raw.endIndex
            let line = raw[cursor..<lineEnd]
            let nextCursor = lineEnd < raw.endIndex ? raw.index(after: lineEnd) : raw.endIndex
            if line.isEmpty {
                cursor = nextCursor
                goodBytes = raw.distance(from: raw.startIndex, to: nextCursor)
                continue
            }
            guard let event = try? SocketFraming.decodeLine(Event.self, from: Data(line)),
                  event.seq == UInt64(events.count) + 1
            else {
                corrupted = true
                break
            }
            events.append(event)
            cursor = nextCursor
            goodBytes = raw.distance(from: raw.startIndex, to: nextCursor)
        }
        var quarantined = 0
        if corrupted, repair {
            let rest = raw[raw.index(raw.startIndex, offsetBy: goodBytes)...]
            quarantined = rest.count
            let quarantineURL = url.appendingPathExtension("quarantine")
            let qfd = open(quarantineURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
            if qfd >= 0 {
                Data(rest).withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
                    var offset = 0
                    while offset < buffer.count {
                        let written = write(qfd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                        if written > 0 { offset += written } else if written < 0 && errno == EINTR { continue } else { break }
                    }
                }
                _ = fsync(qfd)
                close(qfd)
                let temp = url.deletingLastPathComponent()
                    .appendingPathComponent(".\(url.lastPathComponent).repair")
                if (try? Data(raw.prefix(goodBytes)).write(to: temp)) != nil,
                   rename(temp.path, url.path) == 0 {
                    // reescrito só com as linhas boas
                } else {
                    try? FileManager.default.removeItem(at: temp)
                }
            }
        }
        return JournalReadResult(events: events, corrupted: corrupted, quarantinedBytes: quarantined)
    }
}
