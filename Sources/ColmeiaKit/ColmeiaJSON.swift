import Foundation

/// Coders canônicos do projeto. Timestamps são ISO-8601 UTC com milissegundos (§0);
/// na leitura aceita-se também sem fração. Todo JSON do protocolo/storage DEVE passar por aqui.
public enum ColmeiaJSON {
    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    public static func string(from date: Date) -> String {
        isoFractional.string(from: date)
    }

    public static func date(from string: String) -> Date? {
        isoFractional.date(from: string) ?? isoPlain.date(from: string)
    }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(string(from: date))
        }
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let date = date(from: raw) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "timestamp não é ISO-8601: \(raw)"
                )
            }
            return date
        }
        return decoder
    }
}
