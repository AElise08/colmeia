import Foundation

public enum HubWSSError: Error, LocalizedError, Sendable {
    case tlsRequired
    case notSupportedOnPlatform

    public var errorDescription: String? {
        switch self {
        case .tlsRequired: return "WSS exige TLS configurado (SecIdentity) — §12.2"
        case .notSupportedOnPlatform: return "WSS não disponível nesta plataforma"
        }
    }
}

#if canImport(Network)
import Network
import Security
import SecurityFoundation

// §12.2 / Marco D — listener WSS para o Hub (macOS).
public final class HubWSSListener: @unchecked Sendable {
    public let port: UInt16
    public let tlsIdentity: SecIdentity?
    public let serverHostname: String?
    private let queue = DispatchQueue(label: "colmeia.hub.wss")
    private var listener: NWListener?

    public init(port: UInt16, tlsIdentity: SecIdentity? = nil, serverHostname: String? = nil) {
        self.port = port
        self.tlsIdentity = tlsIdentity
        self.serverHostname = serverHostname
    }

    public func start() throws {
        let params: NWParameters
            if let identity = tlsIdentity {
            let tlsOptions = NWProtocolTLS.Options()
            let secOptions = tlsOptions.securityProtocolOptions
            sec_protocol_options_set_local_identity(
                secOptions, unsafeBitCast(identity, to: sec_identity_t.self))
            params = NWParameters(tls: tlsOptions)
        } else {
            throw HubWSSError.tlsRequired
        }
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port) ?? .any)
        listener.newConnectionHandler = { connection in
            self.handle(connection: connection)
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let err) = state {
                FileHandle.standardError.write(
                    Data("[colmeia-hub] WSS failed: \(err)\n".utf8))
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
    }

    public static func loadIdentity(pkcs12Path: String, password: String) -> SecIdentity? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: pkcs12Path)) else {
            return nil
        }
        let options: [String: Any] = [kSecImportExportPassphrase as String: password]
        var rawItems: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &rawItems)
        guard status == errSecSuccess, let items = rawItems as? [[String: Any]] else {
            return nil
        }
        for item in items {
            if let identity = item[kSecImportItemIdentity as String] {
                return (identity as! SecIdentity)
            }
        }
        return nil
    }
}

#else
// Stub Linux — WSS não disponível, hub usa TCP puro (apenas para testes).
public final class HubWSSListener: @unchecked Sendable {
    public let port: UInt16

    public init(port: UInt16, tlsIdentity: Any? = nil, serverHostname: String? = nil) {
        self.port = port
    }

    public func start() throws {
        throw HubWSSError.notSupportedOnPlatform
    }

    public func stop() {}

    public static func loadIdentity(pkcs12Path: String, password: String) -> Any? { nil }
}
#endif
