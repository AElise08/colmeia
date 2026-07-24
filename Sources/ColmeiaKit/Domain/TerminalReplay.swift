import Foundation

/// Reconstrução de tela a partir do journal (§8.2–§8.4).
///
/// O replay DEVE reproduzir a geometria: eventos `resize` são aplicados ao emulador
/// na MESMA ordem do journal — TUIs sensíveis a geometria (Claude Code redesenha o
/// status com cursor posicionado) viram salada se o output for alimentado com a
/// geometria errada. O output ENTRE dois resizes pode ser concatenado num único
/// `feed` (journals grandes não podem virar milhares de passadas no launch, §21.1):
/// para um emulador determinístico, isso reconstrói exatamente a mesma tela que o
/// processamento evento-a-evento.
///
/// `plan` também é o ponto único da emenda replay↔vivo (§8.4): `lastSeq` avança por
/// TODO evento consumido e qualquer evento com `seq <= lastSeq` é descartado — sem
/// buraco nem duplicata mesmo com re-attach ou replay repetido.
public enum TerminalReplay {
    public enum Acao: Equatable, Sendable {
        case resize(cols: Int, rows: Int)
        case feed(Data)
    }

    /// Converte eventos (replay ou vivo tardio) em ações para o emulador, deduplicando
    /// por `seq` e preservando a ordem relativa resize/output.
    public static func plan(events: [Event], lastSeq: inout UInt64) -> [Acao] {
        var acoes: [Acao] = []
        var pendente = Data()
        func flush() {
            guard !pendente.isEmpty else { return }
            acoes.append(.feed(pendente))
            pendente = Data()
        }
        for event in events {
            guard event.seq > lastSeq else { continue }
            lastSeq = event.seq
            switch event.payload {
            case .output(let payload):
                if let data = Data(base64Encoded: payload.dataB64) {
                    pendente.append(data)
                }
            case .resize(let payload):
                flush()
                acoes.append(.resize(cols: payload.cols, rows: payload.rows))
            default:
                break // state/input/message/… não alimentam o emulador
            }
        }
        flush()
        return acoes
    }

    /// Forma canônica para comparar reconstruções: feeds adjacentes fundidos e feeds
    /// vazios removidos. Duas sequências de ações com a mesma forma canônica produzem
    /// a MESMA tela em qualquer emulador determinístico.
    public static func canonical(_ acoes: [Acao]) -> [Acao] {
        var out: [Acao] = []
        for acao in acoes {
            switch acao {
            case .feed(let data):
                guard !data.isEmpty else { continue }
                if case .feed(let anterior)? = out.last {
                    out[out.count - 1] = .feed(anterior + data)
                } else {
                    out.append(acao)
                }
            case .resize:
                out.append(acao)
            }
        }
        return out
    }
}
