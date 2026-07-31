import Foundation
import ColmeiaKit
import ColmeiaHub

let host = ProcessInfo.processInfo.environment["COLMEIA_HUB_HOST"] ?? "0.0.0.0"
let port = UInt16(ProcessInfo.processInfo.environment["COLMEIA_HUB_PORT"] ?? "9620") ?? 9620
let usarWSS = ProcessInfo.processInfo.environment["COLMEIA_HUB_WSS"] == "1"
let tlsP12Path = ProcessInfo.processInfo.environment["COLMEIA_HUB_TLS_P12"]
let tlsPassword = ProcessInfo.processInfo.environment["COLMEIA_HUB_TLS_PASSWORD"]
let tlsHostname = ProcessInfo.processInfo.environment["COLMEIA_HUB_TLS_HOSTNAME"]
let allowAnonymous = ProcessInfo.processInfo.environment["COLMEIA_HUB_ALLOW_ANONYMOUS"] == "1"
let allowInsecureFallback = ProcessInfo.processInfo.environment["COLMEIA_HUB_ALLOW_INSECURE_FALLBACK"] == "1"

let paths: ColmeiaPaths
if let root = ProcessInfo.processInfo.environment["COLMEIA_ROOT"], !root.isEmpty {
    paths = ColmeiaPaths(root: URL(fileURLWithPath: root, isDirectory: true))
} else {
    paths = ColmeiaPaths()
}
print("colmeia-hub: root=\(paths.root.path), workspacesDir=\(paths.workspacesDir.path)")
let hub = HubServer(paths: paths, host: host, port: port)
hub.engineURL = ProcessInfo.processInfo.environment["COLMEIA_ENGINE_URL"]
hub.hubToken = ProcessInfo.processInfo.environment["COLMEIA_HUB_TOKEN"]

let isLoopback = host == "127.0.0.1" || host == "localhost" || host == "::1"
if !isLoopback && hub.hubToken == nil && !allowAnonymous {
    print("[colmeia-hub] Recusando bind remoto sem COLMEIA_HUB_TOKEN (use COLMEIA_HUB_ALLOW_ANONYMOUS=1 somente em rede controlada).")
    exit(2)
}

if usarWSS {
    #if canImport(Security)
    let identity: SecIdentity? = {
        if let p12 = tlsP12Path, let pwd = tlsPassword {
            return HubWSSListener.loadIdentity(pkcs12Path: p12, password: pwd)
        }
        return nil
    }()
    guard identity != nil || allowInsecureFallback else {
        print("[colmeia-hub] WSS exige COLMEIA_HUB_TLS_P12 e COLMEIA_HUB_TLS_PASSWORD.")
        exit(2)
    }
    let listener = HubWSSListener(
        port: port, tlsIdentity: identity, serverHostname: tlsHostname)
    do {
        try listener.start()
        print("[colmeia-hub] WSS escutando em wss://\(host):\(port)")
    } catch {
        print("[colmeia-hub] WSS falhou: \(error)")
        if !allowInsecureFallback { exit(2) }
        print("[colmeia-hub] fallback TCP permitido explicitamente para desenvolvimento.")
    }
    #else
    print("[colmeia-hub] WSS não suportado nesta plataforma")
    if !allowInsecureFallback { exit(2) }
    #endif
}

print("[colmeia-hub] Iniciando na porta \(port)…")

do {
    try hub.start()
} catch {
    print("[colmeia-hub] Erro ao iniciar: \(error)")
    exit(1)
}

let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
signalSource.setEventHandler {
    print("\n[colmeia-hub] Encerrando…")
    hub.stop()
    exit(0)
}
signal(SIGINT, SIG_IGN)
signalSource.resume()

let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termSource.setEventHandler {
    print("\n[colmeia-hub] Encerrando…")
    hub.stop()
    exit(0)
}
signal(SIGTERM, SIG_IGN)
termSource.resume()

dispatchMain()
