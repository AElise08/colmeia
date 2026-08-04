import Foundation

private struct CAPCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init(_ string: String) { self.stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

/// CAP (Colmeia Agent Protocol) wire constants and helpers.
public enum CAP {
    public static let version = "1.0.0"
    public static let stateUpdateType = "agent.state_update"
    public static let toolInvocationRequestType = "tool.invocation_request"
    public static let toolInvocationResponseType = "tool.invocation_response"
}

public enum CAPMessageType: String, Codable, Sendable, Equatable {
    case stateUpdate = "agent.state_update"
    case toolInvocationRequest = "tool.invocation_request"
    case toolInvocationResponse = "tool.invocation_response"
}

/// A single CAP message. It can be encoded as one line of NDJSON.
public struct CAPEnvelope: Codable, Sendable, Equatable {
    public let cap_version: String
    public let msg_id: ULID
    public let type: String
    public let timestamp: HLC
    public let payload: JSONValue
    public let additionalFields: [String: JSONValue]

    public init(
        msg_id: ULID,
        type: String,
        timestamp: HLC,
        payload: JSONValue,
        cap_version: String = CAP.version,
        additionalFields: [String: JSONValue] = [:]
    ) {
        self.cap_version = cap_version
        self.msg_id = msg_id
        self.type = type
        self.timestamp = timestamp
        self.payload = payload
        self.additionalFields = additionalFields
    }

    public init(
        msgID: ULID = ULID.generate(),
        type: String,
        timestamp: HLC,
        payload: JSONValue,
        capVersion: String = CAP.version,
        additionalFields: [String: JSONValue] = [:]
    ) {
        self.init(msg_id: msgID, type: type, timestamp: timestamp, payload: payload,
                  cap_version: capVersion, additionalFields: additionalFields)
    }

    public var capVersion: String { cap_version }
    public var msgID: ULID { msg_id }
    public var unknownFields: [String: JSONValue] { additionalFields }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CAPCodingKey.self)
        self.cap_version = try container.decode(String.self, forKey: CAPCodingKey("cap_version"))
        self.msg_id = try container.decode(ULID.self, forKey: CAPCodingKey("msg_id"))
        self.type = try container.decode(String.self, forKey: CAPCodingKey("type"))
        self.timestamp = try container.decode(HLC.self, forKey: CAPCodingKey("timestamp"))
        self.payload = try container.decode(JSONValue.self, forKey: CAPCodingKey("payload"))

        var extras: [String: JSONValue] = [:]
        for key in container.allKeys where !Self.reservedKeys.contains(key.stringValue) {
            if let value = try? container.decode(JSONValue.self, forKey: key) {
                extras[key.stringValue] = value
            }
        }
        self.additionalFields = extras
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CAPCodingKey.self)
        try container.encode(cap_version, forKey: CAPCodingKey("cap_version"))
        try container.encode(msg_id, forKey: CAPCodingKey("msg_id"))
        try container.encode(type, forKey: CAPCodingKey("type"))
        try container.encode(timestamp, forKey: CAPCodingKey("timestamp"))
        try container.encode(payload, forKey: CAPCodingKey("payload"))
        for (key, value) in additionalFields where !Self.reservedKeys.contains(key) {
            try container.encode(value, forKey: CAPCodingKey(key))
        }
    }

    /// Returns exactly one JSON object followed by the NDJSON line terminator.
    public func encodeNDJSON() throws -> Data {
        var data = try ColmeiaJSON.encoder().encode(self)
        data.append(0x0A)
        return data
    }

    public init(ndjsonLine data: Data) throws {
        let line = data.last == 0x0A ? data.dropLast() : data[...]
        self = try ColmeiaJSON.decoder().decode(CAPEnvelope.self, from: Data(line))
    }

    private static let reservedKeys: Set<String> = ["cap_version", "msg_id", "type", "timestamp", "payload"]
}

public struct CAPStateUpdatePayload: Codable, Sendable, Equatable {
    public let state: CAPState
    public let target: String?
    public let reason: String?
    public let data: JSONValue?
    public let additionalFields: [String: JSONValue]

