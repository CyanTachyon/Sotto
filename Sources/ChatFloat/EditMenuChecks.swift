import AppKit

/// Exercise menu dispatch without reading or replacing the system clipboard.
@MainActor private final class EditMenuCheckTextView: NSTextView {
    let privatePasteboard = NSPasteboard.withUniqueName()
    var copied = false
    var cutText = false
    var pasted = false

    override func copy(_ sender: Any?) {
        copied = true
        privatePasteboard.clearContents()
        // NSTextView publishes the types its selection writer accepts; on this
        // system that is NSStringPboardType, not .string's modern UTI spelling.
        let types = writablePasteboardTypes
        privatePasteboard.declareTypes(types, owner: nil)
        _ = writeSelection(to: privatePasteboard, types: types)
    }
    override func cut(_ sender: Any?) {
        cutText = true
        copy(sender)
        insertText("", replacementRange: selectedRange())
    }
    override func paste(_ sender: Any?) {
        pasted = true
        _ = readSelection(from: privatePasteboard)
    }
    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(NSText.paste(_:)) {
            return isEditable && privatePasteboard.availableType(from: readablePasteboardTypes) != nil
        }
        return super.validateMenuItem(menuItem)
    }
}

@MainActor private final class EditMenuUndoDelegate: NSObject, NSTextViewDelegate {
    let edits = UndoManager()
    func undoManager(for view: NSTextView) -> UndoManager? { edits }
}

