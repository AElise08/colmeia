import Foundation

/// A hybrid logical clock value.
///
/// The textual form is deliberately independent of locale and date formatting:
/// `wall_time:counter:uuid`, where `wall_time` is Unix time in milliseconds.
public struct HLC: Sendable, Codable, Comparable, Equatable, Hashable, CustomStringConvertible {
    public let wall_time: UInt64
    public let counter: UInt32
    public let node_id: UUID

    public init(wall_time: UInt64, counter: UInt32 = 0, node_id: UUID) {
        self.wall_time = wall_time
        self.counter = counter
        self.node_id = node_id
    }

    public init(wallTime: UInt64, counter: UInt32 = 0, nodeID: UUID) {
        self.init(wall_time: wallTime, counter: counter, node_id: nodeID)
    }

    /// Parses the canonical `wall_time:counter:uuid` representation.
    public init?(_ string: String) {
        let parts = string.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let wall = UInt64(parts[0]),
              let counter = UInt32(parts[1]),
              let node = UUID(uuidString: String(parts[2])) else { return nil }
        self.init(wall_time: wall, counter: counter, node_id: node)
    }

    public var wallTime: UInt64 { wall_time }
    public var nodeID: UUID { node_id }

    public var description: String {
        "\(wall_time):\(counter):\(node_id.uuidString.lowercased())"
    }

    public static func < (lhs: HLC, rhs: HLC) -> Bool {
        if lhs.wall_time != rhs.wall_time { return lhs.wall_time < rhs.wall_time }
        if lhs.counter != rhs.counter { return lhs.counter < rhs.counter }
        return lhs.node_id.uuidString.lowercased() < rhs.node_id.uuidString.lowercased()
    }

    public init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let raw = try? single.decode(String.self), let value = HLC(raw) {
            self = value
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        let wall = try container.decode(UInt64.self, forKey: .wallTime)
        let counter = try container.decode(UInt32.self, forKey: .counter)
        let node = try container.decode(UUID.self, forKey: .nodeID)
        self.init(wall_time: wall, counter: counter, node_id: node)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    private enum CodingKeys: String, CodingKey {
        case wallTime = "wall_time"
        case counter
        case nodeID = "node_id"
    }
}

/// A process-local HLC clock. The physical clock is only used as a lower bound;
/// ordering and merges are always decided by HLC values.
public final class HLCClock: @unchecked Sendable {
    private let lock = NSLock()
    public let node_id: UUID
    private let wallTime: @Sendable () -> UInt64
    private var last: HLC

    /// Sendable wrapper used by the public default arguments.
    public static let defaultWallTime: @Sendable () -> UInt64 = {
        HLCClock.currentWallTimeMilliseconds()
    }

    public init(
        node_id: UUID = UUID(),
        wallTime: @escaping @Sendable () -> UInt64 = HLCClock.defaultWallTime
    ) {
        self.node_id = node_id
        self.wallTime = wallTime
        self.last = HLC(wall_time: 0, counter: 0, node_id: node_id)
    }

    public convenience init(nodeID: UUID, wallTime: @escaping @Sendable () -> UInt64 = HLCClock.defaultWallTime) {
        self.init(node_id: nodeID, wallTime: wallTime)
    }

    public var nodeID: UUID { node_id }

    /// Emits a local event after the last value emitted or merged by this clock.
    public func tick() -> HLC {
        lock.lock()
        defer { lock.unlock() }
        let physical = wallTime()
        let wall = max(physical, last.wall_time)
        let nextCounter: UInt32
        var nextWall: UInt64
        if wall > last.wall_time {
            nextWall = wall
            nextCounter = 0
        } else if last.counter == UInt32.max {
            nextWall = last.wall_time == UInt64.max ? UInt64.max : last.wall_time + 1
            nextCounter = 0
        } else {
            nextWall = last.wall_time
            nextCounter = last.counter + 1
        }
        last = HLC(wall_time: nextWall, counter: nextCounter, node_id: node_id)
        return last
    }

    public func now() -> HLC { tick() }
    public func local() -> HLC { tick() }

    /// Merges a remote value and emits the next causally-later local value.
    public func merge(_ remote: HLC) -> HLC {
        lock.lock()
        defer { lock.unlock() }

        let physical = wallTime()
        let wall = max(physical, max(last.wall_time, remote.wall_time))
        let nextCounter: UInt32
        var nextWall: UInt64
        if wall > max(last.wall_time, remote.wall_time) {
            nextWall = wall
            nextCounter = 0
        } else if last.wall_time == remote.wall_time {
            nextWall = wall
            nextCounter = increment(max(last.counter, remote.counter), wall: &nextWall)
        } else if last.wall_time == wall {
            nextWall = wall
            nextCounter = increment(last.counter, wall: &nextWall)
        } else {
            nextWall = wall
            nextCounter = increment(remote.counter, wall: &nextWall)
        }
        last = HLC(wall_time: nextWall, counter: nextCounter, node_id: node_id)
        return last
    }

    public func receive(_ remote: HLC) -> HLC { merge(remote) }

    public var lastValue: HLC {
        lock.lock(); defer { lock.unlock() }
        return last
    }

    private func increment(_ value: UInt32, wall: inout UInt64) -> UInt32 {
        guard value == UInt32.max else { return value + 1 }
        if wall < UInt64.max { wall += 1 }
        return 0
    }

    public static func currentWallTimeMilliseconds() -> UInt64 {
        let seconds = Date().timeIntervalSince1970
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return UInt64(seconds * 1000.0)
    }
}

public typealias HybridLogicalClock = HLCClock
