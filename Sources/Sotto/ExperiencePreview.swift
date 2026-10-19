import Foundation
import SottoCore

@MainActor extension AppModel {
    func loadExperiencePreview() throws {
        guard isDevelopmentMode else { throw ChatError.invalid("合成预览仅用于开发与测试。") }
        try loadSyntheticPreview()
        guard let snapshot = frozenSnapshot else { return }
        let markdown = """
        ## 讨论小结

        这是**虚构预览**，用于验证阅读体验。

        - 小气泡跟随微信窗口。
        - 点击后展开，收起仍保留回答。

        > 正文仅为合成样例，不是微信聊天内容。

        | 功能 | 状态 |
        | --- | --- |
        | 私聊与群聊 | 统一会话入口 |
        | 流式输出 | 逐段显示 |

        ```swift
        let greeting = "你好，世界"
        print(greeting)
        ```

        可以提问以测试本机合成流式响应。
        """
        turns = [AnswerTurn(question: "这段讨论有哪些重点？", answer: try GroundedAnswer(validating: Data(markdown.utf8)), snapshot: snapshot)]
        config.endpoint = "http://127.0.0.1:27654/chat/completions"; config.model = "synthetic-stream"
        config.consentEndpoint = config.endpoint
        question = "请用 Markdown 总结这段虚构讨论。"
        groups = [DBGroup(id: "preview-private", name: "虚构联系人", aliases: []), DBGroup(id: "preview-group@chatroom", name: "虚构项目群", aliases: [])]
        groupID = "preview-private"; live = true
        selectGroup("preview-group@chatroom")
        try loadSyntheticPreview(); question = "这是另一个会话的草稿。"
        selectGroup("preview-private")
        identity = "虚构预览 · 仅连接本机合成服务"
        companionEnabled = true
        followForegroundIsRelevant = { true }
        followAXReader = { _ in .init(group: nil, state: "unsupported", visited: 0, evidenceCount: 0, roleCounts: [:]) }
    }
}
