import AppKit
import SwiftUI

enum MessageComposerContext: Equatable {
    case database(account: String, conversation: String)
    case imported(UUID?)
}

/// Keep Return handling in the text input client so marked IME text reaches the
/// input method before a send action can run. Pasting remains native plain text.
@MainActor final class MessageComposerTextView: NSTextView {
    var canSend = false
    var onSend: (() -> Void)?
    private var handlingMarkedReturn = false
    private var draftContext: MessageComposerContext?
    private var lastFocusRequest: Int?
    private(set) var draftGeneration: UInt = 0

    override func keyDown(with event: NSEvent) {
        guard Self.isReturn(event) else { super.keyDown(with: event); return }
        if hasMarkedText() {
            // The input method may commit its text and then issue insertNewline
            // within this same key event. Keep this guard until interpretation ends.
            handlingMarkedReturn = true
            defer { handlingMarkedReturn = false }
            super.keyDown(with: event)
            return
        }
        guard isEditable else { return }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if modifiers.contains(.command) || modifiers.contains(.shift) {
            super.insertNewline(nil)
        } else if modifiers.isEmpty {
            if !event.isARepeat, canSend, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { onSend?() }
        } else {
            super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown,
              Self.isReturn(event), event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        // Do not consume the candidate-confirmation event as an app shortcut.
        // Returning false lets the normal keyDown/input-method path handle it.
        guard !hasMarkedText() else { return false }
        if isEditable { super.insertNewline(nil) }
        return true
    }

    override func insertNewline(_ sender: Any?) {
        guard !handlingMarkedReturn, !hasMarkedText() else { return }
        super.insertNewline(sender)
    }

    override func insertNewlineIgnoringFieldEditor(_ sender: Any?) {
        guard !handlingMarkedReturn, !hasMarkedText() else { return }
        super.insertNewlineIgnoringFieldEditor(sender)
    }

    func applyExternalText(_ text: String, resetUndo: Bool = false) {
        guard resetUndo || string != text || hasMarkedText() else { return }
        let selection = selectedRange()
        inputContext?.discardMarkedText()
        unmarkText()
        string = text
        let length = (text as NSString).length
        let location = min(selection.location, length)
        setSelectedRange(NSRange(location: location, length: min(selection.length, length - location)))
        // A new conversation or a submitted draft must not be recoverable into a
        // different conversation through the native undo stack.
        undoManager?.removeAllActions()
    }

    /// Context changes reset native state even when the model's text is identical
    /// (most commonly two empty drafts). Normal renders leave editing/IME intact.
    func synchronizeDraft(_ text: String, context: MessageComposerContext, focusRequest: Int,
                          lastDeliveredText: String) -> (appliedText: Bool, requestsFocus: Bool) {
        let contextChanged = draftContext != context
        let requestsFocus = lastFocusRequest.map { $0 != focusRequest } ?? false
        draftContext = context
        lastFocusRequest = focusRequest
        if contextChanged || requestsFocus {
            draftGeneration &+= 1
            applyExternalText(text, resetUndo: true)
            return (true, requestsFocus)
        }
        if string != text, !hasMarkedText() || text != lastDeliveredText {
            applyExternalText(text)
            return (true, false)
        }
        return (false, false)
    }

    private static func isReturn(_ event: NSEvent) -> Bool { event.keyCode == 36 || event.keyCode == 76 }
}

struct MessageComposer: NSViewRepresentable {
    @Binding var text: String
    let canSend: Bool
    let editable: Bool
    let contextID: MessageComposerContext
    let focusRequest: Int
    let onSend: () -> Void
    @Environment(\.isEnabled) private var enabled

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 58))
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.hasHorizontalScroller = false
        let view = MessageComposerTextView(frame: scroll.contentView.bounds)
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.isSelectable = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.drawsBackground = false
        view.font = .systemFont(ofSize: 14)
        view.textColor = NSColor(AppTheme.textPrimary)
        view.insertionPointColor = NSColor(AppTheme.accent)
        view.textContainerInset = NSSize(width: 0, height: 6)
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        view.setAccessibilityLabel("输入问题")
        view.setAccessibilityHelp("Return 发送；Command Return 或 Shift Return 换行。输入法候选需要先确认。")
        view.setAccessibilityIdentifier("message-composer")
        view.string = text
        view.delegate = context.coordinator
        view.onSend = { [weak coordinator = context.coordinator] in coordinator?.send() }
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? MessageComposerTextView else { return }
        let coordinator = context.coordinator
        coordinator.parent = self
        view.canSend = canSend && enabled
        view.isEditable = editable && enabled
        let result = view.synchronizeDraft(text, context: contextID, focusRequest: focusRequest,
                                           lastDeliveredText: coordinator.lastDeliveredText)
        if result.appliedText { coordinator.lastDeliveredText = text }
        if result.requestsFocus {
            let generation = view.draftGeneration
            DispatchQueue.main.async { [weak view] in
                guard let view, view.draftGeneration == generation, view.isEditable,
                      let window = view.window, window.isVisible else { return }
                window.makeFirstResponder(view)
            }
        }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        guard let view = scroll.documentView as? MessageComposerTextView else { return }
        view.delegate = nil
        view.onSend = nil
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MessageComposer
        var lastDeliveredText: String

        init(_ parent: MessageComposer) {
            self.parent = parent
            lastDeliveredText = parent.text
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? MessageComposerTextView else { return }
            lastDeliveredText = view.string
            if parent.text != view.string { parent.text = view.string }
        }

        func send() {
            guard parent.canSend, parent.editable else { return }
            parent.onSend()
        }
    }
}
