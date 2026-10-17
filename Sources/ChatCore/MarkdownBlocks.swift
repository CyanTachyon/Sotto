import Foundation

public enum MarkdownBlock: Equatable {
    case paragraph(String), heading(Int, String), code(String, String), quote(String), rule
    case item(String, String, Int)
    case table([String], [[String]])
}

/// Keeps incomplete streaming fences readable; never evaluates HTML or loads remote images.
public enum MarkdownBlocks {
    public static func parse(_ text: String) -> [MarkdownBlock] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var result: [MarkdownBlock] = [], paragraph: [String] = [], i = 0
        func flush() { if !paragraph.isEmpty { result.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] } }
        while i < lines.count {
            let raw = lines[i], line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); i += 1; continue }
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                flush(); let marker = String(line.prefix(1)); let count = line.prefix(while: { String($0) == marker }).count
                let language = String(line.dropFirst(count)).trimmingCharacters(in: .whitespaces)
                var body: [String] = []; i += 1
                while i < lines.count {
                    let candidate = lines[i].trimmingCharacters(in: .whitespaces)
                    if candidate.hasPrefix(String(repeating: marker, count: count)), candidate.allSatisfy({ String($0) == marker }) { i += 1; break }
                    body.append(lines[i]); i += 1
                }
                result.append(.code(language, body.joined(separator: "\n"))); continue
            }
            if i + 1 < lines.count, line.contains("|"), isTableSeparator(lines[i + 1]) {
                flush(); let headers = cells(line); i += 2; var rows: [[String]] = []
                while i < lines.count, lines[i].contains("|"), !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    let row = cells(lines[i]); rows.append(Array((row + Array(repeating: "", count: headers.count)).prefix(headers.count))); i += 1
                }
                result.append(.table(headers, rows)); continue
            }
            if line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) != nil {
                flush(); let n = line.prefix(while: { $0 == "#" }).count
                result.append(.heading(n, String(line.dropFirst(n)).trimmingCharacters(in: .whitespaces))); i += 1; continue
            }
            if i + 1 < lines.count, ["=", "-"].contains(String(lines[i+1].trimmingCharacters(in: .whitespaces).prefix(1))) {
                let next = lines[i+1].trimmingCharacters(in: .whitespaces)
                if next.count >= 3, Set(next).count == 1 {
                    flush(); result.append(.heading(next.first == "=" ? 1 : 2, line)); i += 2; continue
                }
            }
            let compact = line.replacingOccurrences(of: " ", with: "")
            if compact.count >= 3, Set(compact).count == 1, "-*_".contains(compact.first!) {
                flush(); result.append(.rule); i += 1; continue
            }
            if line.hasPrefix(">") {
                flush(); var quote: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quote.append(String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces)); i += 1
                }
                result.append(.quote(quote.joined(separator: "\n"))); continue
            }
            if let match = line.range(of: #"^(?:[-+*]|\d+[.)])\s+"#, options: .regularExpression) {
                flush(); let marker = String(line[match]).trimmingCharacters(in: .whitespaces)
                var body = String(line[match.upperBound...]); let indent = raw.prefix(while: { $0 == " " || $0 == "\t" }).count
                var label = "-+*".contains(marker) ? "•" : marker
                if body.hasPrefix("[ ] ") { label = "☐"; body = String(body.dropFirst(4)) }
                if body.hasPrefix("[x] ") || body.hasPrefix("[X] ") { label = "☑"; body = String(body.dropFirst(4)) }
                result.append(.item(label, body, min(indent / 2, 6))); i += 1; continue
            }
            paragraph.append(raw); i += 1
        }
        flush(); return result
    }
    private static func isTableSeparator(_ line: String) -> Bool {
        let values = cells(line)
        return !values.isEmpty && values.allSatisfy { $0.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil }
    }
    public static func cells(_ line: String) -> [String] {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }; if text.hasSuffix("|") && !text.hasSuffix("\\|") { text.removeLast() }
        var result: [String] = [], value = "", escaped = false, code = false
        for char in text {
            if escaped { value.append(char); escaped = false; continue }
            if char == "\\" { escaped = true; continue }
            if char == "`" { code.toggle() }
            if char == "|", !code { result.append(value.trimmingCharacters(in: .whitespaces)); value = "" }
            else { value.append(char) }
        }
        if escaped { value.append("\\") }; result.append(value.trimmingCharacters(in: .whitespaces)); return result
    }
}
