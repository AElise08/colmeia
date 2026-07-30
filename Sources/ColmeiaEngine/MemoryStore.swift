import Foundation
import ColmeiaKit

/// Erros internos do serviço de memória. O adaptador de protocolo pode convertê-los
/// para `ProtocolError` depois, sem expor detalhes de conteúdo sensível.
enum MemoryStoreError: Error, Equatable {
    case authorizationDenied
    case invalidContent
    case proposalNotFound
    case invalidTransition
}

/// Memória por workspace, propositalmente independente de journal e de sessão.
/// O chamador fornece o diretório já isolado daquele workspace; portanto esta
/// classe não precisa conhecer estado global do Engine nem o protocolo de socket.
final class WorkspaceMemoryStore {
    private let workspaceDirectory: URL
    private let fileManager: FileManager
    private static let maximumMemoryBytes = 12_000
    private static let maximumProposalBytes = 4_000
    private static let maximumDailyBytes = 3_000
    private static let maximumBriefingBytes = 6_000
    private static let maximumHistoryEntries = 500

    init(workspaceDirectory: URL, fileManager: FileManager = .default) {
        self.workspaceDirectory = workspaceDirectory.standardizedFileURL
        self.fileManager = fileManager
    }

    private var memoryURL: URL { workspaceDirectory.appendingPathComponent("MEMORY.md") }
    private var dailyDirectory: URL { workspaceDirectory.appendingPathComponent("daily", isDirectory: true) }
    private var proposalsURL: URL { workspaceDirectory.appendingPathComponent("memory-proposals.json") }
    private var historyURL: URL { workspaceDirectory.appendingPathComponent("memory-history.json") }

    func get() -> WorkspaceMemory {
        let content = readMarkdown(memoryURL)
        let history = history()
        let lastUpdate = history.last(where: { $0.action == .memoryUpdated || $0.action == .proposalAccepted })
        return WorkspaceMemory(content: MemorySanitizer.forReading(content, maximumBytes: Self.maximumMemoryBytes),
                               updatedAt: lastUpdate?.timestamp,
                               updatedBy: lastUpdate?.author)
    }

    /// Atualização direta é uma decisão humana. Agentes só podem usar `propose`.
    @discardableResult
    func update(_ content: String, author: Author, now: Date = Date()) throws -> WorkspaceMemory {
        try requireHuman(author)
        let safe = try MemorySanitizer.forWriting(content, maximumBytes: Self.maximumMemoryBytes)
        try writeMarkdown(safe, to: memoryURL)
        try appendHistory(.memoryUpdated, author: author, at: now)
        return WorkspaceMemory(content: safe, updatedAt: now, updatedBy: author)
    }

    /// Acrescenta uma nota curada ao diário UTC do dia, nunca a saída de uma sessão.
    @discardableResult
    func appendDaily(_ content: String, author: Author, date: Date = Date()) throws -> String {
        try requireHumanOrSystem(author)
        let safe = try MemorySanitizer.forWriting(content, maximumBytes: Self.maximumDailyBytes)
        let url = dailyURL(for: date)
        let timestamp = ISO8601DateFormatter().string(from: date)
        let prior = readMarkdown(url)
        let entry = "## \(timestamp) — \(author.rawValue)\n\n\(safe)\n"
        let combined = prior.isEmpty ? entry : "\(prior.trimmingCharacters(in: .whitespacesAndNewlines))\n\n\(entry)"
        try writeMarkdown(combined, to: url)
        try appendHistory(.dailyAppended, author: author, at: date, detail: dailyFilename(for: date))
        return combined
    }

    /// Apenas agentes criam sugestões. A operação é idempotente por `id`, se o
    /// chamador estiver repetindo uma request após reconexão.
    @discardableResult
    func propose(
        _ content: String,
        author: Author,
        id: ULID = ULID.generate(),
        now: Date = Date()
    ) throws -> MemoryProposal {
        guard case .agente = author else { throw MemoryStoreError.authorizationDenied }
        let safe = try MemorySanitizer.forWriting(content, maximumBytes: Self.maximumProposalBytes)
        var values = loadProposals()
        if let existing = values.first(where: { $0.id == id }) { return existing }
        let proposal = MemoryProposal(id: id, content: safe, author: author, createdAt: now)
        values.append(proposal)
        try saveProposals(values)
        try appendHistory(.proposalCreated, author: author, at: now, proposalID: id)
        return proposal
    }

