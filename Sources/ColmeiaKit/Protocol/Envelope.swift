import Foundation

/// Envelope do protocolo (§6.2): três kinds em NDJSON sobre o socket (§6.1).
/// Campos desconhecidos DEVEM ser ignorados (§0).
public enum Envelope: Codable, Equatable, Sendable {
    case request(RequestMessage)
    case response(ResponseMessage)
    case event(EventMessage)

    private enum CodingKeys: String, CodingKey { case kind }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "request":
            self = .request(try RequestMessage(from: decoder))
        case "response":
            self = .response(try ResponseMessage(from: decoder))
        case "event":
            self = .event(try EventMessage(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container,
                debugDescription: "kind desconhecido: \(kind)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .request(let message): try message.encode(to: encoder)
        case .response(let message): try message.encode(to: encoder)
        case .event(let message): try message.encode(to: encoder)
        }
    }
}

/// `id` correlaciona request↔response; gerado pelo cliente; DEVE ser único por conexão (§6.2).
public struct RequestMessage: Codable, Equatable, Sendable {
    public var id: String
    public var method: String
    public var params: JSONValue?

    private enum CodingKeys: String, CodingKey { case kind, id, method, params }

    public init(id: String, method: String, params: JSONValue? = nil) {
        self.id = id
        self.method = method
        self.params = params
    }

    public init(id: String, method: ColmeiaMethod, params: JSONValue? = nil) {
        self.init(id: id, method: method.rawValue, params: params)
    }

    public var knownMethod: ColmeiaMethod? { ColmeiaMethod(rawValue: method) }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        method = try container.decode(String.self, forKey: .method)
        params = try container.decodeIfPresent(JSONValue.self, forKey: .params)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("request", forKey: .kind)
        try container.encode(id, forKey: .id)
        try container.encode(method, forKey: .method)
        try container.encodeIfPresent(params, forKey: .params)
    }

    public func decodeParams<P: Decodable>(_ type: P.Type) throws -> P {
        try (params ?? .object([:])).decode(as: type)
    }
}

/// Toda request DEVE receber exatamente uma response (§6.2).
public struct ResponseMessage: Codable, Equatable, Sendable {
    public var id: String
    public var ok: Bool
    public var result: JSONValue?
    public var error: ProtocolError?

    private enum CodingKeys: String, CodingKey { case kind, id, ok, result, error }

    public init(id: String, result: JSONValue?) {
        self.id = id
        self.ok = true
        self.result = result
        self.error = nil
    }

    public init(id: String, error: ProtocolError) {
        self.id = id
        self.ok = false
        self.result = nil
        self.error = error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        ok = try container.decode(Bool.self, forKey: .ok)
        result = try container.decodeIfPresent(JSONValue.self, forKey: .result)
        error = try container.decodeIfPresent(ProtocolError.self, forKey: .error)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("response", forKey: .kind)
        try container.encode(id, forKey: .id)
        try container.encode(ok, forKey: .ok)
        try container.encodeIfPresent(result, forKey: .result)
        try container.encodeIfPresent(error, forKey: .error)
    }
}

/// Sem `id`; flui apenas engine→cliente, apenas para tópicos assinados (§6.2).
public struct EventMessage: Codable, Equatable, Sendable {
    public var topic: String
    public var params: JSONValue

    private enum CodingKeys: String, CodingKey { case kind, topic, params }

    public init(topic: String, params: JSONValue) {
        self.topic = topic
        self.params = params
    }

    public init(topic: ColmeiaTopic, params: JSONValue) {
        self.init(topic: topic.rawValue, params: params)
    }

    public var knownTopic: ColmeiaTopic? { ColmeiaTopic(rawValue: topic) }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        topic = try container.decode(String.self, forKey: .topic)
        params = try container.decodeIfPresent(JSONValue.self, forKey: .params) ?? .object([:])
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("event", forKey: .kind)
        try container.encode(topic, forKey: .topic)
        try container.encode(params, forKey: .params)
    }

    public func decodeParams<P: Decodable>(_ type: P.Type) throws -> P {
        try params.decode(as: type)
    }
}
