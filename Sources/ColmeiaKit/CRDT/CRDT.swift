import Foundation

/// A last-write-wins register. A larger HLC timestamp wins.
public struct LWWRegister<Value: Codable & Equatable & Sendable>: Codable, Sendable, Equatable {
    public let target: String
    public let value: Value
    public let timestamp: HLC

    public init(target: String, value: Value, timestamp: HLC) {
        self.target = target
        self.value = value
        self.timestamp = timestamp
    }
}

public typealias JSONLWWRegister = LWWRegister<JSONValue>

/// An immutable RGA node. Tombstones are retained in the resolver and are never
/// removed from the operation history, so later inserts can still refer to them.
public struct RGAElement: Codable, Sendable, Equatable {
    public let id: HLC
    public let left: HLC?
    public let value: String
    public let tombstone: Bool

    public init(id: HLC, left: HLC? = nil, value: String, tombstone: Bool = false) {
        self.id = id
        self.left = left
        self.value = value
        self.tombstone = tombstone
    }

    public var character: String { value }
    public var isTombstone: Bool { tombstone }
}

public typealias RGACharacter = RGAElement

public struct LWWSetOperation: Codable, Sendable, Equatable {
    public let target: String
    public let value: JSONValue
    public let timestamp: HLC
    public let causal_deps: [HLC]

    public init(
        target: String,
        value: JSONValue,
        timestamp: HLC,
        causal_deps: [HLC] = []
    ) {
        self.target = target
        self.value = value
        self.timestamp = timestamp
        self.causal_deps = causal_deps
    }

    public var causalDeps: [HLC] { causal_deps }
    public var operationID: HLC { timestamp }
}

public struct RGAInsertOperation: Codable, Sendable, Equatable {
    public let id: HLC
    public let left: HLC?
    public let value: String
    public let causal_deps: [HLC]

    public init(
        id: HLC,
        left: HLC? = nil,
        value: String,
        causal_deps: [HLC] = []
    ) {
        self.id = id
        self.left = left
        self.value = value
        self.causal_deps = causal_deps
    }

    public init(
        id: HLC,
        left: HLC? = nil,
        character: String,
        causal_deps: [HLC] = []
    ) {
        self.init(id: id, left: left, value: character, causal_deps: causal_deps)
    }

    public var character: String { value }
    public var causalDeps: [HLC] { causal_deps }
    public var operationID: HLC { id }
}

public struct RGADeleteOperation: Codable, Sendable, Equatable {
    /// The element being deleted.
    public let target: HLC
    /// A distinct operation id is required so deletion cannot be confused with
    /// the insertion that created the target element.
    public let operation_id: HLC
    public let causal_deps: [HLC]

    public init(target: HLC, operation_id: HLC, causal_deps: [HLC] = []) {
        self.target = target
        self.operation_id = operation_id
        self.causal_deps = causal_deps
    }

    public init(id: HLC, operationID: HLC, causalDeps: [HLC] = []) {
        self.init(target: id, operation_id: operationID, causal_deps: causalDeps)
    }

    public var id: HLC { target }
    public var operationID: HLC { operation_id }
    public var causalDeps: [HLC] { causal_deps }
}

/// The portable operation union. The discriminator is stable JSON and all
/// causal dependencies are represented as HLC values.
public enum CRDTOperation: Codable, Sendable, Equatable {
    case lwwSet(LWWSetOperation)
    case rgaInsert(RGAInsertOperation)
    case rgaDelete(RGADeleteOperation)

    public static func set(
        target: String,
        value: JSONValue,
        timestamp: HLC,
        causal_deps: [HLC] = []
    ) -> CRDTOperation {
        .lwwSet(LWWSetOperation(target: target, value: value, timestamp: timestamp, causal_deps: causal_deps))
    }

    public static func insert(
        id: HLC,
        left: HLC? = nil,
        value: String,
        causal_deps: [HLC] = []
    ) -> CRDTOperation {
        .rgaInsert(RGAInsertOperation(id: id, left: left, value: value, causal_deps: causal_deps))
    }

