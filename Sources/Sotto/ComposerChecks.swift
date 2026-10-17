import AppKit

@MainActor private final class ComposerUndoCheckDelegate: NSObject, NSTextViewDelegate {
    let nativeUndo = UndoManager()
    func undoManager(for view: NSTextView) -> UndoManager? { nativeUndo }
}

/// Dispatch only to this unshown, process-owned NSTextView. No global key events,
/// system clipboard, other application, network, or account data is involved.
@MainActor func composerChecks() async throws -> [String: Bool] {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 100),
                          styleMask: [.borderless], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    let view = MessageComposerTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 100))
    view.isRichText = false
    view.isEditable = true
    view.isSelectable = true
    window.contentView = view
    window.makeFirstResponder(view)
    var sends = 0
    view.onSend = { sends += 1 }
    view.canSend = true
    var checks: [String: Bool] = [:]

    func enter(_ modifiers: NSEvent.ModifierFlags = [], keyCode: UInt16 = 36, repeating: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                        timestamp: 0, windowNumber: 0, context: nil,
                        characters: "\r", charactersIgnoringModifiers: "\r",
                        isARepeat: repeating, keyCode: keyCode)!
    }
    func reset(_ text: String) {
        view.applyExternalText(text)
        view.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        view.canSend = true
        view.isEditable = true
    }

    reset("完整问题")
    view.keyDown(with: enter())
    checks["composer_return_sends_without_inserting_newline"] = sends == 1 && view.string == "完整问题"
    view.keyDown(with: enter(repeating: true))
    checks["composer_held_return_does_not_resend"] = sends == 1

    reset("第一行")
    let commandHandled = view.performKeyEquivalent(with: enter(.command))
    checks["composer_command_return_is_handled_before_keydown"] = commandHandled && sends == 1 && view.string == "第一行\n"
    window.makeFirstResponder(nil)
    _ = view.performKeyEquivalent(with: enter(.command))
    checks["composer_does_not_take_command_return_from_another_responder"] = sends == 1 && view.string == "第一行\n"
    window.makeFirstResponder(view)
    reset("第一行")
    view.keyDown(with: enter(.command))
    checks["composer_command_return_keydown_inserts_newline"] = sends == 1 && view.string == "第一行\n"
    reset("第一行")
    view.keyDown(with: enter(.shift))
    checks["composer_shift_return_inserts_newline"] = sends == 1 && view.string == "第一行\n"

    reset("数字键盘发送")
    view.keyDown(with: enter(.numericPad, keyCode: 76))
    checks["composer_keypad_enter_sends"] = sends == 2
    reset(" \n\t ")
    view.keyDown(with: enter())
    checks["composer_whitespace_cannot_send"] = sends == 2
    reset("暂不可发送")
    view.canSend = false
    view.keyDown(with: enter())
    checks["composer_disabled_send_keeps_draft"] = sends == 2 && view.string == "暂不可发送"
    view.insertText("，下一条草稿", replacementRange: view.selectedRange())
    view.keyDown(with: enter())
    checks["composer_can_prepare_next_draft_while_send_is_disabled"] =
        sends == 2 && view.isEditable && view.string == "暂不可发送，下一条草稿"
    reset("正在回答")
    view.isEditable = false
    view.keyDown(with: enter())
    let disabledCommandHandled = view.performKeyEquivalent(with: enter(.command))
    checks["composer_readonly_input_cannot_send_or_insert_newline"] = disabledCommandHandled && sends == 2 && view.string == "正在回答"

    reset("")
    view.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    checks["composer_native_text_view_has_real_marked_text"] = view.hasMarkedText()
    view.keyDown(with: enter())
    checks["composer_marked_return_cannot_send_or_add_newline"] = sends == 2 && !view.string.contains("\n")
    view.unmarkText()
    view.applyExternalText("中文候选已确认")
    view.keyDown(with: enter())
    checks["composer_next_return_after_ime_confirmation_sends"] = sends == 3

    reset("")
    view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    let markedCommandHandled = view.performKeyEquivalent(with: enter(.command))
    view.keyDown(with: enter(.command))
    checks["composer_marked_command_return_reaches_input_method_without_send"] = !markedCommandHandled && sends == 3 && !view.string.contains("\n")
    view.applyExternalText("")
    checks["composer_new_conversation_discards_marked_draft"] = view.string.isEmpty && !view.hasMarkedText()

    reset("")
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally(); window.close() }
    pasteboard.setString("第一行\n第二行\n第三行", forType: .string)
    let pasted = view.readSelection(from: pasteboard, type: .string)
    checks["composer_native_plain_text_paste_preserves_newlines_without_send"] =
        pasted && view.string == "第一行\n第二行\n第三行" && sends == 3

    // Use native NSTextView edits and a private undo manager, rather than a fake
    // stored callback, to reproduce an empty draft whose previous text is undoable.
    let undoDelegate = ComposerUndoCheckDelegate()
    let undo = undoDelegate.nativeUndo
    undo.groupsByEvent = false
    view.allowsUndo = true
    view.delegate = undoDelegate
    defer { withExtendedLifetime(undoDelegate) { view.delegate = nil } }
    let contextA = MessageComposerContext.database(account: "/synthetic/account", conversation: "a")
    let contextB = MessageComposerContext.database(account: "/synthetic/account", conversation: "b")
    let contextC = MessageComposerContext.database(account: "/synthetic/account", conversation: "c")
    func replaceNatively(_ text: String) {
        view.breakUndoCoalescing()
        undo.beginUndoGrouping()
        view.insertText(text, replacementRange: NSRange(location: 0, length: (view.string as NSString).length))
        undo.endUndoGrouping()
        view.breakUndoCoalescing()
    }
    _ = view.synchronizeDraft("", context: contextA, focusRequest: 0, lastDeliveredText: "")
    replaceNatively("A 的草稿")
    replaceNatively("")
    let emptyWasUndoable = undo.canUndo && view.string.isEmpty
    if undo.canUndo { undo.undo() }
    checks["composer_native_undo_fixture_restores_deleted_draft"] = emptyWasUndoable && view.string == "A 的草稿"
    if undo.canRedo { undo.redo() }
    let refresh = view.synchronizeDraft("", context: contextA, focusRequest: 0, lastDeliveredText: "")
    checks["composer_same_context_refresh_preserves_native_undo"] =
        view.string.isEmpty && undo.canUndo && !refresh.appliedText && !refresh.requestsFocus
    let switchToB = view.synchronizeDraft("", context: contextB, focusRequest: 0, lastDeliveredText: "")
    checks["composer_empty_context_switch_clears_undo_and_redo_without_focusing"] =
        switchToB.appliedText && !switchToB.requestsFocus && view.string.isEmpty && !undo.canUndo && !undo.canRedo

    view.applyExternalText("前一个会话的内容", resetUndo: true)
    replaceNatively("相同草稿")
    let sameTextWasUndoable = undo.canUndo
    _ = view.synchronizeDraft("相同草稿", context: contextC, focusRequest: 0, lastDeliveredText: "相同草稿")
    checks["composer_equal_nonempty_context_switch_clears_old_undo"] =
        sameTextWasUndoable && view.string == "相同草稿" && !undo.canUndo && !undo.canRedo

    _ = view.synchronizeDraft("", context: contextC, focusRequest: 0, lastDeliveredText: "相同草稿")
    replaceNatively("新对话之前的草稿")
    replaceNatively("")
    let beforeNewConversation = undo.canUndo
    let newConversation = view.synchronizeDraft("", context: contextC, focusRequest: 1, lastDeliveredText: "")
    checks["composer_new_conversation_resets_equal_empty_draft_undo"] =
        beforeNewConversation && newConversation.requestsFocus && view.string.isEmpty && !undo.canUndo && !undo.canRedo

    undo.beginUndoGrouping()
    view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    undo.endUndoGrouping()
    let composing = view.hasMarkedText()
    let markedText = view.string
    let unchanged = view.synchronizeDraft(markedText, context: contextC, focusRequest: 1, lastDeliveredText: markedText)
    checks["composer_stream_refresh_keeps_marked_text_without_focusing"] =
        composing && view.hasMarkedText() && !unchanged.appliedText && !unchanged.requestsFocus
    let switchFromIME = view.synchronizeDraft(markedText, context: contextA, focusRequest: 1, lastDeliveredText: markedText)
    checks["composer_equal_text_context_switch_ends_old_ime_without_focusing"] =
        switchFromIME.appliedText && !switchFromIME.requestsFocus && view.string == markedText && !view.hasMarkedText() && !undo.canUndo
    return checks
}
