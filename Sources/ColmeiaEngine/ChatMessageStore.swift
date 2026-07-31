import Foundation
import ColmeiaKit

enum ChatMessageStoreError: Error, Equatable {
    case idempotencyConflict(ULID)
    case invalidText
}

/// Projeção durável e pequena para Agent Chat. O journal de sessão continua
/// sendo a fonte de verdade da execução; esta store é a fonte de verdade da
/// conversa apresentada pela UI.
final class ChatMessageStore: @unchecked Sendable {
    private struct Snapshot: Codable {
        var schemaVersion: Int
        var messages: [ChatMessage]

        enum CodingKeys: String, CodingKey {
            case messages
            case schemaVersion = "schema_version"
        }
    }

    private let fileURL: URL
    private let lock = NSLock()
    private var messages: [ULID: ChatMessage]

    init(fileURL: URL) throws {
        self.fileURL = fileURL
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let snapshot = try AtomicJSON.read(Snapshot.self, from: fileURL)
            var loaded: [ULID: ChatMessage] = [:]
            for message in snapshot.messages {
                guard loaded[message.id] == nil else {
                    throw ChatMessageStoreError.idempotencyConflict(message.id)
                }
                loaded[message.id] = message
            }
            messages = loaded
        } else {
            messages = [:]
        }
    }

    @discardableResult
    func append(_ message: ChatMessage) throws -> ChatMessage {
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 64_000 else {
            throw ChatMessageStoreError.invalidText
        }
        lock.lock()
        defer { lock.unlock() }
        if let existing = messages[message.id] {
            guard existing == message else {
                throw ChatMessageStoreError.idempotencyConflict(message.id)
            }
            return existing
        }
        var normalized = message
        normalized.text = text
        messages[message.id] = normalized
        try persistLocked()
        return normalized
    }

    func list(toNodeID: ULID? = nil, limit: Int = 200) -> [ChatMessage] {
        lock.lock()
        defer { lock.unlock() }
        let bounded = max(1, min(limit, 2_000))
        return messages.values
            .filter { toNodeID == nil || $0.toNodeID == toNodeID || $0.fromNodeID == toNodeID }
            .sorted { lhs, rhs in
                lhs.createdAt == rhs.createdAt ? lhs.id < rhs.id : lhs.createdAt < rhs.createdAt
            }
            .suffix(bounded)
    }

    private func persistLocked() throws {
        let snapshot = Snapshot(
            schemaVersion: 1,
            messages: messages.values.sorted { lhs, rhs in lhs.createdAt < rhs.createdAt })
        try AtomicJSON.write(snapshot, to: fileURL)
    }
}

