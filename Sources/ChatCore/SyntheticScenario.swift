import Foundation

/// Public regression fixture, entirely fictional; never loads the user's real sessions.
public enum SyntheticScenario {
    public static func snapshot() throws -> Snapshot {
        let id = UUID(), base = Date(timeIntervalSince1970: 1_700_000_000)
        let rows: [(Int, String, String)] = [
            (1,"产品","15点客户演示，展示登录、报表、支付。"),(3,"测试","Safari登录401，Chrome正常。"),
            (4,"设计","咖啡店不开门。"),(6,"前端","已复现，在查。"),(9,"后端","暂不明原因，先别重置账号。"),
            (12,"产品","问客户能否改15:30。"),(15,"前端","定位登录回调Cookie配置，修复发预发。"),
            (17,"测试","预发Safari能登录，继续回归。"),(19,"产品","客户同意改15:30。"),(20,"设计","有人点咖啡吗？"),
            (22,"测试","登录Safari/Chrome回归通过；支付提交500，原因未定位。"),
            (24,"产品","只演示登录和报表，支付暂不展示，视频备用。"),(26,"前端","登录修复已上线，请确认。"),
            (28,"测试","线上Safari登录正常，支付还没修。"),(29,"产品","支付负责人未定，会后确认；15:30按精简范围演示。")]
        let messages = rows.enumerated().map { i, row in ChatMessage(sessionID: id, timestamp: base.addingTimeInterval(Double(row.0 * 60)), sender: row.1, text: row.2, source: "synthetic only", sourceLine: i + 1) }
        let session = try ChatSession(id: id, name: "人工演示项目群", origin: .demo, sourceDescription: "虚构验收样例", messages: messages)
        return try Snapshot(session: session, window: TimeWindow(start: base, end: base.addingTimeInterval(1800)), includeUnknown: false)
    }
    public static func narrative(_: Snapshot) throws -> Data {
        Data("""
        ## 登录问题的处理过程

        测试先发现 Safari 登录返回 401，而 Chrome 正常。前端复现后定位到登录回调的 Cookie 配置，修复发往预发。预发验证和回归通过后，修复上线，测试最终确认线上 Safari 登录正常。

        支付提交另有 500 错误，原因仍未定位，不能将它归因于登录配置。

        ## 演示安排与未决事项

        原定 15 点的客户演示已得到客户同意改至 **15:30**，展示范围缩减为登录和报表，支付暂不展示，并准备视频备用。

        支付尚未修复，负责人未定，会后再确认。支付错误原因与负责人都不能从现有记录确定。
        """.utf8)
    }
}
