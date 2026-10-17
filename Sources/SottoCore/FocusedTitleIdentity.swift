import Foundation

/// An accessibility window title is exact metadata, not OCR. Do not remove characters,
/// fold spaces or case, or interpret a literal suffix as a member count.
public enum FocusedTitleIdentity {
    public static func resolve(_ title: String?, candidates: [TitleCandidate]) -> ConversationResolution {
        guard let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !["微信", "WeChat", "Weixin"].contains(title) else {
            return ConversationResolution(id: nil, state: .noMetadata)
        }
        // Swift String equality permits canonical Unicode equivalence, but preserves
        // internal spaces, NBSP, zero-width characters, emoji variants and punctuation.
        let ids = Set(candidates.filter { $0.aliases.contains(title) }.map(\.id))
        guard ids.count == 1 else {
            return ConversationResolution(id: nil, state: ids.isEmpty ? .unmatched : .ambiguous)
        }
        return ConversationResolution(id: ids.first, state: .confirmed)
    }
}
