import Foundation
import ColmeiaKit

/// Representação markdown mínima e deliberadamente restrita da checklist. O ID fica
/// em comentário HTML para que o arquivo continue legível fora do Colmeia.
enum NoteChecklist {
    private static let markerPrefix = "<!-- colmeia:item:"
    private static let markerSuffix = " -->"

    static func normalize(_ content: String) -> String {
        let hadFinalNewline = content.hasSuffix("\n")
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let normalized = lines.map { line -> String in
            guard checkbox(in: line) != nil, markerID(in: line) == nil else { return line }
            return line + " \(markerPrefix)\(ULID.generate().string)\(markerSuffix)"
        }
        var result = normalized.joined(separator: "\n")
        if hadFinalNewline, !result.hasSuffix("\n") { result += "\n" }
        return result
    }

    static func items(in content: String) -> [NoteChecklistItem] {
        content.split(separator: "\n", omittingEmptySubsequences: false).compactMap { raw in
            let line = String(raw)
            guard let id = markerID(in: line), let check = checkbox(in: line),
                  let marker = line.range(of: markerPrefix)
            else { return nil }
            let beforeMarker = String(line[..<marker.lowerBound])
            let text = beforeMarker
                .replacingOccurrences(of: "- [ ]", with: "")
                .replacingOccurrences(of: "- [x]", with: "")
                .replacingOccurrences(of: "- [X]", with: "")
                .trimmingCharacters(in: .whitespaces)
            return NoteChecklistItem(id: id, texto: text, marcada: check.marked)
        }
    }

    static func appending(_ text: String, to content: String, id: ULID) -> String {
        let separator = content.isEmpty || content.hasSuffix("\n") ? "" : "\n"
        return content + separator + "- [ ] \(text) \(markerPrefix)\(id.string)\(markerSuffix)\n"
    }

    static func setting(_ id: ULID, marked: Bool, in content: String) -> (content: String, changed: Bool)? {
        let hadFinalNewline = content.hasSuffix("\n")
        var lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for index in lines.indices where markerID(in: lines[index]) == id {
            guard let check = checkbox(in: lines[index]) else { return nil }
            guard check.marked != marked else { return (content, false) }
            lines[index].replaceSubrange(check.range, with: marked ? "[x]" : "[ ]")
            var updated = lines.joined(separator: "\n")
            if hadFinalNewline, !updated.hasSuffix("\n") { updated += "\n" }
            return (updated, true)
        }
        return nil
    }

    private static func markerID(in line: String) -> ULID? {
        guard let start = line.range(of: markerPrefix),
              let end = line.range(of: markerSuffix, range: start.upperBound..<line.endIndex)
        else { return nil }
        return ULID(String(line[start.upperBound..<end.lowerBound]))
    }

    private static func checkbox(in line: String) -> (range: Range<String.Index>, marked: Bool)? {
        if let range = line.range(of: "[ ]") {
            return (range, false)
        }
        if let range = line.range(of: "[x]") ?? line.range(of: "[X]") {
            return (range, true)
        }
        return nil
    }
}
