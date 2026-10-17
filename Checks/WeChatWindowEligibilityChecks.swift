import Foundation
import ChatCore

func checkWeChatWindowEligibility() throws {
    let standard = WeChatWindowMetadata(role: "AXWindow", subrole: "AXStandardWindow", isModal: false, hasDocument: false)
    let known = [TitleCandidate(id: "group", aliases: ["Sotto Demo", "讨论 👩‍💻  A"]),
                 TitleCandidate(id: "private", aliases: ["Alice"])]
    func expect(_ title: String?, metadata: WeChatWindowMetadata? = standard,
                candidates: [TitleCandidate] = known, _ expected: WeChatWindowEligibility.Kind) throws {
        guard WeChatWindowEligibility.classify(title: title, metadata: metadata, candidates: candidates) == expected else {
            throw ChatError.invalid("Window eligibility synthetic check failed")
        }
    }
    for title in ["微信", "WeChat", "Weixin"] { try expect(title, candidates: [], .mainChat) }
    try expect("Sotto Demo", .knownConversation)
    try expect("Alice", .knownConversation)
    try expect("讨论 👩‍💻  A", .knownConversation)
    try expect("讨论 👩‍💻 A", .unsupported)
    try expect("sotto demo", .unsupported)
    try expect("Sotto Demo — 微信", .unsupported)
    try expect("Unknown", .unsupported)
    try expect("Sotto Demo", candidates: [], .unsupported)
    for title: String? in [nil, "", " ", " 微信 "] { try expect(title, .unsupported) }
    try expect("微信", metadata: nil, .unsupported)
    for metadata in [
        WeChatWindowMetadata(role: nil, subrole: "AXStandardWindow", isModal: false, hasDocument: false),
        WeChatWindowMetadata(role: "AXWindow", subrole: nil, isModal: false, hasDocument: false),
        WeChatWindowMetadata(role: "AXWindow", subrole: "AXDialog", isModal: false, hasDocument: false),
        WeChatWindowMetadata(role: "AXSheet", subrole: "AXStandardWindow", isModal: false, hasDocument: false),
        WeChatWindowMetadata(role: "AXWindow", subrole: "AXStandardWindow", isModal: true, hasDocument: false),
        WeChatWindowMetadata(role: "AXWindow", subrole: "AXStandardWindow", isModal: nil, hasDocument: false),
        WeChatWindowMetadata(role: "AXWindow", subrole: "AXStandardWindow", isModal: false, hasDocument: true),
        WeChatWindowMetadata(role: "AXWindow", subrole: "AXStandardWindow", isModal: false, hasDocument: nil)
    ] {
        try expect("微信", metadata: metadata, .unsupported)
        try expect("Sotto Demo", metadata: metadata, .unsupported)
    }
    // Even a known chat with a reserved preview title must not turn that system
    // surface into a chat target. All other unfamiliar preview titles fail closed.
    for title in ["图片和视频", "图片与视频", "图片", "视频", "文件预览", "预览", "照片",
                  "Image", "Images", "Photo", "Photos", "Video", "Videos", "Image and Video",
                  "Images and Videos", "Image Viewer", "File Preview", "Preview"] {
        try expect(title, candidates: [.init(id: "same-name-chat", aliases: [title])], .unsupported)
    }
    let duplicates = [TitleCandidate(id: "one", aliases: ["Same"]), TitleCandidate(id: "two", aliases: ["Same"])]
    try expect("Same", candidates: duplicates, .knownConversation)
    let identity = FocusedTitleIdentity.resolve("Same", candidates: duplicates)
    guard identity.id == nil && identity.state == .ambiguous else {
        throw ChatError.invalid("Chat eligibility must not grant ambiguous conversation identity")
    }
}
