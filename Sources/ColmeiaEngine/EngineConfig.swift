import Foundation
import ColmeiaKit

/// Preferências globais que afetam armazenamento. Campos desconhecidos são
/// ignorados pelo decoder para que um `config.json` escrito por versão nova não
/// impeça o boot de uma versão antiga (§6.6 por analogia).
struct EngineConfig: Codable, Sendable, Equatable {
    static let `default` = EngineConfig()

    var schemaVersion: Int
    /// Menor que os 50 MiB da RFC para deixar margem aos eventos de auditoria.
    var journalMaxActiveBytes: Int
    /// RFC §20.4: padrão >= 30 dias.
    var closedJournalRetentionDays: Int
    /// RFC §7.4: <= 500; a compactação mantém a janela do dia em `document.jsonl`.
    var documentSnapshotEveryOps: Int

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case journalMaxActiveBytes = "journal_max_active_bytes"
        case closedJournalRetentionDays = "closed_journal_retention_days"
        case documentSnapshotEveryOps = "document_snapshot_every_ops"
    }

    init(
        schemaVersion: Int = 1,
        journalMaxActiveBytes: Int = 48 * 1024 * 1024,
        closedJournalRetentionDays: Int = 30,
        documentSnapshotEveryOps: Int = 500
    ) {
        self.schemaVersion = schemaVersion
        self.journalMaxActiveBytes = journalMaxActiveBytes
        self.closedJournalRetentionDays = closedJournalRetentionDays
        self.documentSnapshotEveryOps = documentSnapshotEveryOps
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            schemaVersion: try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1,
            journalMaxActiveBytes: try c.decodeIfPresent(Int.self, forKey: .journalMaxActiveBytes) ?? 48 * 1024 * 1024,
            closedJournalRetentionDays: try c.decodeIfPresent(Int.self, forKey: .closedJournalRetentionDays) ?? 30,
            documentSnapshotEveryOps: try c.decodeIfPresent(Int.self, forKey: .documentSnapshotEveryOps) ?? 500
        )
    }

    /// Recusa valores perigosos, mas não campos extras. Valores inválidos inteiros
    /// voltam a defaults individuais para não transformar config em ponto único de boot.
    func validated() -> EngineConfig {
        var value = self
        if value.schemaVersion < 1 { value.schemaVersion = 1 }
        if !(1 * 1024 * 1024 ... 49 * 1024 * 1024).contains(value.journalMaxActiveBytes) {
            value.journalMaxActiveBytes = EngineConfig.default.journalMaxActiveBytes
        }
        if !(30...3650).contains(value.closedJournalRetentionDays) {
            value.closedJournalRetentionDays = EngineConfig.default.closedJournalRetentionDays
        }
        if !(1...500).contains(value.documentSnapshotEveryOps) {
            value.documentSnapshotEveryOps = EngineConfig.default.documentSnapshotEveryOps
        }
        return value
    }

    var journalPolicy: JournalStoragePolicy { JournalStoragePolicy(maxActiveBytes: journalMaxActiveBytes) }

    static func load(from paths: ColmeiaPaths) -> (config: EngineConfig, warning: String?) {
        guard FileManager.default.fileExists(atPath: paths.configFile.path) else { return (.default, nil) }
        do {
            let raw = try AtomicJSON.read(EngineConfig.self, from: paths.configFile)
            let valid = raw.validated()
            let warning = valid == raw ? nil : "config.json contém limites inválidos; defaults seguros aplicados"
            return (valid, warning)
        } catch {
            return (.default, "config.json ilegível; defaults seguros aplicados")
        }
    }
}

/// Limpeza de journals encerrados, executada no boot ou em manutenção diária. A
/// meta é a autoridade para a data de encerramento; sem ela não apagamos nada.
enum SessionRetention {
    struct Removal: Equatable {
        let sessionID: ULID
        let files: [URL]
    }

    static func pruneClosedJournals(
        paths: ColmeiaPaths,
        retentionDays: Int,
        now: Date = Date()
    ) -> [Removal] {
        let minimumDays = max(30, retentionDays)
        let cutoff = Calendar.current.date(byAdding: .day, value: -minimumDays, to: now) ?? now
        let fm = FileManager.default
        guard let workspaces = try? fm.contentsOfDirectory(
            at: paths.workspacesDir, includingPropertiesForKeys: nil
        ) else { return [] }
        var removed: [Removal] = []
        for workspaceURL in workspaces {
            guard let workspaceID = ULID(workspaceURL.lastPathComponent),
                  let sessions = try? fm.contentsOfDirectory(
                    at: paths.sessionsDir(workspaceID), includingPropertiesForKeys: nil
                  )
            else { continue }
            for metaURL in sessions where metaURL.lastPathComponent.hasSuffix(".meta.json") {
                guard let meta = try? AtomicJSON.read(Session.self, from: metaURL),
                      !meta.estado.isViva,
                      let ended = meta.encerradaEm,
                      ended < cutoff
                else { continue }
                let dataFiles = [
                    paths.sessionJournal(workspace: workspaceID, session: meta.id),
                    paths.sessionScrollback(workspace: workspaceID, session: meta.id),
                ].filter { fm.fileExists(atPath: $0.path) }
                var allRemoved = true
                // Meta vem por último. Se o volume falhar ao apagar um journal,
                // preservar a meta garante que a próxima manutenção o encontre.
                for file in dataFiles {
                    do { try fm.removeItem(at: file) } catch { allRemoved = false }
                }
                guard allRemoved else { continue }
                do {
                    try fm.removeItem(at: metaURL)
                    removed.append(Removal(sessionID: meta.id, files: dataFiles + [metaURL]))
                } catch {
                    // Mesmo se a meta não saiu, os journals já foram removidos com
                    // sucesso; o próximo boot pode tentar novamente sem perder a
                    // informação de que a sessão existiu.
                }
            }
        }
        return removed
    }
}
