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

#if canImport(Security)
var wssIdentity: SecIdentity?
if usarWSS, let p12 = tlsP12Path, let password = tlsPassword {
    wssIdentity = HubWSSListener.loadIdentity(pkcs12Path: p12, password: password)
}
#else
var wssIdentity: Any?
#endif
var wssEnabled = usarWSS && wssIdentity != nil
if usarWSS && !wssEnabled && !allowInsecureFallback {
    print("[colmeia-hub] WSS exige COLMEIA_HUB_TLS_P12 e COLMEIA_HUB_TLS_PASSWORD.")
    exit(2)
}
if usarWSS && !wssEnabled {
    print("[colmeia-hub] fallback TCP permitido explicitamente para desenvolvimento.")
}

// Quando WSS está ativo, o HubServer fica somente em loopback numa porta
// interna; o listener TLS termina a conexão pública e faz proxy de bytes.
let backendPort = wssEnabled ? (port == UInt16.max ? port : port &+ 1) : port
let backendHost = wssEnabled ? "127.0.0.1" : host

let paths: ColmeiaPaths
if let root = ProcessInfo.processInfo.environment["COLMEIA_ROOT"], !root.isEmpty {
    paths = ColmeiaPaths(root: URL(fileURLWithPath: root, isDirectory: true))
} else {
    paths = ColmeiaPaths()
}
print("colmeia-hub: root=\(paths.root.path), workspacesDir=\(paths.workspacesDir.path)")
let hub = HubServer(paths: paths, host: backendHost, port: backendPort)
hub.engineURL = ProcessInfo.processInfo.environment["COLMEIA_ENGINE_URL"]
hub.hubToken = ProcessInfo.processInfo.environment["COLMEIA_HUB_TOKEN"]

let isLoopback = host == "127.0.0.1" || host == "localhost" || host == "::1"
if !isLoopback && hub.hubToken == nil && !allowAnonymous {
    print("[colmeia-hub] Recusando bind remoto sem COLMEIA_HUB_TOKEN (use COLMEIA_HUB_ALLOW_ANONYMOUS=1 somente em rede controlada).")
    exit(2)
}

var wssListener: HubWSSListener?
if wssEnabled {
    #if canImport(Security)
    let listener = HubWSSListener(
        port: port, tlsIdentity: wssIdentity, serverHostname: tlsHostname,
        backendHost: backendHost, backendPort: backendPort)
    do {
        try listener.start()
        wssListener = listener
        print("[colmeia-hub] WSS escutando em wss://\(host):\(port) → TCP interno \(backendPort)")
    } catch {
        print("[colmeia-hub] WSS falhou: \(error)")
        // O Hub já foi configurado para a porta interna (port+1). Continuar
        // aqui com fallback silencioso deixaria o processo ouvindo numa porta
        // diferente da anunciada; falhe explicitamente para não criar um
        // estado de conectividade enganoso.
        if allowInsecureFallback {
            print("[colmeia-hub] fallback solicitado, mas não é seguro reutilizar a porta interna; reinicie sem COLMEIA_HUB_WSS=1.")
        }
        exit(2)
    }
    #else
    print("[colmeia-hub] WSS não suportado nesta plataforma")
    if allowInsecureFallback {
        print("[colmeia-hub] fallback solicitado, mas WSS não possui listener nesta plataforma; reinicie sem COLMEIA_HUB_WSS=1.")
    }
    exit(2)
    #endif
}

print("[colmeia-hub] Iniciando na porta \(backendPort)…")

do {
    try hub.start()
} catch {
    print("[colmeia-hub] Erro ao iniciar: \(error)")
    exit(1)
}

let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
signalSource.setEventHandler {
    print("\n[colmeia-hub] Encerrando…")
    wssListener?.stop()
    hub.stop()
    exit(0)
}
signal(SIGINT, SIG_IGN)
signalSource.resume()

let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termSource.setEventHandler {
    print("\n[colmeia-hub] Encerrando…")
    wssListener?.stop()
    hub.stop()
    exit(0)
}
signal(SIGTERM, SIG_IGN)
termSource.resume()

dispatchMain()
