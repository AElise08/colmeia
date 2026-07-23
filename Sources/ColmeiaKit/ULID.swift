import Foundation

/// ULID (§0): 26 chars Crockford base32, ordenável lexicograficamente por tempo.
/// Gerador monotônico: dentro do mesmo milissegundo (ou com relógio andando para trás)
/// os 80 bits aleatórios são incrementados, preservando a ordem de criação.
public struct ULID: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public static let length = 26

    /// Sempre canônico: 26 chars maiúsculos do alfabeto Crockford.
    public let string: String

    static let alphabet: [UInt8] = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ".utf8)
    private static let alphabetSet = Set(alphabet)

    public init?(_ string: String) {
        let canonical = string.uppercased()
        guard ULID.isValid(canonical) else { return nil }
        self.string = canonical
    }

    init(unchecked string: String) {
        self.string = string
    }

    public static func generate(now: Date = Date()) -> ULID {
        ULIDGenerator.shared.next(now: now)
    }

    /// Estrito: exige forma canônica (maiúscula); primeiro char ≤ "7" evita overflow de 128 bits.
    public static func isValid(_ string: String) -> Bool {
        let bytes = Array(string.utf8)
        guard bytes.count == length else { return false }
        guard let first = bytes.first,
              first >= UInt8(ascii: "0"), first <= UInt8(ascii: "7") else { return false }
        return bytes.allSatisfy { alphabetSet.contains($0) }
    }

    static func encode(millis: UInt64, random: [UInt8]) -> String {
        precondition(random.count == 10)
        var chars = [UInt8]()
        chars.reserveCapacity(length)
        var shift = 45
        while shift >= 0 {
            chars.append(alphabet[Int((millis >> UInt64(shift)) & 0x1F)])
            shift -= 5
        }
        var hi: UInt64 = 0
        for byte in random[0..<5] { hi = (hi << 8) | UInt64(byte) }
        var lo: UInt64 = 0
        for byte in random[5..<10] { lo = (lo << 8) | UInt64(byte) }
        for word in [hi, lo] {
            shift = 35
            while shift >= 0 {
                chars.append(alphabet[Int((word >> UInt64(shift)) & 0x1F)])
                shift -= 5
            }
        }
        return String(decoding: chars, as: UTF8.self)
    }

    public var description: String { string }

    public static func < (lhs: ULID, rhs: ULID) -> Bool { lhs.string < rhs.string }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let ulid = ULID(raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "ULID inválido: \(raw)")
        }
        self = ulid
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(string)
    }
}

final class ULIDGenerator: @unchecked Sendable {
    static let shared = ULIDGenerator()

    private let lock = NSLock()
    private var lastMillis: UInt64 = 0
    private var lastRandom = [UInt8](repeating: 0, count: 10)

    func next(now: Date) -> ULID {
        let wallMillis = UInt64(max(0, now.timeIntervalSince1970 * 1000)) & 0xFFFF_FFFF_FFFF
        lock.lock()
        defer { lock.unlock() }
        let millis = max(wallMillis, lastMillis)
        if millis == lastMillis {
            incrementLastRandom()
        } else {
            lastMillis = millis
            lastRandom = ULIDGenerator.randomBytes()
        }
        return ULID(unchecked: ULID.encode(millis: millis, random: lastRandom))
    }

    private func incrementLastRandom() {
        var index = lastRandom.count - 1
        while index >= 0 {
            if lastRandom[index] == 0xFF {
                lastRandom[index] = 0
                index -= 1
            } else {
                lastRandom[index] += 1
                return
            }
        }
    }

    private static func randomBytes() -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        let a = generator.next()
        let b = generator.next()
        var bytes = [UInt8]()
        bytes.reserveCapacity(10)
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8((a >> UInt64(shift)) & 0xFF))
        }
        bytes.append(UInt8(b & 0xFF))
        bytes.append(UInt8((b >> 8) & 0xFF))
        return bytes
    }
}
