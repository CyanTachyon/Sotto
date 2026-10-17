import Foundation
import ChatCore

func checkFocusedTitleIdentity() throws {
    func chat(_ id: String, _ aliases: String...) -> TitleCandidate { .init(id: id, aliases: aliases) }
    func expect(_ title: String?, _ candidates: [TitleCandidate], id: String? = nil, state: ConversationResolution.State) throws {
        let result = FocusedTitleIdentity.resolve(title, candidates: candidates)
        guard result.id == id, result.state == state else {
            throw ChatError.invalid("Focused title exact identity check failed: expected \(state), got \(result.state)")
        }
    }
    try expect("Sotto Demo", [chat("group", "Sotto Demo")], id: "group", state: .confirmed)
    try expect("Alice", [chat("private", "Alice")], id: "private", state: .confirmed)
    try expect("Same", [chat("group", "Same"), chat("private", "Same")], state: .ambiguous)
    try expect("Alias", [chat("one", "Name", "Alias"), chat("two", "Alias")], state: .ambiguous)
    try expect("Alias", [chat("one", "Alias", "Alias"), chat("one", "Alias")], id: "one", state: .confirmed)
    try expect("Team 🙂", [chat("smile", "Team 🙂"), chat("other", "Team 🙃")], id: "smile", state: .confirmed)
    try expect("Team", [chat("emoji", "Team🙂")], state: .unmatched)
    try expect("Family 👨‍👩‍👧", [chat("joined", "Family 👨‍👩‍👧"), chat("separate", "Family 👨👩👧")], id: "joined", state: .confirmed)
    try expect("A B", [chat("space", "A B"), chat("joined", "AB"), chat("nbsp", "A\u{00A0}B")], id: "space", state: .confirmed)
    try expect("A  B", [chat("space", "A B")], state: .unmatched)
    try expect("A\u{00A0}B", [chat("space", "A B")], state: .unmatched)
    try expect("A\u{200B}B", [chat("plain", "AB")], state: .unmatched)
    try expect(" Name ", [chat("plain", "Name")], state: .unmatched)
    try expect(" Name ", [chat("spaced", " Name ")], id: "spaced", state: .confirmed)
    try expect("name", [chat("capital", "Name")], state: .unmatched)
    try expect("Group (42)", [chat("base", "Group")], state: .unmatched)
    try expect("Group (42)", [chat("base", "Group"), chat("literal", "Group (42)")], id: "literal", state: .confirmed)
    try expect("WeChat — Group", [chat("base", "Group")], state: .unmatched)
    try expect("Cafe\u{301}", [chat("accent", "Café")], id: "accent", state: .confirmed)
    try expect("Name...", [chat("literal", "Name...")], id: "literal", state: .confirmed)
    try expect("Unknown", [chat("known", "Known")], state: .unmatched)
    for title: String? in [nil, "", "  \n", "微信", "WeChat", "Weixin"] {
        try expect(title, [chat("generic", title ?? "")], state: .noMetadata)
    }
}
