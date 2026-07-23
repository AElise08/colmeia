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
case "portal", "handoff":
    // §13.5 — nomes reservados ([v1.5]/[FASE 2]); NÃO DEVEM ser usados para outra coisa.
    printErr("colmeia \(cliArguments[0]): nome reservado (§13.5), ainda não disponível nesta versão")
    exitCode = CLIExit.uso
case .some(let outro):
    printErr("subcomando desconhecido: \(outro)\n\n\(cliUsage)")
    exitCode = CLIExit.uso
}

exit(exitCode)