@MainActor private final class EditMenuCheckPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The application menu is installed by normal startup. Only this process's
/// synthetic window becomes key; no global events, other apps, or user data.
@MainActor func editMenuChecks() async throws -> [String: Bool] {
    guard let main = NSApp.mainMenu,
          let edit = main.items.compactMap(\.submenu).first(where: { $0.title == "编辑" }) else {
        return ["edit_menu_installed_at_startup": false]
    }
    let actions = ["undo:", "redo:", "cut:", "copy:", "paste:", "selectAll:"]
    var checks = ["edit_menu_installed_at_startup": true]
    checks["edit_menu_uses_standard_responder_chain_actions"] = actions.allSatisfy { name in
        edit.items.contains { $0.action == NSSelectorFromString(name) && $0.target == nil }
    }
    checks["edit_menu_redo_uses_command_shift_z"] = edit.items.contains {
        $0.action == NSSelectorFromString("redo:") && $0.keyEquivalent == "z" && $0.keyEquivalentModifierMask == [.command, .shift]
    }

    let previousKeyWindow = NSApp.keyWindow
    let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 380, height: 140),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.title = "编辑快捷键 · 合成检查"
    window.isReleasedWhenClosed = false
    let view = EditMenuCheckTextView(frame: NSRect(x: 0, y: 40, width: 380, height: 100))
    view.isRichText = false
    view.isEditable = true
    view.isSelectable = true
    view.allowsUndo = true
    let undoDelegate = EditMenuUndoDelegate()
    undoDelegate.edits.groupsByEvent = false
    view.delegate = undoDelegate
    let field = NSTextField(frame: NSRect(x: 10, y: 8, width: 350, height: 24))
    field.stringValue = "合成设置字段"
    let content = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 140))
    content.addSubview(view)
    content.addSubview(field)
    window.contentView = content
    defer {
        view.delegate = nil
        view.privatePasteboard.releaseGlobally()
        window.close()
        if let previousKeyWindow, previousKeyWindow.isVisible { previousKeyWindow.makeKey() }
    }
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    try await Task.sleep(for: .milliseconds(80))
    window.makeFirstResponder(view)

    func key(_ character: String, code: UInt16, shift: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero,
                        modifierFlags: shift ? [.command, .shift] : [.command],
                        timestamp: 0, windowNumber: window.windowNumber, context: nil,
                        characters: shift ? character.uppercased() : character,
                        charactersIgnoringModifiers: character, isARepeat: false, keyCode: code)!
    }
    func press(_ character: String, code: UInt16, shift: Bool = false) -> Bool {
        main.update()
        edit.update()
        return main.performKeyEquivalent(with: key(character, code: code, shift: shift))
    }
    view.string = "合成问题甲乙"
    view.setSelectedRange(NSRange(location: 0, length: 0))
    checks["edit_menu_missing_baseline_cannot_route_command_a"] =
        !NSMenu().performKeyEquivalent(with: key("a", code: 0)) && view.selectedRange().length == 0
    checks["edit_menu_command_a_selects_native_text"] =
        press("a", code: 0) && view.selectedRange() == NSRange(location: 0, length: (view.string as NSString).length)
    checks["edit_menu_command_c_routes_to_first_responder"] =
        press("c", code: 8) && view.copied && view.privatePasteboard.string(forType: .string) == "合成问题甲乙"
    undoDelegate.edits.beginUndoGrouping()
    let cutHandled = press("x", code: 7)
    undoDelegate.edits.endUndoGrouping()
    checks["edit_menu_command_x_cuts_selected_text"] = cutHandled && view.cutText && view.string.isEmpty
    undoDelegate.edits.beginUndoGrouping()
    let pasteHandled = press("v", code: 9)
    undoDelegate.edits.endUndoGrouping()
    view.breakUndoCoalescing()
    checks["edit_menu_command_v_pastes_without_send"] = pasteHandled && view.pasted && view.string == "合成问题甲乙"
    checks["edit_menu_command_z_undoes_native_edit"] = press("z", code: 6) && view.string.isEmpty
    checks["edit_menu_command_shift_z_redoes_native_edit"] = press("z", code: 6, shift: true) && view.string == "合成问题甲乙"

    window.makeFirstResponder(field)
    if let editor = field.currentEditor() as? NSTextView {
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        checks["edit_menu_settings_field_editor_receives_select_all"] =
            press("a", code: 0) && editor.selectedRange().length == (field.stringValue as NSString).length
        checks["edit_menu_settings_copy_and_paste_resolve_to_field_editor"] =
            NSApp.target(forAction: #selector(NSText.copy(_:)), to: nil, from: nil) as? NSTextView === editor &&
            NSApp.target(forAction: #selector(NSText.paste(_:)), to: nil, from: nil) as? NSTextView === editor
    } else {
        checks["edit_menu_settings_field_editor_receives_select_all"] = false
        checks["edit_menu_settings_copy_and_paste_resolve_to_field_editor"] = false
    }
    window.makeFirstResponder(view)
    view.isEditable = false
    view.setSelectedRange(NSRange(location: 0, length: 0))
    checks["edit_menu_readonly_answer_can_select_and_copy"] =
        press("a", code: 0) && press("c", code: 8) && view.privatePasteboard.string(forType: .string) == "合成问题甲乙"
    edit.update()
    checks["edit_menu_readonly_answer_disables_paste"] =
        edit.items.first(where: { $0.action == #selector(NSText.paste(_:)) })?.isEnabled == false
    if let appMenu = main.items.first?.submenu,
       let settings = appMenu.items.first(where: { $0.action == #selector(AppDelegate.settings) }),
       let quit = appMenu.items.first(where: { $0.action == #selector(NSApplication.terminate(_:)) }),
       let delegate = NSApp.delegate as? AppDelegate {
        checks["app_menu_settings_resolves_to_application_delegate"] =
            settings.target == nil && NSApp.target(forAction: settings.action!, to: nil, from: settings) as? AppDelegate === delegate
        checks["app_menu_quit_resolves_to_application_with_termination_delegate"] =
            quit.target == nil && NSApp.target(forAction: quit.action!, to: nil, from: quit) as? NSApplication === NSApp &&
            delegate.responds(to: #selector(NSApplicationDelegate.applicationShouldTerminate(_:)))
    } else {
        checks["app_menu_settings_resolves_to_application_delegate"] = false
        checks["app_menu_quit_resolves_to_application_with_termination_delegate"] = false
    }
    checks.merge(try await nonactivatingPanelMenuChecks()) { _, new in new }
    withExtendedLifetime(undoDelegate) {}
    return checks
}

/// Send the key event through NSApplication to a real composer in the same panel
/// style as production. The separate interactive fixture verifies inactive-app
/// delivery: deactivate() alone cannot create that OS focus state in this runner.
/// Copy/paste targets are checked without invoking system clipboard actions.
@MainActor private func nonactivatingPanelMenuChecks() async throws -> [String: Bool] {
    let previousKeyWindow = NSApp.keyWindow
    let panel = EditMenuCheckPanel(contentRect: NSRect(x: 140, y: 160, width: 360, height: 100),
                                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    panel.hidesOnDeactivate = false
    panel.becomesKeyOnlyIfNeeded = false
    let view = MessageComposerTextView(frame: panel.contentLayoutRect)
    view.isRichText = false
    view.isEditable = true
    view.isSelectable = true
    view.string = "非激活浮窗的合成草稿"
    view.setSelectedRange(NSRange(location: 0, length: 0))
    panel.contentView = view
    defer {
        panel.close()
        if let previousKeyWindow, previousKeyWindow.isVisible { previousKeyWindow.makeKey() }
    }
    panel.makeKeyAndOrderFront(nil)
    panel.makeFirstResponder(view)
    try await Task.sleep(for: .milliseconds(60))
    var checks: [String: Bool] = [
        "edit_menu_nonactivating_panel_is_key_with_real_composer":
            panel.styleMask.contains(.nonactivatingPanel) && panel.isKeyWindow && panel.firstResponder === view
    ]
    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
                                timestamp: ProcessInfo.processInfo.systemUptime,
                                windowNumber: panel.windowNumber, context: nil,
                                characters: "a", charactersIgnoringModifiers: "a",
                                isARepeat: false, keyCode: 0)!
    NSApp.sendEvent(event)
    checks["edit_menu_panel_application_event_routes_command_a_to_real_composer"] =
        panel.firstResponder === view &&
        view.selectedRange() == NSRange(location: 0, length: (view.string as NSString).length)
    checks["edit_menu_panel_copy_and_paste_target_real_composer"] =
        NSApp.target(forAction: #selector(NSText.copy(_:)), to: nil, from: nil) as? MessageComposerTextView === view &&
        NSApp.target(forAction: #selector(NSText.paste(_:)), to: nil, from: nil) as? MessageComposerTextView === view
    return checks
}
