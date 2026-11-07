import AVDCore
import AppKit

enum Alerts {
    static func error(_ title: String, _ message: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: AppLanguage.text("action.ok"))
        alert.runModal()
    }

    static func confirmDestructive(
        title: String,
        message: String,
        actionTitle: String
    ) -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        // 默认按钮设为“取消”，避免连按 Return 直接执行破坏性操作。
        alert.addButton(withTitle: AppLanguage.text("action.cancel"))
        let destructive = alert.addButton(withTitle: actionTitle)
        destructive.hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }
}
