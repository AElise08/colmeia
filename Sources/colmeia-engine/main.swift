import Foundation
import Darwin
import ColmeiaEngine
import ColmeiaKit

// colmeia-engine [--root <dir>] — daemon local (§3.1).
// COLMEIA_ROOT também é aceito (útil em testes/integração).

var rootOverride: String? = ProcessInfo.processInfo.environment["COLMEIA_ROOT"]
var argIterator = CommandLine.arguments.dropFirst().makeIterator()
while let arg = argIterator.next() {
    switch arg {
    case "--root":
        rootOverride = argIterator.next()
    case "--version":
        print(ColmeiaEngineInfo.banner())
        exit(0)
    case "--help", "-h":
        print("uso: colmeia-engine [--root <dir>] [--version]")
        exit(0)
    default:
        FileHandle.standardError.write(Data("argumento desconhecido: \(arg)\n".utf8))
        exit(2)
    }
}

let paths = rootOverride.map { ColmeiaPaths(root: URL(fileURLWithPath: $0, isDirectory: true)) } ?? ColmeiaPaths()
let engine = Engine(paths: paths)

// EPIPE vira erro de write, não sinal fatal.
signal(SIGPIPE, SIG_IGN)

do {
    try engine.start()
} catch is EngineStartError {
    // §20.5 — instância já rodando: quem chamou deve conectar ao socket existente.
    print("colmeia-engine já está rodando (socket: \(paths.engineSocket.path))")
    exit(0)
} catch {
    FileHandle.standardError.write(Data("falha ao iniciar engine: \(error)\n".utf8))
    exit(1)
}

print(ColmeiaEngineInfo.banner())
print("socket: \(paths.engineSocket.path)")

// SIGTERM/SIGINT → shutdown gracioso (flush + TERM→KILL nas sessões).
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termSource.setEventHandler { engine.requestShutdown(exitProcess: true) }
termSource.resume()
let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
intSource.setEventHandler { engine.requestShutdown(exitProcess: true) }
intSource.resume()

dispatchMain()