    public init(
        state: CAPState,
        target: String? = nil,
        reason: String? = nil,
        data: JSONValue? = nil,
        additionalFields: [String: JSONValue] = [:]
    ) {
        self.state = state
        self.target = target
        self.reason = reason
        self.data = data
        self.additionalFields = additionalFields
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CAPCodingKey.self)
        state = try c.decode(CAPState.self, forKey: CAPCodingKey("state"))
        target = try c.decodeIfPresent(String.self, forKey: CAPCodingKey("target"))
        reason = try c.decodeIfPresent(String.self, forKey: CAPCodingKey("reason"))
        data = try c.decodeIfPresent(JSONValue.self, forKey: CAPCodingKey("data"))
        additionalFields = try CAPStateUpdatePayload.decodeExtras(c, reserved: ["state", "target", "reason", "data"])
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CAPCodingKey.self)
        try c.encode(state, forKey: CAPCodingKey("state"))
        try c.encodeIfPresent(target, forKey: CAPCodingKey("target"))
        try c.encodeIfPresent(reason, forKey: CAPCodingKey("reason"))
        try c.encodeIfPresent(data, forKey: CAPCodingKey("data"))
        for (key, value) in additionalFields { try c.encode(value, forKey: CAPCodingKey(key)) }
    }

    private static func decodeExtras(
        _ c: KeyedDecodingContainer<CAPCodingKey>, reserved: Set<String>
    ) throws -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        for key in c.allKeys where !reserved.contains(key.stringValue) {
            if let value = try? c.decode(JSONValue.self, forKey: key) { result[key.stringValue] = value }
        }
        return result
    }
}

public struct CAPToolInvocationRequestPayload: Codable, Sendable, Equatable {
    public let request_id: ULID?
    public let tool_name: String
    public let args: JSONValue
    public let requires_approval: Bool
    public let causal_deps: [HLC]
    public let additionalFields: [String: JSONValue]

    public init(
        request_id: ULID? = nil,
        tool_name: String,
        args: JSONValue = .object([:]),
        requires_approval: Bool = false,
        causal_deps: [HLC] = [],
        additionalFields: [String: JSONValue] = [:]
    ) {
        self.request_id = request_id
        self.tool_name = tool_name
        self.args = args
        self.requires_approval = requires_approval
        self.causal_deps = causal_deps
        self.additionalFields = additionalFields
    }

    /// Source-compatible aliases for the pre-v2 API.
    public init(
        invocation_id: ULID? = nil,
        tool: String,
        arguments: JSONValue = .object([:]),
        requires_approval: Bool = false,
        causal_deps: [HLC] = [],
        additionalFields: [String: JSONValue] = [:]
    ) {
        self.init(request_id: invocation_id, tool_name: tool, args: arguments,
                  requires_approval: requires_approval, causal_deps: causal_deps,
                  additionalFields: additionalFields)
    }

    public var requestID: ULID? { request_id }
    public var invocation_id: ULID? { request_id }
    public var invocationID: ULID? { request_id }
    public var tool: String { tool_name }
    public var arguments: JSONValue { args }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CAPCodingKey.self)
        request_id = try c.decodeIfPresent(ULID.self, forKey: CAPCodingKey("request_id"))
            ?? c.decodeIfPresent(ULID.self, forKey: CAPCodingKey("invocation_id"))
        tool_name = try c.decodeIfPresent(String.self, forKey: CAPCodingKey("tool_name"))
            ?? c.decode(String.self, forKey: CAPCodingKey("tool"))
        args = try c.decodeIfPresent(JSONValue.self, forKey: CAPCodingKey("args"))
            ?? c.decode(JSONValue.self, forKey: CAPCodingKey("arguments"))
        requires_approval = try c.decodeIfPresent(Bool.self, forKey: CAPCodingKey("requires_approval")) ?? false
        causal_deps = try c.decodeIfPresent([HLC].self, forKey: CAPCodingKey("causal_deps")) ?? []
        additionalFields = try CAPToolInvocationRequestPayload.decodeExtras(c)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CAPCodingKey.self)
        try c.encodeIfPresent(request_id, forKey: CAPCodingKey("request_id"))
        try c.encode(tool_name, forKey: CAPCodingKey("tool_name"))
        try c.encode(args, forKey: CAPCodingKey("args"))
        try c.encode(requires_approval, forKey: CAPCodingKey("requires_approval"))
        if !causal_deps.isEmpty { try c.encode(causal_deps, forKey: CAPCodingKey("causal_deps")) }
        for (key, value) in additionalFields { try c.encode(value, forKey: CAPCodingKey(key)) }
    }

    private static func decodeExtras(_ c: KeyedDecodingContainer<CAPCodingKey>) throws -> [String: JSONValue] {
        let reserved: Set<String> = [
            "request_id", "tool_name", "args", "requires_approval", "causal_deps",
            "invocation_id", "tool", "arguments"
        ]
        var result: [String: JSONValue] = [:]
        for key in c.allKeys where !reserved.contains(key.stringValue) {
            if let value = try? c.decode(JSONValue.self, forKey: key) { result[key.stringValue] = value }
        }
        return result
    }
}

