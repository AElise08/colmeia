// swift-tools-version: 6.0
// Colmeia — canvas de agentes (spec: ~/colmeia-spec.md).
// Sem xcodebuild nesta máquina: apenas `swift build` / `swift test`.
import PackageDescription

// Modo v5 em todos os targets para evitar churn de strict concurrency (decisão do projeto).
let swiftSettings: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "Colmeia",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ColmeiaKit", targets: ["ColmeiaKit"]),
        .library(name: "ColmeiaEngine", targets: ["ColmeiaEngine"]),
        .executable(name: "colmeia-engine", targets: ["colmeia-engine"]),
        .executable(name: "colmeia", targets: ["colmeia"]),
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
            dependencies: ["ColmeiaKit", "ColmeiaEngine"],
            swiftSettings: swiftSettings
        ),
    ]
)
