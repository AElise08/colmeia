import Foundation

/// Suporte a transporte WebSocket (RFC 6455) sobre TLS (WSS) ou TCP.
/// Permite que clientes de rede (browser, app macOS ou NGINX/Caddy reverse proxy)
/// conectem ao `colmeia-hub` via WebSocket seguro.
public enum WebSocketFraming {
    public static let magicGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    /// SHA-1 puro (RFC 3174) — sem dependência de CryptoKit ou frameworks externos.
    public static func sha1(_ data: Data) -> Data {
        var h0: UInt32 = 0x67452301
        var h1: UInt32 = 0xEFCDAB89
        var h2: UInt32 = 0x98BADCFE
        var h3: UInt32 = 0x10325476
        var h4: UInt32 = 0xC3D2E1F0

        var msg = data
        let bitLen = UInt64(data.count) * 8
        msg.append(0x80)
        while (msg.count % 64) != 56 {
            msg.append(0x00)
        }
        for shift in stride(from: 56, through: 0, by: -8) {
            msg.append(UInt8((bitLen >> shift) & 0xFF))
        }

        for chunkStart in stride(from: 0, to: msg.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 80)
            for i in 0..<16 {
                let idx = chunkStart + i * 4
                w[i] = (UInt32(msg[idx]) << 24) |
                       (UInt32(msg[idx + 1]) << 16) |
                       (UInt32(msg[idx + 2]) << 8) |
                       UInt32(msg[idx + 3])
            }
            for i in 16..<80 {
                let val = w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]
                w[i] = (val << 1) | (val >> 31)
            }

            var a = h0
            var b = h1
            var c = h2
            var d = h3
            var e = h4

            for i in 0..<80 {
                var f: UInt32 = 0
                var k: UInt32 = 0
                if i < 20 {
                    f = (b & c) | ((~b) & d)
                    k = 0x5A827999
                } else if i < 40 {
                    f = b ^ c ^ d
                    k = 0x6ED9EBA1
                } else if i < 60 {
                    f = (b & c) | (b & d) | (c & d)
                    k = 0x8F1BBCDC
                } else {
                    f = b ^ c ^ d
                    k = 0xCA62C1D6
                }
                let temp = ((a << 5) | (a >> 27)) &+ f &+ e &+ k &+ w[i]
                e = d
                d = c
                c = (b << 30) | (b >> 2)
                b = a
                a = temp
            }

            h0 = h0 &+ a
            h1 = h1 &+ b
            h2 = h2 &+ c
            h3 = h3 &+ d
            h4 = h4 &+ e
        }

        var result = Data()
        for h in [h0, h1, h2, h3, h4] {
            result.append(UInt8((h >> 24) & 0xFF))
            result.append(UInt8((h >> 16) & 0xFF))
            result.append(UInt8((h >> 8) & 0xFF))
            result.append(UInt8(h & 0xFF))
        }
        return result
    }

    /// Retorna `Sec-WebSocket-Accept` a partir do `Sec-WebSocket-Key` enviado pelo cliente.
    public static func computeAcceptKey(for clientKey: String) -> String {
        let concatenated = clientKey.trimmingCharacters(in: .whitespacesAndNewlines) + magicGUID
        let hash = sha1(Data(concatenated.utf8))
        return hash.base64EncodedString()
    }

    /// Tenta extrair a chave `Sec-WebSocket-Key` de um cabeçalho de handshake HTTP `GET`.
    public static func parseHandshakeKey(from headerData: Data) -> String? {
        guard let text = String(data: headerData, encoding: .utf8) else { return nil }
        let lowerText = text.lowercased()
        guard lowerText.contains("upgrade: websocket") || lowerText.contains("connection: upgrade") else {
            return nil
        }
        for line in text.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0].lowercased() == "sec-websocket-key" {
                return parts[1]
            }
        }
        return nil
    }

    /// Resposta de handshake HTTP 101 Switching Protocols.
    public static func buildHandshakeResponse(acceptKey: String) -> Data {
        let response = "HTTP/1.1 101 Switching Protocols\r\n" +
            "Upgrade: websocket\r\n" +
            "Connection: Upgrade\r\n" +
            "Sec-WebSocket-Accept: \(acceptKey)\r\n\r\n"
        return Data(response.utf8)
    }

    /// Empacota `payload` (ex.: JSON) num frame de texto WebSocket (opcode 0x1, FIN = 1).
    public static func encodeFrame(_ payload: Data) -> Data {
        var frame = Data()
        frame.append(0x81)

        let len = payload.count
        if len <= 125 {
            frame.append(UInt8(len))
        } else if len <= 65535 {
            frame.append(126)
            frame.append(UInt8((len >> 8) & 0xFF))
            frame.append(UInt8(len & 0xFF))
        } else {
            frame.append(127)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((len >> shift) & 0xFF))
            }
        }
        frame.append(payload)
        return frame
    }

    /// Decodificador de frames WebSocket acumulativo.
    public final class FrameDecoder {
        private var buffer = Data()

        public init() {}

        public func append(_ chunk: Data) -> [Data] {
            buffer.append(chunk)
            var payloads: [Data] = []

            while buffer.count >= 2 {
                let firstByte = buffer[0]
                let secondByte = buffer[1]

                let isMasked = (secondByte & 0x80) != 0
                var payloadLen = Int(secondByte & 0x7F)

                var headerSize = 2
                if payloadLen == 126 {
                    guard buffer.count >= 4 else { break }
                    payloadLen = Int(buffer[2]) << 8 | Int(buffer[3])
                    headerSize = 4
                } else if payloadLen == 127 {
                    guard buffer.count >= 10 else { break }
                    var len64: UInt64 = 0
                    for i in 0..<8 {
                        len64 = (len64 << 8) | UInt64(buffer[2 + i])
                    }
                    payloadLen = Int(len64)
                    headerSize = 10
                }

                let maskSize = isMasked ? 4 : 0
                let totalFrameSize = headerSize + maskSize + payloadLen
                guard buffer.count >= totalFrameSize else { break }

                let payloadStart = headerSize + maskSize
                var rawPayload = buffer.subdata(in: payloadStart..<(payloadStart + payloadLen))

                if isMasked {
                    let mask = buffer.subdata(in: headerSize..<(headerSize + 4))
                    for i in 0..<rawPayload.count {
                        rawPayload[i] ^= mask[i % 4]
                    }
                }

                let opcode = firstByte & 0x0F
                if opcode == 0x1 || opcode == 0x2 {
                    payloads.append(rawPayload)
                }

                buffer.removeSubrange(0..<totalFrameSize)
            }
            return payloads
        }
    }
}
