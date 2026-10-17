import AppKit

@MainActor enum AppMenus {
    static func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let app = NSMenu(title: "Sotto")
        app.addItem(withTitle: "关于 Sotto", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "外观与设置…", action: #selector(AppDelegate.settings), keyEquivalent: ",")
        app.addItem(.separator())
        app.addItem(withTitle: "隐藏 Sotto", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = app.addItem(withTitle: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "显示全部", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "退出 Sotto", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(NSMenuItem(title: app.title, action: nil, keyEquivalent: ""))
        main.items.last?.submenu = app

        // AppKit routes nil targets to the key window's first responder. This
        // also serves settings field editors and selectable answer text; binding
        // these actions to the composer would steal edits from those controls.
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(.separator())
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(NSMenuItem(title: edit.title, action: nil, keyEquivalent: ""))
        main.items.last?.submenu = edit

        let window = NSMenu(title: "窗口")
        window.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        let mainWindowItem = window.addItem(withTitle: "Sotto", action: #selector(AppDelegate.showMainWindow), keyEquivalent: "0")
        mainWindowItem.target = NSApp.delegate
        window.addItem(withTitle: "前置全部窗口", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        main.addItem(NSMenuItem(title: window.title, action: nil, keyEquivalent: ""))
        main.items.last?.submenu = window
        return main
    }
}