public struct CAPToolInvocationResponsePayload: Codable, Sendable, Equatable {
    public let request_id: ULID?
    public let status: CAPToolInvocationStatus
    public let result: JSONValue?
    public let error: String?
    public let additionalFields: [String: JSONValue]

    public init(
        request_id: ULID? = nil,
        status: CAPToolInvocationStatus,
        result: JSONValue? = nil,
        error: String? = nil,
        additionalFields: [String: JSONValue] = [:]
    ) {
        self.request_id = request_id
        self.status = status
        self.result = result
        self.error = error
        self.additionalFields = additionalFields
    }

    public init(
        invocation_id: ULID? = nil,
        success: Bool,
        result: JSONValue? = nil,
        error: String? = nil,
        additionalFields: [String: JSONValue] = [:]
    ) {
        self.init(request_id: invocation_id, status: success ? .success : .error,
                  result: result, error: error, additionalFields: additionalFields)
    }

    public var requestID: ULID? { request_id }
    public var invocation_id: ULID? { request_id }
    public var invocationID: ULID? { request_id }
    public var success: Bool { status == .success }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CAPCodingKey.self)
        request_id = try c.decodeIfPresent(ULID.self, forKey: CAPCodingKey("request_id"))
            ?? c.decodeIfPresent(ULID.self, forKey: CAPCodingKey("invocation_id"))
        if let decodedStatus = try c.decodeIfPresent(CAPToolInvocationStatus.self, forKey: CAPCodingKey("status")) {
            status = decodedStatus
        } else if try c.decodeIfPresent(Bool.self, forKey: CAPCodingKey("success")) == true {
            status = .success
        } else {
            status = .error
        }
        result = try c.decodeIfPresent(JSONValue.self, forKey: CAPCodingKey("result"))
        error = try c.decodeIfPresent(String.self, forKey: CAPCodingKey("error"))
        let reserved: Set<String> = ["request_id", "status", "result", "error", "invocation_id", "success"]
        var extras: [String: JSONValue] = [:]
        for key in c.allKeys where !reserved.contains(key.stringValue) {
            if let value = try? c.decode(JSONValue.self, forKey: key) { extras[key.stringValue] = value }
        }
        additionalFields = extras
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CAPCodingKey.self)
        try c.encodeIfPresent(request_id, forKey: CAPCodingKey("request_id"))
        try c.encode(status, forKey: CAPCodingKey("status"))
        try c.encodeIfPresent(result, forKey: CAPCodingKey("result"))
        try c.encodeIfPresent(error, forKey: CAPCodingKey("error"))
        for (key, value) in additionalFields { try c.encode(value, forKey: CAPCodingKey(key)) }
    }
}

public enum CAPToolInvocationStatus: String, Codable, Sendable, Equatable {
    case success
    case error
    case pending
}

public typealias StateUpdatePayload = CAPStateUpdatePayload
public typealias ToolInvocationRequestPayload = CAPToolInvocationRequestPayload
public typealias ToolInvocationResponsePayload = CAPToolInvocationResponsePayload
