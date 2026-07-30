import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import ColmeiaKit

/// Limites definidos pela implementação para §8.3. O arquivo ativo fica abaixo de
/// 50 MiB em uso normal; o arquivo `.scrollback` conserva os chunks antigos para
/// que `seq` e replay continuem completos.
struct JournalStoragePolicy: Sendable, Equatable {
    static let `default` = JournalStoragePolicy(maxActiveBytes: 48 * 1024 * 1024)
    let maxActiveBytes: Int

    init(maxActiveBytes: Int) {
        // Não aceitar um limite microscópico que faria rotação por evento nem um
        // inteiro negativo vindo de config corrompida.
        self.maxActiveBytes = max(1 * 1024 * 1024, maxActiveBytes)
    }
}

/// Arquivo `.scrollback` legível em JSON. Não há emulador no engine; logo o
/// snapshot definido pela implementação é um arquivo de chunks `output` brutos
/// arquivados. É um superconjunto das "últimas N linhas + resto arquivado": o
/// cliente ainda pode alimentar seu emulador e reconstruir a tela exatamente.
/// Eventos não-output ficam também no journal ativo como trilha de auditoria.
private struct ScrollbackArchive: Codable {
    let schemaVersion: Int
    var outputEvents: [Event]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case outputEvents = "output_events"
    }
}

/// §8.1 — journal append-only por sessão; o engine é o único escritor; `seq` desde
/// 1 sem buracos. Durabilidade: `write()` imediato, fsync pelo flusher ≤ 1 s.
public final class SessionJournal: @unchecked Sendable {
    public let url: URL
    private let scrollbackURL: URL
    private let policy: JournalStoragePolicy
    private let lock = NSLock()
    private var fd: Int32 = -1
    private(set) var lastSeq: UInt64
    private var dirty = false
    private var sealed = false

    init(url: URL, lastSeq: UInt64 = 0, policy: JournalStoragePolicy = .default) throws {
        self.url = url
        self.scrollbackURL = url.deletingPathExtension().appendingPathExtension("scrollback")
        self.policy = policy
        self.lastSeq = lastSeq
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else {
            StorageHealth.shared.recordWriteFailure(errno, operation: "open \(url.lastPathComponent)")
            throw EngineFailure.io("open \(url.lastPathComponent)", errno)
        }
    }

    /// Retorna o Event gravado (com seq atribuído) ou nil se selado/falha de I/O.
    @discardableResult
    func append(_ payload: EventPayload, author: Author, ts: Date = Date()) -> Event? {
        lock.lock()
        defer { lock.unlock() }
        guard !sealed, fd >= 0 else { return nil }
        let event = Event(seq: lastSeq + 1, ts: ts, author: author, payload: payload)
        guard var data = try? SocketFraming.encodeLine(event) else { return nil }
        data.append(0x0A)
        do {
            try AtomicFile.writeAll(data, to: fd, operation: "append \(url.lastPathComponent)")
        } catch {
            return nil
        }
        lastSeq += 1
        dirty = true
        // A rotação só acontece depois que o evento novo já foi aceito. Se ela
        // falhar, o journal original continua íntegro e será tentado de novo.
        rotateIfNeededLocked()
        return event
    }

    /// fsync se houver dados novos (flusher tick ≤ 1s, §8.1).
    func flush() {
        lock.lock()
        defer { lock.unlock() }
        guard dirty, fd >= 0 else { return }
        if fsync(fd) == 0 {
            dirty = false
            StorageHealth.shared.clearAfterSuccessfulWrite()
        } else {
            StorageHealth.shared.recordWriteFailure(errno, operation: "fsync \(url.lastPathComponent)")
        }
    }

    /// Journal de sessão encerrada é imutável (§8.1).
    func seal() {
        lock.lock()
        defer { lock.unlock() }
        if fd >= 0 {
            if fsync(fd) != 0 {
                StorageHealth.shared.recordWriteFailure(errno, operation: "fsync \(url.lastPathComponent)")
            }
            _ = close(fd)
            fd = -1
        }
        sealed = true
    }

