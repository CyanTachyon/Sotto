import Foundation
import ChatCore

enum ReaderAcceptance {
    struct Input: Decodable {
        let result: DBRead
        let root: String
        let start: Double
        let end: Double
        let expectedCount: Int?
        let expectedImages: Int?
    }
    static func run(input: Data) async {
        var stage = "decode"
        do {
            let request = try JSONDecoder().decode(Input.self, from: input)
            let window = try TimeWindow(start: Date(timeIntervalSince1970: request.start), end: Date(timeIntervalSince1970: request.end))
            stage = "session"
            let session = try request.result.session(expectedAccount: DatabaseBridge.account(request.root), expectedChat: request.result.chat, window: window)
            stage = "snapshot"
            let snapshot = try Snapshot(session: session, window: window, includeUnknown: false)
            stage = "row_count"
            if let count = request.expectedCount, snapshot.messages.count != count { throw ChatError.invalid("row count mismatch") }
            var report: [String: Any] = ["passed": true, "messages": snapshot.messages.count, "imageRows": snapshot.messages.filter { $0.image != nil }.count, "textBytes": snapshot.textBytes, "privateContentEmitted": false, "networkRequests": 0]
            // Real local diagnostics only decode. Synthetic fixtures also exercise image preparation and request serialization.
            if let expected = request.expectedImages {
                for enabled in [false, true] {
                    var config = ModelConfig(); config.supportsVision = enabled
                    stage = enabled ? "vision_on" : "vision_off"
                    let prepared = await ImageLoader.prepare(snapshot: snapshot, root: request.root, config: config, chat: request.result.chat)
                    guard prepared.images.count == (enabled ? expected : 0) else { throw ChatError.invalid("image count mismatch") }
                    stage = "prompt"
                    let body = try Prompt.body(snapshot: snapshot, question: "Synthetic check", history: [], config: config, images: prepared.images)
                    let text = String(decoding: body, as: UTF8.self)
                    guard text.contains("synthetic long message"), text.contains("REPLY_MARKER"), text.contains("QUOTED_MARKER"), text.contains("CARD_MARKER"), text.contains("EMBEDDED_MARKER"), text.contains("[图片]"), text.contains("image_url") == (enabled && expected > 0) else { throw ChatError.invalid("request mismatch") }
                    report[enabled ? "visionOnImages" : "visionOffImages"] = prepared.images.count
                }
            }
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]))
            exit(0)
        } catch {
            // Never echo the input or decoded private content.
            print("{\"passed\":false,\"error\":\"local_read_chain_check_failed\",\"stage\":\"\(stage)\"}")
            exit(2)
        }
    }
}
