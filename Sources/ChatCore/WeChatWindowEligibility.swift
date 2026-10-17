import Foundation

/// Window metadata only. An unsupported/missing document attribute means absent;
/// a failed read has unknown presence and must not establish chat eligibility.
public struct WeChatWindowMetadata: Equatable {
    public let role: String?
    public let subrole: String?
    public let isModal: Bool?
    public let hasDocument: Bool?
    public init(role: String?, subrole: String?, isModal: Bool?, hasDocument: Bool?) {
        self.role = role; self.subrole = subrole
        self.isModal = isModal; self.hasDocument = hasDocument
    }
}

/// Eligibility to show the companion is separate from unique conversation identity.
/// Exact known duplicate titles may open the picker, but cannot authorize auto-follow.
public enum WeChatWindowEligibility {
    public enum Kind: Equatable { case mainChat, knownConversation, unsupported }
    private static let applicationTitles: Set<String> = ["微信", "WeChat", "Weixin"]
    private static let previewTitles: Set<String> = [
        "图片和视频", "图片与视频", "图片", "视频", "文件预览", "预览", "照片",
        "Image", "Images", "Photo", "Photos", "Video", "Videos", "Image and Video",
        "Images and Videos", "Image Viewer", "File Preview", "Preview"
    ]

    public static func classify(title: String?, metadata: WeChatWindowMetadata?,
                                candidates: [TitleCandidate]) -> Kind {
        guard let title, !title.isEmpty, !previewTitles.contains(title),
              let metadata, metadata.role == "AXWindow", metadata.subrole == "AXStandardWindow",
              metadata.isModal == false, metadata.hasDocument == false else { return .unsupported }
        // Observed main chat title. Works before database connection so settings
        // remain reachable. AXMainWindow is deliberately not identity evidence.
        if applicationTitles.contains(title) { return .mainChat }
        // Preserve literal emoji, whitespace, punctuation and case just as the
        // focused-title identity resolver does. No substring/size-based guessing.
        return candidates.contains { $0.aliases.contains(title) } ? .knownConversation : .unsupported
    }
}
