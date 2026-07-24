import Foundation
import ColmeiaKit

// CLI companheira (§13): injetada no PATH das sessões gerenciadas, mas legítima
// também fora delas (humano:local). Exit codes em CLIExit (§13.2).

let cliUsage = """
colmeia \(ColmeiaVersion.string) — CLI companheira da Colmeia (protocolo v\(ColmeiaVersion.protocolVersion))

subcomandos:
  \(AskCommand.usage)
  \(NoteCommand.usage)
  \(StatusCommand.usage)
  colmeia portal open <url> [--nome <apelido>] [--workspace <workspace-id>]
  colmeia version | --version
  colmeia help    | --help
"""

let cliArguments = Array(CommandLine.arguments.dropFirst())
let exitCode: Int32

switch cliArguments.first {
case nil:
    printErr(cliUsage)
    exitCode = CLIExit.uso
case "help", "--help", "-h":
    print(cliUsage)
    exitCode = CLIExit.ok
case "version", "--version":
    print("colmeia \(ColmeiaVersion.string) (protocolo v\(ColmeiaVersion.protocolVersion))")
    exitCode = CLIExit.ok
case "ask":
    exitCode = await AskCommand.run(Array(cliArguments.dropFirst()))
case "note":
    exitCode = await NoteCommand.run(Array(cliArguments.dropFirst()))
case "status":
    exitCode = await StatusCommand.run(Array(cliArguments.dropFirst()))
case "portal":
    exitCode = await PortalCommand.run(Array(cliArguments.dropFirst()))
case "handoff":
    // §13.5 — nome reservado [FASE 2]; NÃO DEVE ser usado para outra coisa.
    printErr("colmeia handoff: nome reservado (§13.5), ainda não disponível nesta versão")
    exitCode = CLIExit.uso
case .some(let outro):
    printErr("subcomando desconhecido: \(outro)\n\n\(cliUsage)")
    exitCode = CLIExit.uso
}

exit(exitCode)