    public static func delete(
        target: HLC,
        operation_id: HLC,
        causal_deps: [HLC] = []
    ) -> CRDTOperation {
        .rgaDelete(RGADeleteOperation(target: target, operation_id: operation_id, causal_deps: causal_deps))
    }

    public var operationID: HLC {
        switch self {
        case .lwwSet(let operation): return operation.operationID
        case .rgaInsert(let operation): return operation.operationID
        case .rgaDelete(let operation): return operation.operationID
        }
    }

    public var causal_deps: [HLC] {
        switch self {
        case .lwwSet(let operation): return operation.causal_deps
        case .rgaInsert(let operation): return operation.causal_deps
        case .rgaDelete(let operation): return operation.causal_deps
        }
    }

    public var causalDeps: [HLC] { causal_deps }

    private enum CodingKeys: String, CodingKey { case kind, operation }
    private enum Kind: String, Codable { case lwwSet = "lww_set", rgaInsert = "rga_insert", rgaDelete = "rga_delete" }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .lwwSet: self = .lwwSet(try container.decode(LWWSetOperation.self, forKey: .operation))
        case .rgaInsert: self = .rgaInsert(try container.decode(RGAInsertOperation.self, forKey: .operation))
        case .rgaDelete: self = .rgaDelete(try container.decode(RGADeleteOperation.self, forKey: .operation))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .lwwSet(let operation):
            try container.encode(Kind.lwwSet, forKey: .kind)
            try container.encode(operation, forKey: .operation)
        case .rgaInsert(let operation):
            try container.encode(Kind.rgaInsert, forKey: .kind)
            try container.encode(operation, forKey: .operation)
        case .rgaDelete(let operation):
            try container.encode(Kind.rgaDelete, forKey: .kind)
            try container.encode(operation, forKey: .operation)
        }
    }
}

public typealias RGAOperation = CRDTOperation

/// The materialized view exposed by CRDTResolver.
public struct CRDTMaterializedState: Codable, Sendable, Equatable {
    public let registers: [String: JSONValue]
    public let text: String
    public let characters: [RGAElement]

    public init(registers: [String: JSONValue], text: String, characters: [RGAElement]) {
        self.registers = registers
        self.text = text
        self.characters = characters
    }
}

/// A lock-protected resolver for LWW and RGA operations.
///
/// Operations whose causal dependencies have not arrived are retained. Once a
/// dependency is applied, the pending queue is drained to a fixed point. RGA
/// tombstones and left references remain in memory even when they are invisible
/// in the rendered text.
public final class CRDTResolver: @unchecked Sendable {
    private let lock = NSLock()
    private var registers: [String: JSONLWWRegister] = [:]
    private var elements: [HLC: RGAElement] = [:]
    private var tombstones: Set<HLC> = []
    private var appliedOperationIDs: Set<HLC> = []
    private var pending: [CRDTOperation] = []
    private var pendingOperationIDs: Set<HLC> = []

    public init() {}

