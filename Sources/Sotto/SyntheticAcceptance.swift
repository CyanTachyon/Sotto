import AppKit
import ImageIO
import SottoCore

@MainActor enum SyntheticAcceptance {
    static func run(config: ModelConfig, output: URL) async {
        var report: [String: Any] = ["syntheticOnly": true, "privateMessagesRead": false, "privateImagesSent": false]
        do {
            let now = Date(), id = UUID()
            let rows = (0..<1005).map { i in ChatMessage(sessionID: id, timestamp: now.addingTimeInterval(Double(i-1005)*300), sender: "Fixture", text: "Synthetic message \(i): " + String(repeating: "ordinary sample note. ", count: 5) + (i == 0 ? "START CODE ALPHA." : i == 1004 ? "END CODE OMEGA. Meeting moved to 15:30." : ""), source: "synthetic", sourceLine: i+1) }
            let session = try ChatSession(id: id, name: "Synthetic Long Conversation", origin: .demo, sourceDescription: "Entirely fictional", messages: rows)
            let snapshot = try Snapshot(session: session, window: TimeWindow(start: now.addingTimeInterval(-604800), end: now), includeUnknown: false)
            let key = try await CredentialStore.readAsync(endpoint: config.endpoint), client = ModelClient()
            var textConfig = config; textConfig.supportsVision = false
            let question = "请用一句自然中文概括开头和结尾的代码，以及会议的新时间。自然使用中文引号，不要 JSON 或引用编号。"
            let answer = try await client.ask(snapshot: snapshot, question: question, history: [], config: textConfig, key: key)
            let follow = try await client.ask(snapshot: snapshot, question: "用一句自然中文告诉我会议几点开，不要引用编号。", history: [Followup(question: question, answer: answer)], config: textConfig, key: key)
            report["longRecordCount"] = snapshot.messages.count; report["longTextBytes"] = snapshot.textBytes
            report["longAnswer"] = answer.text
            report["naturalFollowup"] = follow.text
            let base = output.deletingLastPathComponent().appendingPathComponent("synthetic-media")
            let root = base.appendingPathComponent("db_storage")
            let chat = "synthetic@chatroom"
            // Derive the directory using the same selected-conversation hash as the reader.
            let groupHash = MD5ForFixture.hash(chat)
            let dir = base.appendingPathComponent("msg/attach/\(groupHash)/2026-10/Img")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let path = dir.appendingPathComponent("0123456789abcdef0123456789abcdef.png")
            let picture = NSImage(size: NSSize(width: 600,height: 360))
            picture.lockFocus()
            NSColor.white.setFill(); NSRect(x:0,y:0,width:600,height:360).fill()
            NSColor.red.setFill(); NSRect(x:50,y:100,width:140,height:140).fill()
            NSColor.blue.setFill(); NSBezierPath(ovalIn:NSRect(x:370,y:100,width:140,height:140)).fill()
            ("VISION 4729" as NSString).draw(at:NSPoint(x:160,y:290),withAttributes:[.font:NSFont.systemFont(ofSize:30),.foregroundColor:NSColor.black])
            picture.unlockFocus()
            let rep = NSBitmapImageRep(data: picture.tiffRepresentation!)!
            try rep.representation(using: .png, properties: [:])!.write(to:path)
            let visionID = UUID()
            let visionSession = try ChatSession(id:visionID,name:"Synthetic Vision",origin:.demo,sourceDescription:"Fictional shape chart",messages:[ChatMessage(sessionID:visionID,timestamp:now,sender:"Fixture Artist",text:"[图片]",source:"synthetic",sourceLine:1,image:ChatImage(path:path.path,status:"synthetic image"))])
            let visionSnapshot = try Snapshot(session:visionSession,window:TimeWindow(start:now.addingTimeInterval(-1),end:now.addingTimeInterval(1)),includeUnknown:false)
            var visionConfig = config; visionConfig.supportsVision = true
            let prepared = await ImageLoader.prepare(snapshot:visionSnapshot,root:root.path,config:visionConfig,chat:chat)
            guard prepared.images.count == 1 else { throw ChatError.invalid("Synthetic image preparation failed: " + prepared.summary) }
            let vision = try await client.ask(snapshot:visionSnapshot,question:"图片左边和右边分别是什么颜色和形状？上方文字是什么？直接自然回答。",history:[],config:visionConfig,key:key,images:prepared.images)
            let visionText = vision.text
            report["visionAnswer"] = visionText; report["imagePreparation"] = prepared.summary
            let longText = answer.text
            let checks = ["over800Messages":snapshot.messages.count>800,"over80KB":snapshot.textBytes>80000,"firstAndLastIncluded":longText.contains("ALPHA") && longText.contains("OMEGA"),"naturalAnswerDisplayed":!longText.isEmpty,"followupDisplayed":!follow.text.isEmpty,"imageActuallyAttached":prepared.images.count==1,"visionIdentifiedColorsAndText":visionText.contains("红") && visionText.contains("蓝") && visionText.contains("4729")]
            report["checks"] = checks; report["passed"] = checks.values.allSatisfy{$0}
            report["modelRequestCount"] = 3
            try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys,.prettyPrinted]).write(to:output,options:.atomic)
            exit(checks.values.allSatisfy{$0} ? 0 : 2)
        } catch {
            report["passed"] = false; report["error"] = error.localizedDescription
            try? JSONSerialization.data(withJSONObject:report,options:[.sortedKeys,.prettyPrinted]).write(to:output,options:.atomic)
            exit(2)
        }
    }
}
import CryptoKit
private enum MD5ForFixture {
    static func hash(_ value: String) -> String { Insecure.MD5.hash(data:Data(value.utf8)).map{String(format:"%02x",$0)}.joined() }
}
