import Foundation

public enum WorkerSandboxError: Error, Equatable, Sendable, LocalizedError {
    case notIsolated(URL)
    case invalidRelativePath(String)

    public var errorDescription: String? {
        switch self {
        case .notIsolated(let url): return "sandbox do worker não está isolado: \(url.path)"
        case .invalidRelativePath(let path): return "caminho relativo inválido: \(path)"
        }
    }
}

/// Diretório efêmero de execução do worker. O root pode ser injetado nos testes;
/// em produção o padrão é o diretório temporário do sistema com modo 0700.
public struct WorkerSandbox: Sendable {
    public let directory: URL

    public init(workerID: ULID, temporaryRoot: URL = FileManager.default.temporaryDirectory) throws {
        let name = "colmeia-worker-\(workerID.string)"
        let root = temporaryRoot.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
        guard (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700 else {
            throw WorkerSandboxError.notIsolated(root)
        }
        self.directory = root
    }

    public func url(forRelativePath path: String) throws -> URL {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.split(separator: "/").contains("..")
        else { throw WorkerSandboxError.invalidRelativePath(path) }
        return directory.appendingPathComponent(path)
    }

    public func merkleTree() throws -> MerkleTree {
        try MerkleTree.fromFiles(at: directory)
    }

    public func remove() throws {
        try FileManager.default.removeItem(at: directory)
    }
}

/// Política mínima para execução remota: o grant precisa ser do próprio
/// worker, estar ativo, conter `execute` e declarar o comando exato. Não há
/// wildcard implícito; assim, obter acesso de leitura ou a uma sessão não
/// transforma o worker em um shell arbitrário.
public enum WorkerCapabilityPolicy {
    public static func allowsExecute(
        command: String,
        subjectID: String,
        grants: [CapabilityGrant]
    ) -> Bool {
        let resource = "command:\(command)"
        return grants.contains { grant in
            grant.subjectID == subjectID
                && grant.isActive
                && grant.actions.contains(.execute)
                && grant.resource == resource
        }
    }
}
