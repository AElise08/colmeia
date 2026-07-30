import Foundation

/// Identidade estável da instalação (§7.1). Cada máquina
/// gera um ULID uma única vez e guarda no diretório de suporte da app + cache
/// em UserDefaults. Substitui `humano:local` por `humano:<installation-ulid>`.
///
/// Testes podem sobrescrever a identidade via env `COLMEIA_TEST_AUTHOR`
/// (ex.: `COLMEIA_TEST_AUTHOR=humano:local` mantém o comportamento antigo).
public enum InstallationIdentity: Sendable {
    private static let defaultsKey = "Colmeia.installationIdentity"

    /// Lock para acesso concorrente ao estado.
    private static let lock = NSLock()
    private static var _cached: ULID?

    /// Retorna o ULID estável da instalação — gera e persiste na primeira chamada.
    public static func current() -> ULID {
        lock.lock()
        defer { lock.unlock() }

        // Test override via env.
        if let testAuthor = ProcessInfo.processInfo.environment["COLMEIA_TEST_AUTHOR"],
           let author = Author(rawValue: testAuthor),
           case .humano(let id) = author,
           let override = ULID(id) {
            return override
        }

        // 1. Memória (rápido, sem I/O).
        if let cached = _cached {
            return cached
        }

        // 2. UserDefaults (cache entre processos/lançamentos).
        if let string = UserDefaults.standard.string(forKey: defaultsKey),
           let ulid = ULID(string) {
            _cached = ulid
            return ulid
        }

        // 3. Arquivo de identidade (fonte de verdade durável).
        let identityFile = identityFileURL()
        if let stored = readIdentityFile(at: identityFile) {
            persist(stored)
            return stored
        }

        // 4. Gera identidade nova.
        let newID = ULID.generate()
        persist(newID)
        writeIdentityFile(newID, at: identityFile)
        return newID
    }

    /// Author estável da instalação no formato `humano:<ulid>`.
    public static func currentAuthor() -> Author {
        .humano(current().string)
    }

    /// Mantém compatibilidade: `humano:local` é normalizado para a identidade estável.
    public static func normalizeAuthor(_ author: Author) -> Author {
        switch author {
        case .humano("local"):
            return currentAuthor()
        default:
            return author
        }
    }

    // MARK: - Persistência

    private static func persist(_ id: ULID) {
        _cached = id
        UserDefaults.standard.set(id.string, forKey: defaultsKey)
    }

    private static func identityFileURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        let dir = appSupport.appendingPathComponent("Colmeia", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("identity.json")
    }

    private static func readIdentityFile(at url: URL) -> ULID? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        struct IdentityFile: Decodable { var installationID: String }
        guard let file = try? JSONDecoder().decode(IdentityFile.self, from: data),
              let ulid = ULID(file.installationID) else { return nil }
        return ulid
    }

    private static func writeIdentityFile(_ id: ULID, at url: URL) {
        let json = #"{"installation_id":"\#(id.string)"}"#
        try? json.write(to: url, atomically: true, encoding: .utf8)
    }
}
