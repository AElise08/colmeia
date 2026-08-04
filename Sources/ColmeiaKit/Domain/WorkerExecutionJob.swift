import Foundation

/// Job tipado que cruza a fronteira do Worker. Mensagens e direções da Sala
/// nunca são comandos: a execução só pode começar a partir deste registro,
/// criado por um membro autorizado e ligado a uma sessão.
public enum WorkerExecutionJobState: String, Codable, CaseIterable, Sendable {
    case queued
    case running
    case completed
    case failed
    case canceled
}

public struct WorkerExecutionJob: Codable, Equatable, Sendable, Identifiable {
    public var id: ULID
    public var roomID: ULID
    public var sessionID: ULID
    public var subjectID: String
    public var command: String
    public var requestedBy: Author
    public var createdAt: Date
    public var expiresAt: Date
    public var state: WorkerExecutionJobState
    public var result: String?

    enum CodingKeys: String, CodingKey {
        case id, command, state, result
        case roomID = "room_id"
        case sessionID = "session_id"
        case subjectID = "subject_id"
        case requestedBy = "requested_by"
        case createdAt = "created_at"
        case expiresAt = "expires_at"
    }

    public init(
        id: ULID = .generate(), roomID: ULID, sessionID: ULID, subjectID: String,
        command: String, requestedBy: Author, createdAt: Date = Date(),
        expiresAt: Date, state: WorkerExecutionJobState = .queued, result: String? = nil
    ) throws {
        let normalized = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.utf8.count <= 4_096, !normalized.contains("\0") else {
            throw WorkerExecutionJobError.invalidCommand
        }
        guard expiresAt > createdAt else { throw WorkerExecutionJobError.invalidExpiry }
        self.id = id
        self.roomID = roomID
        self.sessionID = sessionID
        self.subjectID = subjectID
        self.command = normalized
        self.requestedBy = requestedBy
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.state = state
        self.result = result
    }

    public var isExpired: Bool { Date() >= expiresAt }
}

public enum WorkerExecutionJobError: Error, Equatable, Sendable, LocalizedError {
    case invalidCommand
    case invalidExpiry
    case invalidTransition(WorkerExecutionJobState, WorkerExecutionJobState)

    public var errorDescription: String? {
        switch self {
        case .invalidCommand: return "job exige comando não vazio, sem NUL e de até 4 KiB"
        case .invalidExpiry: return "expiração do job deve ser posterior à criação"
        case .invalidTransition(let from, let to):
            return "transição de job inválida: \(from.rawValue) → \(to.rawValue)"
        }
    }
}

extension WorkerExecutionJob {
    public mutating func transition(
        to next: WorkerExecutionJobState, result: String? = nil, now: Date = Date()
    ) throws {
        guard !isExpired || next == .failed || next == .canceled else {
            throw WorkerExecutionJobError.invalidTransition(state, next)
        }
        let valid: Bool = {
            switch (state, next) {
            case (.queued, .running), (.queued, .canceled), (.queued, .failed): return true
            case (.running, .completed), (.running, .failed), (.running, .canceled): return true
            case (.completed, .completed), (.failed, .failed), (.canceled, .canceled): return true
            default: return false
            }
        }()
        guard valid else { throw WorkerExecutionJobError.invalidTransition(state, next) }
        state = next
        if let result { self.result = result }
        if now >= expiresAt, state == .queued { state = .failed }
    }
}
