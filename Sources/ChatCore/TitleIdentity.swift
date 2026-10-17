import Foundation

public struct TitleCandidate {
    public let id: String
    public let aliases: [String]
    public init(id: String, aliases: [String]) { self.id = id; self.aliases = aliases }
}
public struct ConversationEvidence {
    public enum Kind: String { case windowTitle, header, selectedRow }
    public let text: String
    public let kind: Kind
    public init(_ text: String, kind: Kind) { self.text = text; self.kind = kind }
}
public struct ConversationResolution {
    public enum State: String { case confirmed, noMetadata, unmatched, ambiguous, conflicting, incomplete }
    public let id: String?
    public let state: State
}
public enum TitleIdentity {
    private static func cleaned(_ title: String) -> String {
        title.precomposedStringWithCanonicalMapping.replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public static func normalized(_ title: String) -> String {
        var value = cleaned(title)
        for prefix in ["微信 — ", "微信 - ", "WeChat — ", "WeChat - ", "Weixin - "] where value.hasPrefix(prefix) { value = String(value.dropFirst(prefix.count)) }
        for suffix in [" — 微信", " - 微信", " — WeChat", " - WeChat", " - Weixin"] where value.hasSuffix(suffix) { value = String(value.dropLast(suffix.count)) }
        return value.replacingOccurrences(of: #"\s*[（(]\s*\d+\s*(?:人|位成员|members)?\s*[)）]\s*$"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func matches(_ raw: String, candidates: [TitleCandidate]) -> Set<String> {
        let literal = cleaned(raw)
        guard !literal.isEmpty, !["微信", "WeChat", "Weixin"].contains(literal) else { return [] }
        // A literal group name containing parentheses takes precedence over member-count normalization.
        let exact = Set(candidates.filter { $0.aliases.contains { cleaned($0) == literal } }.map(\.id))
        if !exact.isEmpty { return exact }
        let value = normalized(literal)
        guard !value.isEmpty, !["微信", "WeChat", "Weixin"].contains(value) else { return [] }
        return Set(candidates.filter { $0.aliases.contains { normalized($0) == value } }.map(\.id))
    }
    public static func resolve(_ title: String, candidates: [TitleCandidate]) -> String? {
        let ids = matches(title, candidates: candidates); return ids.count == 1 ? ids.first : nil
    }
    public static func resolve(_ evidence: [ConversationEvidence], candidates: [TitleCandidate], complete: Bool = true) -> ConversationResolution {
        guard complete else { return ConversationResolution(id: nil, state: .incomplete) }
        let usable = evidence.filter { !cleaned($0.text).isEmpty && !["微信", "WeChat", "Weixin"].contains(normalized($0.text)) }
        guard !usable.isEmpty else { return ConversationResolution(id: nil, state: .noMetadata) }
        // An unmatched selected conversation must invalidate a previously matching window/header.
        let selected = usable.filter { $0.kind == .selectedRow }
        if selected.contains(where: { matches($0.text, candidates: candidates).isEmpty }) { return ConversationResolution(id: nil, state: .unmatched) }
        let windowTitles = usable.filter { $0.kind == .windowTitle }
        if windowTitles.contains(where: { matches($0.text, candidates: candidates).isEmpty }) { return ConversationResolution(id: nil, state: .unmatched) }
        var found = Set<String>(); var ambiguous = false
        for item in usable {
            let ids = matches(item.text, candidates: candidates)
            if ids.count > 1 { ambiguous = true }; found.formUnion(ids)
        }
        if ambiguous { return ConversationResolution(id: nil, state: .ambiguous) }
        if found.count > 1 { return ConversationResolution(id: nil, state: .conflicting) }
        if let id = found.first { return ConversationResolution(id: id, state: .confirmed) }
        return ConversationResolution(id: nil, state: .unmatched)
    }
}