    /// Move SOMENTE outputs para `.scrollback`; eventos de auditoria permanecem no
    /// `.jsonl`. A atualização é crash-safe: primeiro o archive atômico, depois o
    /// journal ativo atômico. No intervalo entre ambos há apenas duplicatas de seq,
    /// que o leitor aceita se forem byte-a-byte semanticamente idênticas.
    private func rotateIfNeededLocked() {
        var info = stat()
        guard fd >= 0, fstat(fd, &info) == 0, info.st_size > off_t(policy.maxActiveBytes) else { return }

        if fsync(fd) != 0 {
            StorageHealth.shared.recordWriteFailure(errno, operation: "fsync antes de rotação")
            return
        }
        let physical = JournalReader.readPhysical(url: url)
        guard !physical.corrupted else { return } // reparo é tarefa de recovery, nunca apagar aqui
        let outputs = physical.events.filter { $0.tipo == .output }
        guard !outputs.isEmpty else { return }
        var archive = (try? AtomicJSON.read(ScrollbackArchive.self, from: scrollbackURL))
            ?? ScrollbackArchive(schemaVersion: 1, outputEvents: [])
        guard archive.schemaVersion == 1 else { return } // formato futuro: não sobrescrever
        var bySeq = Dictionary(uniqueKeysWithValues: archive.outputEvents.map { ($0.seq, $0) })
        for event in outputs { bySeq[event.seq] = event }
        archive.outputEvents = bySeq.values.sorted { $0.seq < $1.seq }
        do {
            try AtomicJSON.write(archive, to: scrollbackURL)
            let auditLines = physical.events.filter { $0.tipo != .output }
                .compactMap { try? SocketFraming.encodeLine($0) + Data([0x0A]) }
            let rewritten = auditLines.reduce(into: Data()) { $0.append($1) }
            try AtomicFile.replace(rewritten, at: url)
            _ = close(fd)
            fd = open(url.path, O_WRONLY | O_APPEND, 0o600)
            guard fd >= 0 else { throw EngineFailure.io("reabrir \(url.lastPathComponent)", errno) }
            dirty = false
        } catch let error as EngineFailure {
            // O arquivo ativo não é tocado antes de o archive estar íntegro. Se a
            // segunda etapa falhou, duplicatas no archive são deduplicadas no leitor.
            if case .io(_, let code) = error {
                StorageHealth.shared.recordWriteFailure(code, operation: "rotação do journal")
            }
        } catch {
            return
        }
    }

    deinit { seal() }
}

struct JournalReadResult {
    var events: [Event]
    /// true se houve linha ilegível, sequência inválida ou archive incompatível (§22.3).
    var corrupted: Bool
    var quarantinedBytes: Int
}