    func list(status: MemoryProposalStatus? = nil) -> [MemoryProposal] {
        loadProposals()
            .filter { status == nil || $0.status == status }
            .map { proposal in
                var safe = proposal
                safe.content = MemorySanitizer.forReading(safe.content, maximumBytes: Self.maximumProposalBytes)
                safe.resolutionNote = safe.resolutionNote.map {
                    MemorySanitizer.forReading($0, maximumBytes: 500)
                }
                return safe
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Aceitar é idempotente: uma segunda chamada retorna a memória já aceita e
    /// não duplica conteúdo nem histórico. A edição humana altera a sugestão,
    /// que é acrescentada à memória existente.
    @discardableResult
    func accept(
        _ id: ULID,
        author: Author,
        editedContent: String? = nil,
        now: Date = Date()
    ) throws -> WorkspaceMemory {
        try requireHuman(author)
        var values = loadProposals()
        guard let index = values.firstIndex(where: { $0.id == id }) else { throw MemoryStoreError.proposalNotFound }
        var proposal = values[index]
        if proposal.status == .accepted { return get() }
        guard proposal.status == .pending else { throw MemoryStoreError.invalidTransition }

        // A edição humana altera SOMENTE esta proposta. Aceitar nunca substitui
        // a memória anterior: ela a acrescenta uma vez, preservando o contexto.
        let selected = try MemorySanitizer.forWriting(
            editedContent ?? proposal.content, maximumBytes: Self.maximumProposalBytes)
        let safe = try appendingToMemory(existing: get().content, selected: selected)
        try writeMarkdown(safe, to: memoryURL)
        proposal.status = .accepted
        proposal.resolvedAt = now
        proposal.resolvedBy = author
        values[index] = proposal
        try saveProposals(values)
        try appendHistory(.proposalAccepted, author: author, at: now, proposalID: id)
        return WorkspaceMemory(content: safe, updatedAt: now, updatedBy: author)
    }

    /// Rejeição também é idempotente e não toca em `MEMORY.md`.
    @discardableResult
    func reject(_ id: ULID, author: Author, note: String? = nil, now: Date = Date()) throws -> MemoryProposal {
        try requireHuman(author)
        var values = loadProposals()
        guard let index = values.firstIndex(where: { $0.id == id }) else { throw MemoryStoreError.proposalNotFound }
        var proposal = values[index]
        if proposal.status == .rejected { return proposal }
        guard proposal.status == .pending else { throw MemoryStoreError.invalidTransition }
        proposal.status = .rejected
        proposal.resolvedAt = now
        proposal.resolvedBy = author
        proposal.resolutionNote = try note.map { try MemorySanitizer.forWriting($0, maximumBytes: 500) }
        values[index] = proposal
        try saveProposals(values)
        try appendHistory(.proposalRejected, author: author, at: now, proposalID: id)
        return proposal
    }

    func history() -> [MemoryHistoryEntry] {
        ((try? AtomicJSON.read([MemoryHistoryEntry].self, from: historyURL)) ?? [])
            .sorted { $0.timestamp < $1.timestamp }
    }

    /// Retorno pequeno e seguro para um briefing. O diário é opcional e limitado
    /// ao dia indicado para evitar que a memória vire log de execução.
    func briefing(for date: Date = Date()) -> MemoryBriefing {
        let memory = get()
        let daily = MemorySanitizer.forReading(
            readMarkdown(dailyURL(for: date)), maximumBytes: Self.maximumBriefingBytes)
        return MemoryBriefing(memory: memory, daily: daily)
    }

    private func requireHuman(_ author: Author) throws {
        guard case .humano = author else { throw MemoryStoreError.authorizationDenied }
    }

    private func requireHumanOrSystem(_ author: Author) throws {
        switch author {
        case .humano, .sistema:
            return
        case .agente:
            throw MemoryStoreError.authorizationDenied
        }
    }

    private func loadProposals() -> [MemoryProposal] {
        // Arquivo manualmente truncado/corrompido não derruba o workspace nem
        // transforma JSON técnico em memória; uma escrita posterior o recompõe.
        (try? AtomicJSON.read([MemoryProposal].self, from: proposalsURL)) ?? []
    }

    private func saveProposals(_ values: [MemoryProposal]) throws {
        try AtomicJSON.write(values, to: proposalsURL)
    }

    private func appendHistory(
        _ action: MemoryHistoryAction,
        author: Author,
        at timestamp: Date,
        proposalID: ULID? = nil,
        detail: String? = nil
    ) throws {
        var values = history()
        values.append(MemoryHistoryEntry(
            id: ULID.generate(), action: action, author: author, timestamp: timestamp,
            proposalID: proposalID, detail: detail))
        if values.count > Self.maximumHistoryEntries {
            values.removeFirst(values.count - Self.maximumHistoryEntries)
        }
        try AtomicJSON.write(values, to: historyURL)
    }

    private func readMarkdown(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url), let value = String(data: data, encoding: .utf8) else { return "" }
        return value
    }

    private func writeMarkdown(_ content: String, to url: URL) throws {
        let normalized = content.trimmingCharacters(in: .whitespacesAndNewlines)
        try AtomicFile.replace(Data((normalized.isEmpty ? "" : normalized + "\n").utf8), at: url)
    }

    /// Junta a proposta aprovada sem duplicar o trecho já existente. Quando o
    /// limite explícito é alcançado, preserva a proposta mais nova integralmente
    /// e marca a parte histórica compactada, em vez de cortar a aprovação.
    private func appendingToMemory(existing: String, selected: String) throws -> String {
        let current = MemorySanitizer.forReading(existing, maximumBytes: Self.maximumMemoryBytes)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if current.isEmpty { return selected }
        if current == selected || current.contains(selected) { return current }
        let separator = "\n\n"
        let combined = current + separator + selected
        if Data(combined.utf8).count <= Self.maximumMemoryBytes { return combined }

        let marker = "\n[HISTÓRICO_COMPACTADO]\n\n"
        let available = max(0, Self.maximumMemoryBytes - Data((marker + selected).utf8).count)
        let prefix = String(decoding: Data(current.utf8).prefix(available), as: UTF8.self)
        let compacted = prefix + marker + selected
        return try MemorySanitizer.forWriting(compacted, maximumBytes: Self.maximumMemoryBytes)
    }

    private func dailyURL(for date: Date) -> URL {
        dailyDirectory.appendingPathComponent(dailyFilename(for: date))
    }

    private func dailyFilename(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d.md", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

private enum MemorySanitizer {
    private static let secretPatterns: [String] = [
        #"(?i)\b(?:api[_-]?key|token|secret|password|passwd|authorization)\s*[:=]\s*[^\s]+"#,
        #"(?i)\bbearer\s+[a-z0-9._~+\-/=]{12,}"#,
        #"\bsk-[A-Za-z0-9_-]{16,}\b"#,
        #"\bgh[pousr]_[A-Za-z0-9_]{16,}\b"#,
        #"\bxox[baprs]-[A-Za-z0-9-]{16,}\b"#,
        #"\bAKIA[0-9A-Z]{16}\b"#,
    ]
    private static let rawTranscriptMarkers = [
        "begin prompt", "end prompt", "begin raw output", "end raw output", "full prompt", "raw terminal output",
    ]

    static func forWriting(_ content: String, maximumBytes: Int) throws -> String {
        let normalized = normalized(content)
        guard !normalized.isEmpty, !looksLikeRawTranscript(normalized) else { throw MemoryStoreError.invalidContent }
        return redactAndLimit(normalized, maximumBytes: maximumBytes)
    }

    static func forReading(_ content: String, maximumBytes: Int) -> String {
        redactAndLimit(normalized(content), maximumBytes: maximumBytes)
    }

    private static func normalized(_ value: String) -> String {
        value.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .unicodeScalars.filter {
                !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t"
            }
            .map(String.init)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func looksLikeRawTranscript(_ content: String) -> Bool {
        let lower = content.lowercased()
        if rawTranscriptMarkers.contains(where: lower.contains) { return true }
        if content.contains("```") { return true }
        let transcriptLines = content.split(separator: "\n").filter {
            let line = $0.trimmingCharacters(in: .whitespaces).lowercased()
            return line.hasPrefix("system:") || line.hasPrefix("user:") || line.hasPrefix("assistant:")
        }
        return transcriptLines.count >= 2
    }

    private static func redactAndLimit(_ content: String, maximumBytes: Int) -> String {
        var result = content
        for pattern in secretPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "[SEGREDO_REMOVIDO]")
        }
        let data = Data(result.utf8)
        guard data.count > maximumBytes else { return result }
        let prefix = String(decoding: data.prefix(max(0, maximumBytes - 28)), as: UTF8.self)
        return prefix + "\n[MEMÓRIA_TRUNCADA]"
    }
}
