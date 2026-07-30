import AppKit
import SwiftTerm

/// Aparência de terminal de verdade (§9.2 + §18.3): SF Mono 13 (fallback Menlo),
/// tema escuro consistente (fundo/texto/cursor/seleção + paleta ANSI 16), cursor
/// piscando (blinkBlock é o default do SwiftTerm) e texto nítido sem smoothing.
///
/// Fronteira importante: aqui vive SÓ estética. Geometria (cols/rows) NUNCA é
/// derivada de métricas de fonte por fora — a verdade é sempre o próprio SwiftTerm.
enum TerminalAppearance {
    static let tamanhoFonte: CGFloat = 13
    static let tamanhoFonteMin: CGFloat = 10
    static let tamanhoFonteMax: CGFloat = 24

    static func tamanhoNormalizado(_ size: Double?) -> CGFloat {
        min(tamanhoFonteMax, max(tamanhoFonteMin, CGFloat(size ?? Double(tamanhoFonte))))
    }

    /// SF Mono de verdade; Menlo como fallback; o mono do sistema como última linha.
    static var fonte: NSFont {
        fonte(size: tamanhoFonte)
    }

    static func fonte(size: CGFloat) -> NSFont {
        NSFont(name: "SFMono-Regular", size: size)
            ?? NSFont(name: "Menlo", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    // Tema escuro no espírito Terminal.app/Ghostty: fundo quase-preto azulado,
    // texto claro com contraste confortável. Reverse video (barra de digitação
    // do Claude Code) vira texto-sobre-claro legível, não barra cinza ilegível.
    static let fundo = nsCor(0x14161B)
    static let texto = nsCor(0xDCDFE4)
    static let cursor = nsCor(0xAEB8C4)
    static let selecao = nsCor(0x33518A)

    /// Paleta ANSI 16 (One Half Dark ajustada para fundo quase-preto).
    static let paletaANSI: [SwiftTerm.Color] = [
        cor(0x1B1E24), // 0 preto
        cor(0xE06C75), // 1 vermelho
        cor(0x98C379), // 2 verde
        cor(0xE5C07B), // 3 amarelo
        cor(0x61AFEF), // 4 azul
        cor(0xC678DD), // 5 magenta
        cor(0x56B6C2), // 6 ciano
        cor(0xC8CCD4), // 7 branco (cinza claro)
        cor(0x5A6374), // 8 preto brilhante (cinza)
        cor(0xEF7580), // 9 vermelho brilhante
        cor(0xA6D189), // 10 verde brilhante
        cor(0xF0CA85), // 11 amarelo brilhante
        cor(0x74BEFF), // 12 azul brilhante
        cor(0xD28AE8), // 13 magenta brilhante
        cor(0x66C7D4), // 14 ciano brilhante
        cor(0xFFFFFF), // 15 branco brilhante
    ]

    /// Aplica o tema completo. A fonte DEVE entrar pelo init da view (mudar fonte
    /// depois dispara resetFont, que recalcula cols sem descontar o scroller —
    /// caminho de geometria pior que o do layout normal).
    static func aplicar(em view: TerminalView) {
        view.nativeBackgroundColor = fundo
        view.nativeForegroundColor = texto
        view.installColors(paletaANSI)
        view.caretColor = cursor
        view.caretTextColor = fundo
        view.selectedTextBackgroundColor = selecao
        // Sem font smoothing (default do Terminal.app moderno): glifos finos e
        // nítidos em retina, sem o "borrão engordado" do smoothing legado.
        view.fontSmoothing = false
    }

    private static func cor(_ rgb: Int) -> SwiftTerm.Color {
        SwiftTerm.Color(
            red: UInt16(((rgb >> 16) & 0xFF) * 257),
            green: UInt16(((rgb >> 8) & 0xFF) * 257),
            blue: UInt16((rgb & 0xFF) * 257)
        )
    }

    private static func nsCor(_ rgb: Int) -> NSColor {
        NSColor(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255.0,
            green: CGFloat((rgb >> 8) & 0xFF) / 255.0,
            blue: CGFloat(rgb & 0xFF) / 255.0,
            alpha: 1
        )
    }
}
