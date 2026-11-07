import AppKit
import Combine
import SwiftUI
import SimDeckCore

final class StatusItemController: NSObject, NSPopoverDelegate {
    private let model: AppModel
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let contextMenu = NSMenu()
    private let quitAction: () -> Void
    private var cancellables = Set<AnyCancellable>()
    private var escapeMonitor: Any?
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?

    private static let popoverSize = NSSize(width: 390, height: 420)

    init(model: AppModel, actions: PanelActions) {
        self.model = model
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        self.quitAction = actions.quit
        super.init()

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "iphone", accessibilityDescription: "SimDeck")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
            button.toolTip = "SimDeck"
            button.target = self
            button.action = #selector(handleStatusItemClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let quitItem = NSMenuItem(
            title: AppLanguage.text("menu.quit"),
            action: #selector(quitApplication(_:)),
            keyEquivalent: ""
        )
        quitItem.target = self
        contextMenu.addItem(quitItem)

        popover.contentViewController = NSHostingController(
            rootView: AVDPanelView(model: model, actions: actions)
        )
        popover.contentSize = Self.popoverSize
        popover.delegate = self

        Publishers.CombineLatest3(model.$running, model.$busyAVDs, model.$avds)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateBadge() }
            .store(in: &cancellables)

        updateBadge()
    }

    deinit {
        stopMonitors()
    }

    @objc private func handleStatusItemClick(_ button: NSStatusBarButton) {
        if let event = NSApp.currentEvent,
           event.type == .rightMouseUp ||
           (event.type == .leftMouseUp && event.modifierFlags.contains(.control)) {
            closePanel()
            let bounds = button.bounds
            let anchor = NSPoint(x: bounds.minX, y: button.isFlipped ? bounds.maxY : bounds.minY)
            contextMenu.popUp(positioning: nil, at: anchor, in: button)
        } else if popover.isShown {
            closePanel()
        } else {
            showPanel()
        }
    }

    @objc private func quitApplication(_ sender: Any?) {
        quitAction()
    }

    func showPanel() {
        guard !popover.isShown, let button = statusItem.button else { return }

        // 菜单栏应用默认不是 active 应用。先激活，popover 窗口才能成为 key window，
        // 系统才会按 .transient 语义在点击外部时关闭面板。
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        button.highlight(true)
        startMonitors()
    }

    func closePanel() {
        guard popover.isShown else {
            statusItem.button?.highlight(false)
            stopMonitors()
            return
        }
        popover.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        statusItem.button?.highlight(false)
        stopMonitors()
    }

    private func startMonitors() {
        if escapeMonitor == nil {
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if event.keyCode == 53,
                   self?.popover.isShown == true,
                   NSApp.modalWindow == nil {
                    self?.closePanel()
                    return nil
                }
                return event
            }
        }

        if localClickMonitor == nil {
            localClickMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] event in
                self?.handleLocalClick(event)
                return event
            }
        }

        if globalClickMonitor == nil {
            globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] _ in
                self?.closePanel()
            }
        }
    }

    private func stopMonitors() {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
        if let localClickMonitor {
            NSEvent.removeMonitor(localClickMonitor)
            self.localClickMonitor = nil
        }
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
            self.globalClickMonitor = nil
        }
    }

    /// 点击本应用的其他窗口（主窗口、设置窗口、对话框）时关闭面板。
    /// 面板内部和状态栏按钮上的点击排除在外。
    private func handleLocalClick(_ event: NSEvent) {
        guard popover.isShown else { return }
        if let panelWindow = popover.contentViewController?.view.window,
           event.window === panelWindow {
            return
        }
        if let button = statusItem.button, event.window === button.window {
            let point = button.convert(event.locationInWindow, from: nil)
            if button.bounds.contains(point) {
                return
            }
        }
        closePanel()
    }

    /// 点击其他应用或桌面时关闭面板。全局监听收不到本应用的事件，
    /// 本应用内的点击由 `handleLocalClick` 处理。
    private func updateBadge() {
        statusItem.button?.title = model.activeCount > 0 ? "\(model.activeCount)" : ""
    }
}