    /// Applies an operation, or queues it if one of its causal dependencies is
    /// not known yet. Returns true only when the operation was applied now.
    @discardableResult
    public func apply(_ operation: CRDTOperation) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !appliedOperationIDs.contains(operation.operationID),
              !pendingOperationIDs.contains(operation.operationID) else { return false }
        guard dependenciesAreReady(for: operation) else {
            pending.append(operation)
            pendingOperationIDs.insert(operation.operationID)
            return false
        }
        applyReady(operation)
        drainPending()
        return true
    }

    @discardableResult
    public func apply(_ operation: LWWSetOperation) -> Bool {
        apply(CRDTOperation.lwwSet(operation))
    }

    @discardableResult
    public func apply(_ operation: RGAInsertOperation) -> Bool {
        apply(CRDTOperation.rgaInsert(operation))
    }

    @discardableResult
    public func apply(_ operation: RGADeleteOperation) -> Bool {
        apply(CRDTOperation.rgaDelete(operation))
    }

    public func apply<S: Sequence>(contentsOf operations: S) where S.Element == CRDTOperation {
        for operation in operations { _ = apply(operation) }
    }

    public var pendingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return pending.count
    }

    public var materialized: CRDTMaterializedState {
        lock.lock(); defer { lock.unlock() }
        return makeMaterializedState()
    }

    public var materializedState: CRDTMaterializedState { materialized }
    public var text: String { materialized.text }
    public var renderedText: String { materialized.text }
    public var characters: [RGAElement] { materialized.characters }
    public var rgaElements: [RGAElement] { materialized.characters }

    public func value(for target: String) -> JSONValue? {
        lock.lock(); defer { lock.unlock() }
        return registers[target]?.value
    }

    public func register(for target: String) -> JSONLWWRegister? {
        lock.lock(); defer { lock.unlock() }
        return registers[target]
    }

    public var registerValues: [String: JSONValue] {
        lock.lock(); defer { lock.unlock() }
        return registers.mapValues(\.value)
    }

    public var knownOperationIDs: Set<HLC> {
        lock.lock(); defer { lock.unlock() }
        return appliedOperationIDs
    }

    private func dependenciesAreReady(for operation: CRDTOperation) -> Bool {
        operation.causal_deps.allSatisfy { appliedOperationIDs.contains($0) }
    }

    private func applyReady(_ operation: CRDTOperation) {
        appliedOperationIDs.insert(operation.operationID)
        switch operation {
        case .lwwSet(let set):
            let candidate = JSONLWWRegister(target: set.target, value: set.value, timestamp: set.timestamp)
            if let existing = registers[set.target] {
                if existing.timestamp < candidate.timestamp {
                    registers[set.target] = candidate
                } else if existing.timestamp == candidate.timestamp && stableJSON(set.value) > stableJSON(existing.value) {
                    registers[set.target] = candidate
                }
            } else {
                registers[set.target] = candidate
            }
        case .rgaInsert(let insert):
            if elements[insert.id] == nil {
                elements[insert.id] = RGAElement(
                    id: insert.id,
                    left: insert.left,
                    value: insert.value,
                    tombstone: tombstones.contains(insert.id))
            }
        case .rgaDelete(let delete):
            tombstones.insert(delete.target)
            if let existing = elements[delete.target] {
                elements[delete.target] = RGAElement(
                    id: existing.id,
                    left: existing.left,
                    value: existing.value,
                    tombstone: true)
            }
        }
    }

    private func drainPending() {
        var madeProgress = true
        while madeProgress {
            madeProgress = false
            var remaining: [CRDTOperation] = []
            for operation in pending {
                if dependenciesAreReady(for: operation) {
                    pendingOperationIDs.remove(operation.operationID)
                    applyReady(operation)
                    madeProgress = true
                } else {
                    remaining.append(operation)
                }
            }
            pending = remaining
        }
    }

    private func makeMaterializedState() -> CRDTMaterializedState {
        let ordered = orderedElements()
        return CRDTMaterializedState(
            registers: registers.mapValues(\.value),
            text: ordered.filter { !$0.tombstone }.map(\.value).joined(),
            characters: ordered)
    }

    /// RGA order is a depth-first traversal of left-reference children. Each
    /// sibling is sorted by its HLC, making concurrent inserts converge.
    private func orderedElements() -> [RGAElement] {
        var roots: [HLC] = []
        var children: [HLC: [HLC]] = [:]
        for element in elements.values {
            if let left = element.left, elements[left] != nil {
                children[left, default: []].append(element.id)
            } else {
                roots.append(element.id)
            }
        }
        roots.sort()
        for key in children.keys { children[key]?.sort() }

        var result: [RGAElement] = []
        var visited: Set<HLC> = []
        func visit(_ id: HLC) {
            guard !visited.contains(id), let element = elements[id] else { return }
            visited.insert(id)
            result.append(element)
            for child in children[id] ?? [] { visit(child) }
        }
        for root in roots { visit(root) }

        // Malformed/cyclic references must not prevent deterministic materialization.
        for id in elements.keys.sorted() { visit(id) }
        return result
    }

    private func stableJSON(_ value: JSONValue) -> String {
        guard let data = try? ColmeiaJSON.encoder().encode(value) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
