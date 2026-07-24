import Foundation
import Testing
import ColmeiaKit

// MARK: - Replay com geometria e emenda por seq (§8.2, §8.4)

private func event(_ seq: UInt64, output texto: String) -> Event {
    Event(
        seq: seq, ts: Date(), author: .agente("n1"),
        payload: .output(OutputEventPayload(dataB64: Data(texto.utf8).base64EncodedString())))
}

private func event(_ seq: UInt64, resize cols: Int, _ rows: Int) -> Event {
    Event(seq: seq, ts: Date(), author: .sistema, payload: .resize(ResizeEventPayload(cols: cols, rows: rows)))
}

private func event(_ seq: UInt64, state para: SessionEstado) -> Event {
    Event(
        seq: seq, ts: Date(), author: .sistema,
        payload: .state(StateEventPayload(de: .iniciando, para: para, motivo: nil)))
}

@Suite("Replay de terminal — geometria e emenda (§8.2/§8.4)")
struct TerminalReplayTests {
    /// Journal sintético com outputs + resizes intercalados: o plano batelado DEVE
    /// preservar a ordem resize/output (geometria reproduzida) e ser canonicamente
    /// IGUAL ao processamento evento-a-evento — mesma tela em emulador determinístico.
    @Test func replayReproduzGeometriaNaOrdemDoJournal() {
        let journal: [Event] = [
            event(1, resize: 120, 32), // geometria inicial gravada (§9.1)
            event(2, output: "banner-120-colunas "),
            event(3, output: "linha-a\n"),
            event(4, resize: 80, 24), // UI attachou e redimensionou
            event(5, output: "\u{1B}[2J\u{1B}[Hbanner-80-colunas "),
            event(6, state: .rodando), // eventos não-output não alimentam o emulador
            event(7, output: "linha-b\n"),
            event(8, resize: 100, 30),
            event(9, output: "final"),
        ]

        var seqBatch: UInt64 = 0
        let batch = TerminalReplay.plan(events: journal, lastSeq: &seqBatch)
        #expect(seqBatch == 9)
        #expect(batch == [
            .resize(cols: 120, rows: 32),
            .feed(Data("banner-120-colunas linha-a\n".utf8)),
            .resize(cols: 80, rows: 24),
            .feed(Data("\u{1B}[2J\u{1B}[Hbanner-80-colunas linha-b\n".utf8)),
            .resize(cols: 100, rows: 30),
            .feed(Data("final".utf8)),
        ])

        // evento-a-evento (o que o stream vivo faria) reconstrói a MESMA sequência canônica
        var seqVivo: UInt64 = 0
        var eventoAEvento: [TerminalReplay.Acao] = []
        for único in journal {
            eventoAEvento += TerminalReplay.plan(events: [único], lastSeq: &seqVivo)
        }
        #expect(TerminalReplay.canonical(batch) == TerminalReplay.canonical(eventoAEvento))
    }

    /// Re-attach com `desde_seq` sobreposto (reconexão): nada duplica, nada fura.
    @Test func emendaReplayVivoSemBuracoNemDuplicata() {
        let replay: [Event] = (1...5).map { event(UInt64($0), output: "r\($0) ") }
        var lastSeq: UInt64 = 0
        let inicial = TerminalReplay.plan(events: replay, lastSeq: &lastSeq)
        #expect(inicial == [.feed(Data("r1 r2 r3 r4 r5 ".utf8))])
        #expect(lastSeq == 5)

        // stream vivo chega com sobreposição (seqs 4–8): só 6–8 alimentam
        let vivo: [Event] = (4...8).map { event(UInt64($0), output: "v\($0) ") }
        let emenda = TerminalReplay.plan(events: vivo, lastSeq: &lastSeq)
        #expect(emenda == [.feed(Data("v6 v7 v8 ".utf8))])
        #expect(lastSeq == 8)

        // replay repetido inteiro (attach duplicado) é no-op
        #expect(TerminalReplay.plan(events: replay + vivo, lastSeq: &lastSeq).isEmpty)
    }

    /// Eventos não-output/resize avançam o `lastSeq` (piso da emenda) sem alimentar o emulador.
    @Test func eventosNaoOutputAvancamSeqSemFeed() {
        let journal: [Event] = [
            event(1, state: .rodando),
            Event(
                seq: 2, ts: Date(), author: .humanoLocal,
                payload: .input(InputEventPayload(dataB64: Data("ls\r".utf8).base64EncodedString()))),
            event(3, output: "saida"),
        ]
        var lastSeq: UInt64 = 0
        let plano = TerminalReplay.plan(events: journal, lastSeq: &lastSeq)
        #expect(plano == [.feed(Data("saida".utf8))])
        #expect(lastSeq == 3)
        // um vivo atrasado com seq 2 (já coberto) não pode regredir nem duplicar
        let atrasado = TerminalReplay.plan(events: [event(2, output: "fantasma")], lastSeq: &lastSeq)
        #expect(atrasado.isEmpty)
        #expect(lastSeq == 3)
    }
}
