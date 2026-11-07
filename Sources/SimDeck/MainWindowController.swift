import AppKit
import SimDeckCore
import SwiftUI

final class MainWindowController: NSObject, NSWindowDelegate, NSToolbarDelegate {
    let window: NSWindow
    private let model: AppModel
    private let onClose: () -> Void

    /// 侧边栏隐藏时允许更窄的窗口，需与 MainView 的 minWidth 保持一致。
    private static let minWidthWithSidebar: CGFloat = 740
    private static let minWidthWithoutSidebar: CGFloat = 520
    private static let minHeight: CGFloat = 480

    /// 用自定义 identifier：系统的 `.toggleSidebar` 项由 macOS 特殊管理（尾缘放置、按 responder
    /// chain 校验动作，本窗口控制器不在链上会被禁用），自定义项保证 target/action 生效。
    private static let sidebarToggleIdentifier = NSToolbarItem.Identifier("com.simdeck.toggleSidebar")

    init(model: AppModel, actions: PanelActions, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = "SimDeck"
        window.identifier = NSUserInterfaceItemIdentifier("main")
        window.setFrameAutosaveName("SimDeckMain")
        window.contentMinSize = NSSize(width: Self.minWidthWithSidebar, height: Self.minHeight)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: MainView(model: model, actions: actions)
        )
        window.delegate = self
        installToolbar()
        window.center()
    }

    func show() {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }

    // MARK: - 侧边栏

    private func installToolbar() {
        let toolbar = NSToolbar(identifier: "MainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.sidebarToggleIdentifier]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.sidebarToggleIdentifier]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard itemIdentifier == Self.sidebarToggleIdentifier else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = AppLanguage.text("sidebar.toggle")
        item.image = NSImage(
            systemSymbolName: "sidebar.left",
            accessibilityDescription: AppLanguage.text("sidebar.toggle")
        )
        // 窗口控制器不在 responder chain 上，须显式指定 target；
        // 关闭自动校验，避免 AppKit 按 responder chain 校验动作后禁用该项。
        item.target = self
        item.action = #selector(toggleSidebar(_:))
        item.autovalidates = false
        item.isEnabled = true
        return item
    }

    @objc func toggleSidebar(_ sender: Any?) {
        model.toggleSidebar()
        applySidebarMetrics()
    }

    /// 同步窗口最小尺寸到侧边栏状态；菜单入口切换后也需调用。
    func applySidebarMetrics() {
        let minWidth = model.sidebarVisible ? Self.minWidthWithSidebar : Self.minWidthWithoutSidebar
        window.contentMinSize = NSSize(width: minWidth, height: Self.minHeight)
        // 隐藏后缩窄过窗口再恢复显示时，把窗口扩到新的最小宽度。
        if window.frame.width < minWidth {
            var frame = window.frame
            frame.size.width = minWidth
            window.setFrame(frame, display: true, animate: true)
        }
    }
}
