import AppKit
import SwiftUI
import ChatCore

@MainActor extension AppDelegate {
    func runExperienceChecks(output: URL) {
        Task {
            var checks: [String: Bool] = [:]
            let savedPreferences = ["selectedDatabaseGroupV3", "followCurrentConversationV4"].map { ($0, UserDefaults.standard.object(forKey: $0)) }
            do {
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                checks.merge(try await connectionModelChecks()) { _, new in new }
                checks.merge(try await followModelChecks()) { _, new in new }
                checks.merge(try await chatConversationChecks()) { _, new in new }
                checks.merge(try await composerChecks()) { _, new in new }
                checks.merge(try await editMenuChecks()) { _, new in new }
                try model.loadExperiencePreview(); model.companionEnabled = false
                model.question = "完整的合成流式回答"; model.ask()
                var seen = Set<Int>(), samples = 0
                while model.busy && samples < 400 {
                    try await Task.sleep(for: .milliseconds(40)); samples += 1
                    if !model.streamingText.isEmpty {
                        if seen.isEmpty {
                            checks["submitted_input_clears_before_completion"] = model.question.isEmpty
                            model.question = "生成期间继续编辑的新草稿"
                        }
                        seen.insert(model.streamingText.count)
                    }
                }
                checks["incremental_content_before_completion"] = seen.count > 2
                checks["complete_answer_displayed"] = model.turns.count == 2 && model.turns.last?.answer.claims.first?.text.contains("END_STREAM_OK") == true
                checks["completion_preserves_new_input_draft"] = model.question == "生成期间继续编辑的新草稿"
                model.question = "停止合成生成"; model.ask()
                for _ in 0..<100 { if !model.streamingText.isEmpty { break }; try await Task.sleep(for: .milliseconds(30)) }
                model.cancel()
                checks["cancel_preserves_partial"] = !model.busy && model.turns.count == 3 && model.turns.last?.answer.claims.first?.text.contains("已停止生成") == true
                model.question = "切换前的合成问题"; model.ask()
                for _ in 0..<100 { if !model.streamingText.isEmpty { break }; try await Task.sleep(for: .milliseconds(30)) }
                model.selectGroup("preview-group@chatroom")
                checks["switch_restores_other_conversation"] = model.turns.count == 1 && model.question == "这是另一个会话的草稿。"
                model.question = "保留群聊草稿"; model.selectGroup("preview-private")
                checks["switch_back_preserves_partial_and_history"] = model.turns.count == 4 && model.question == "切换前的合成问题" && !model.busy
                try await Task.sleep(for: .milliseconds(250))
                checks["cancelled_request_cannot_append_to_new_context"] = model.turns.count == 4
                model.selectGroup("preview-group@chatroom")
                checks["drafts_are_per_conversation"] = model.question == "保留群聊草稿"
                model.config.model = "disconnect"; model.question = "合成断流测试"; model.ask()
                for _ in 0..<200 { if !model.busy { break }; try await Task.sleep(for: .milliseconds(30)) }
                checks["disconnect_preserves_partial"] = !model.busy && !model.error.isEmpty && model.turns.count == 2
                checks["failure_restores_submitted_input"] = model.question == "合成断流测试"
                model.autoFollow = true
                let candidate = model.groups.first!
                let previousID = model.groupID
                let previousTurns = model.turns.map(\.id)
                model.applyFollowDetection(.init(group: nil, state: "ambiguous", visited: 0, evidenceCount: 2, roleCounts: [:]))
                checks["ambiguous_window_cannot_bind_or_send"] = model.groupID == previousID && !model.canAsk
                checks["identity_gap_preserves_visible_answer"] = model.turns.map(\.id) == previousTurns
                model.applyFollowDetection(.init(group: nil, state: "unsupportedWindow", visited: 0, evidenceCount: 0, roleCounts: [:]))
                checks["unsupported_window_blocks_send_and_preserves_conversation"] = !model.canAsk && model.groupID == previousID && model.turns.map(\.id) == previousTurns
                model.applyFollowDetection(.init(group: candidate, state: "confirmed", visited: 0, evidenceCount: 1, roleCounts: [:]))
                checks["exact_native_window_title_follows_automatically"] = model.autoFollow && model.groupID == candidate.id && model.canAsk
                model.selectGroup(candidate.id)
                checks["explicit_selection_fixes_conversation"] = !model.autoFollow && model.groupID == candidate.id
                model.config.model = "synthetic-stream"
                model.question = "生成中开始新对话"; model.ask()
                for _ in 0..<100 { if !model.streamingText.isEmpty { break }; try await Task.sleep(for: .milliseconds(30)) }
                checks["new_conversation_test_has_active_stream"] = model.busy && !model.streamingText.isEmpty
                let retainedGroup = model.groupID, retainedRange = model.range
                model.startNewConversation()
                checks["new_conversation_cancels_and_clears_stream"] = !model.busy && model.turns.isEmpty && model.streamingText.isEmpty && model.pendingQuestion.isEmpty && model.frozenSnapshot == nil
                checks["new_conversation_preserves_selection"] = model.groupID == retainedGroup && model.range == retainedRange
                model.question = "新对话的新草稿"
                try await Task.sleep(for: .seconds(3))
                checks["old_completion_cannot_restore_cleared_context"] = !model.busy && model.turns.isEmpty && model.streamingText.isEmpty && model.pendingQuestion.isEmpty && model.question == "新对话的新草稿"
                let view = MarkdownView(text: "## Markdown 阅读验收\n\n**粗体**、*斜体*与 `行内代码`。\n\n- 第一项\n  - 嵌套项\n\n> 引用应与正文有清楚区分。\n\n| 项目 | 结果 |\n| --- | --- |\n| 私聊 | 已包含双方发言 |\n| 流式 | 逐段展示 |\n\n```swift\nlet message = \"你好，世界\"\nprint(message)\n```\n\n最后一段。")
                    .padding(22).frame(width: 420).background(.white).foregroundStyle(.black)
                let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 420, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
                window.contentView = NSHostingView(rootView: view)
                window.contentView?.layoutSubtreeIfNeeded()
                render(window, output.appendingPathComponent("markdown-native.png"))
                checks["markdown_render_artifact_created"] = FileManager.default.fileExists(atPath: output.appendingPathComponent("markdown-native.png").path)
            } catch { checks["unexpected_error"] = false }
            let passed = !checks.isEmpty && checks.values.allSatisfy { $0 }
            let report: [String: Any] = ["checks": checks, "passed": passed, "syntheticOnly": true, "realChatRead": false, "remoteRequests": 0]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: output.appendingPathComponent("experience-checks.json")) }
            for (key, value) in savedPreferences { if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
            exit(passed ? 0 : 2)
        }
    }
}
