import Foundation

/// §6.6 — nomes estáveis e portáveis; snake_case exatamente como na spec.
/// Clientes DEVEM decidir comportamento pelo `name`, nunca por parsing da `message`.
public enum ProtocolErrorName: String, Codable, CaseIterable, Sendable {
    case protocol_version_mismatch
    case workspace_not_found
    case node_not_found
    case session_not_found
    case session_already_running
    case session_not_running
    case duplicate_node_name
    case adapter_not_found
    case adapter_launch_failed
    case approval_not_found
    case approval_already_resolved
    case routine_not_found
    case routine_target_missing
    case floor_not_found
    case floor_dirty
    case floor_mechanism_unavailable
    case journal_corrupted
    case document_corrupted
    case invalid_params
    case confirmation_required
    case internal_error
}

/// Corpo de `error` no envelope de response (§6.2). `name` fica como String no wire
/// porque extensões documentadas são permitidas (§6.6); `known` mapeia para o enum.
public struct ProtocolError: Error, Codable, Equatable, Sendable, CustomStringConvertible {
    public var name: String
    public var message: String

    public var known: ProtocolErrorName? { ProtocolErrorName(rawValue: name) }

    public init(name: ProtocolErrorName, message: String) {
        self.name = name.rawValue
        self.message = message
    }

    public init(name: String, message: String) {
        self.name = name
        self.message = message
    }

    public var description: String { "\(name): \(message)" }
}
