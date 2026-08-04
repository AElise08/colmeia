// swift-tools-version: 6.0
// Colmeia — canvas colaborativo de agentes.
// Sem xcodebuild nesta máquina: apenas `swift build` / `swift test`.
import PackageDescription

// Modo v5 em todos os targets para evitar churn de strict concurrency (decisão do projeto).
let swiftSettings: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let platforms: [SupportedPlatform]? = {
    #if os(macOS)
    return [.macOS(.v15)]
    #else
    return nil
    #endif
}()

let package = Package(
    name: "Colmeia",
    platforms: platforms,
    products: [
        .library(name: "ColmeiaKit", targets: ["ColmeiaKit"]),
        .library(name: "ColmeiaEngine", targets: ["ColmeiaEngine"]),
        .library(name: "ColmeiaHub", targets: ["ColmeiaHub"]),
        .executable(name: "colmeia-engine", targets: ["colmeia-engine"]),
        .executable(name: "colmeia", targets: ["colmeia"]),
        .executable(name: "colmeia-hub", targets: ["colmeia-hub"]),
        .executable(name: "colmeia-worker", targets: ["colmeia-worker"]),
        .executable(name: "colmeia-tcp-bridge", targets: ["colmeia-tcp-bridge"]),
        .executable(name: "colmeia-sync", targets: ["colmeia-sync"]),
        .executable(name: "ColmeiaApp", targets: ["ColmeiaApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
    ],
    targets: [
        // Tudo compartilhado: domínio (§5), protocolo (§6), ops (§7.2), eventos (§8.2),
        // cliente/framing de socket (§6.1) e paths de storage (§20).
        .target(
            name: "ColmeiaKit",
            swiftSettings: swiftSettings
        ),
        // Daemon headless (§3.1). A implementação real (PTY, journal, adapters) entra aqui.
        .target(
            name: "ColmeiaEngine",
            dependencies: ["ColmeiaKit"],
            swiftSettings: swiftSettings
        ),
        // Hub de colaboração (§3.1). Servidor de rede sem PTY,
        // AppKit ou dependências Darwin — compila em macOS e Linux.
        .target(
            name: "ColmeiaHub",
            dependencies: ["ColmeiaKit"],
            swiftSettings: swiftSettings
        ),
        // Binário fino do daemon.
        .executableTarget(
            name: "colmeia-engine",
            dependencies: ["ColmeiaEngine", "ColmeiaKit"],
            swiftSettings: swiftSettings
        ),
        // CLI companheira (§13): ask / note / status.
        .executableTarget(
            name: "colmeia",
            dependencies: ["ColmeiaKit"],
            swiftSettings: swiftSettings
        ),
        // Binário do Hub colaborativo (§3.1).
        .executableTarget(
            name: "colmeia-hub",
            dependencies: ["ColmeiaHub", "ColmeiaKit"],
            swiftSettings: swiftSettings
        ),
        // Worker remoto headless no Linux/macOS (§4.1).
        .executableTarget(
            name: "colmeia-worker",
            dependencies: ["ColmeiaKit"],
            swiftSettings: swiftSettings
        ),
        // TCP→Unix bridge para tunnel do Engine (sem dependências).
        .executableTarget(
            name: "colmeia-tcp-bridge",
            swiftSettings: swiftSettings
        ),
        // Sincroniza workspaces do engine local para o Hub remoto.
        .executableTarget(
            name: "colmeia-sync",
            dependencies: ["ColmeiaKit"],
            swiftSettings: swiftSettings
        ),
        // App SwiftUI do canvas (§18); SwiftTerm é o emulador de terminal (§9.2).
        .executableTarget(
            name: "ColmeiaApp",
            dependencies: [
                "ColmeiaKit",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            swiftSettings: swiftSettings
        ),
        // Rodar testes NESTA máquina (CommandLineTools sem Xcode): use ./test.sh —
        // o overlay _Testing_Foundation vem sem módulo no CLT e `swift test` puro
        // não resolve `import Testing`. unsafeFlags aqui fariam o SwiftPM parar de
        // executar o produto de teste (build passa, run silenciosamente não acontece).
        .testTarget(
            name: "ColmeiaTests",
            dependencies: ["ColmeiaKit", "ColmeiaEngine", "ColmeiaHub"],
            swiftSettings: swiftSettings
        ),
    ]
)