enum JournalReader {
    /// Lê archive + journal ativo e verifica a sequência global sem buracos. Durante
    /// rotação o ativo contém apenas eventos não-output, portanto a continuidade só
    /// pode ser validada depois do merge.
    static func read(url: URL, repair: Bool) -> JournalReadResult {
        let physical = readPhysical(url: url)
        var corrupted = physical.corrupted
        var quarantined = 0
        if physical.corrupted, repair {
            quarantined = quarantineInvalidSuffix(url: url, goodBytes: physical.goodBytes)
        }

        let scrollbackURL = url.deletingPathExtension().appendingPathExtension("scrollback")
        var archiveEvents: [Event] = []
        if FileManager.default.fileExists(atPath: scrollbackURL.path) {
            do {
                let archive = try AtomicJSON.read(ScrollbackArchive.self, from: scrollbackURL)
                guard archive.schemaVersion == 1,
                      archive.outputEvents.allSatisfy({ $0.tipo == .output })
                else { throw EngineFailure.io("scrollback incompatível", EINVAL) }
                archiveEvents = archive.outputEvents
            } catch {
                corrupted = true
                // Archive ilegível também nunca é apagado silenciosamente.
                quarantined += quarantineWholeFile(url: scrollbackURL)
            }
        }

        // Sem archive, o comportamento histórico é prefixo válido até o primeiro
        // buraco. Com archive há lacunas físicas legítimas no arquivo ativo.
        if archiveEvents.isEmpty && !FileManager.default.fileExists(atPath: scrollbackURL.path) {
            var expected: UInt64 = 1
            var prefix: [Event] = []
            for event in physical.events {
                guard event.seq == expected else { corrupted = true; break }
                prefix.append(event)
                expected += 1
            }
            return JournalReadResult(events: prefix, corrupted: corrupted, quarantinedBytes: quarantined)
        }

        var bySeq: [UInt64: Event] = [:]
        for event in archiveEvents + physical.events {
            if let previous = bySeq[event.seq], previous != event {
                corrupted = true
            } else {
                bySeq[event.seq] = event
            }
        }
        let events = bySeq.values.sorted { $0.seq < $1.seq }
        if events.enumerated().contains(where: { $0.element.seq != UInt64($0.offset + 1) }) {
            corrupted = true
        }
        return JournalReadResult(events: events, corrupted: corrupted, quarantinedBytes: quarantined)
    }

    /// Prefixo fisicamente válido. Seq pode ser esparsa após rotação, mas nunca
    /// regressiva/duplicada dentro do mesmo arquivo.
    fileprivate static func readPhysical(url: URL) -> (events: [Event], corrupted: Bool, goodBytes: Int) {
        guard let raw = try? Data(contentsOf: url) else { return ([], false, 0) }
        var events: [Event] = []
        var goodBytes = 0
        var cursor = raw.startIndex
        var lastSeq: UInt64 = 0
        var corrupted = false
        while cursor < raw.endIndex {
            guard let lineEnd = raw[cursor...].firstIndex(of: 0x0A) else {
                // JSONL sem newline terminal pode ser um write interrompido: trate
                // como corrupção mesmo se o JSON por acaso decodificar.
                corrupted = true
                break
            }
            let line = raw[cursor..<lineEnd]
            let nextCursor = raw.index(after: lineEnd)
            if !line.isEmpty {
                guard let event = try? SocketFraming.decodeLine(Event.self, from: Data(line)),
                      event.seq > lastSeq
                else { corrupted = true; break }
                events.append(event)
                lastSeq = event.seq
            }
            cursor = nextCursor
            goodBytes = raw.distance(from: raw.startIndex, to: nextCursor)
        }
        return (events, corrupted, goodBytes)
    }

    private static func quarantineInvalidSuffix(url: URL, goodBytes: Int) -> Int {
        guard let raw = try? Data(contentsOf: url), goodBytes < raw.count else { return 0 }
        let rest = Data(raw.dropFirst(goodBytes))
        let quarantine = url.appendingPathExtension("quarantine")
        do {
            // Append é deliberado: preserva cada incidente em vez de sobrescrever.
            let fd = open(quarantine.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
            guard fd >= 0 else { return 0 }
            defer { close(fd) }
            try AtomicFile.writeAll(rest, to: fd, operation: "quarentena \(url.lastPathComponent)")
            guard fsync(fd) == 0 else { return 0 }
            try AtomicFile.replace(Data(raw.prefix(goodBytes)), at: url)
            return rest.count
        } catch { return 0 }
    }

    private static func quarantineWholeFile(url: URL) -> Int {
        guard let raw = try? Data(contentsOf: url), !raw.isEmpty else { return 0 }
        let quarantine = url.appendingPathExtension("quarantine")
        let fd = open(quarantine.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { return 0 }
        defer { close(fd) }
        do {
            try AtomicFile.writeAll(raw, to: fd, operation: "quarentena \(url.lastPathComponent)")
            _ = fsync(fd)
            return raw.count
        } catch { return 0 }
    }
}
