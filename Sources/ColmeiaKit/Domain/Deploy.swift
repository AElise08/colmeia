import Foundation

public enum DeployRequestState: String, Codable, CaseIterable, Sendable {
    case draft
    case awaitingReview = "awaiting_review"
    case approved
    case awaitingConfirmation = "awaiting_confirmation"
    case deploying
    case succeeded
    case failed
    case canceled
}

/// Destino cadastrado; cadastrar não concede capacidade de execução.
public struct DeployTarget: Codable, Equatable, Sendable, Identifiable {
    public var id: ULID
    public var workspaceID: ULID
    public var roomID: ULID
    public var name: String
    public var environment: String
    public var resource: String
    public var subjectID: String
    public var allowed: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, environment, resource, allowed
        case workspaceID = "workspace_id"
        case roomID = "room_id"
        case subjectID = "subject_id"
    }

    public init(
        id: ULID = .generate(), workspaceID: ULID, roomID: ULID,
        name: String, environment: String, resource: String,
        subjectID: String, allowed: Bool = true
    ) {
        self.id = id; self.workspaceID = workspaceID; self.roomID = roomID
        self.name = name; self.environment = environment; self.resource = resource
        self.subjectID = subjectID; self.allowed = allowed
    }
}

public struct DeployRequest: Codable, Equatable, Sendable, Identifiable {
    public var id: ULID
    public var workspaceID: ULID
    public var deliveryID: ULID
    public var targetID: ULID
    public var requestedBy: Author
    public var confirmedBy: Author?
    public var capabilityGrantID: ULID?
    public var state: DeployRequestState
    public var createdAt: Date
    public var updatedAt: Date
    public var audit: [String]

    enum CodingKeys: String, CodingKey {
        case id, state, audit
        case workspaceID = "workspace_id"
        case deliveryID = "delivery_id"
        case targetID = "target_id"
        case requestedBy = "requested_by"
        case confirmedBy = "confirmed_by"
        case capabilityGrantID = "capability_grant_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(
        id: ULID = .generate(), workspaceID: ULID, deliveryID: ULID,
        targetID: ULID, requestedBy: Author, state: DeployRequestState = .awaitingReview,
        createdAt: Date = Date(), updatedAt: Date = Date(), audit: [String] = []
    ) {
        self.id = id; self.workspaceID = workspaceID; self.deliveryID = deliveryID
        self.targetID = targetID; self.requestedBy = requestedBy; self.confirmedBy = nil
        self.capabilityGrantID = nil; self.state = state; self.createdAt = createdAt
        self.updatedAt = updatedAt; self.audit = audit
    }
}

public struct DeployTargetRegisterParams: Codable, Equatable, Sendable {
    public var target: DeployTarget
    public init(target: DeployTarget) { self.target = target }
}

public struct DeployTargetListParams: Codable, Equatable, Sendable {
    public var workspaceID: ULID
    public init(workspaceID: ULID) { self.workspaceID = workspaceID }
}

public struct DeployRequestParams: Codable, Equatable, Sendable {
    public var workspaceID: ULID
    public var deliveryID: ULID
    public var targetID: ULID
    public init(workspaceID: ULID, deliveryID: ULID, targetID: ULID) {
        self.workspaceID = workspaceID; self.deliveryID = deliveryID; self.targetID = targetID
    }
}

public struct DeployConfirmParams: Codable, Equatable, Sendable {
    public var requestID: ULID
    public var capabilityGrantID: ULID?
    public init(requestID: ULID, capabilityGrantID: ULID? = nil) {
        self.requestID = requestID; self.capabilityGrantID = capabilityGrantID
    }
}

public struct DeployRequestResult: Codable, Equatable, Sendable {
    public var request: DeployRequest
    public init(request: DeployRequest) { self.request = request }
}

public struct DeployTargetResult: Codable, Equatable, Sendable {
    public var target: DeployTarget
    public init(target: DeployTarget) { self.target = target }
}
