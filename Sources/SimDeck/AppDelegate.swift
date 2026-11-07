import AppKit
import SimDeckCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel!
    private var coordinator: AppCoordinator!
    private var statusController: StatusItemController!
    private var mainWindowController: MainWindowController?
    private var settingsController: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AppAppearance.applyCurrent()

        model = AppModel()
        coordinator = AppCoordinator(
            model: model,
            showSettings: { [weak self] in
                self?.statusController?.closePanel()
                self?.showSettings()
            },
            quit: { NSApp.terminate(nil) },
            togglePanelPin: { [weak self] in
                self?.statusController?.togglePin()
            },
            openMain: { [weak self] in
                self?.statusController?.closePanel()
                self?.showMain()
            }
        )
        statusController = StatusItemController(model: model, actions: coordinator.actions)
        model.onError = { title, message in
            Alerts.error(title, message)
        }
        model.start()
        NSApp.mainMenu = makeMainMenu()

        if CommandLine.arguments.contains("--show-panel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.statusController.showPanel()
            }
        }
        if CommandLine.arguments.contains("--show-main") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.showMain()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.stopPreview()
        model?.stopWindowlessInstances()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// 最小主菜单：App 菜单（设置/退出）+ View 菜单（侧边栏 ⌘⌥S）。
    /// accessory 应用激活主窗口时显示；⌘⌥S 只能靠菜单项提供（NSToolbarItem 快捷键固定 ⌘ 前缀）。
    private func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "SimDeck")
        let settingsItem = NSMenuItem(
            title: AppLanguage.text("menu.settings"),
            action: #selector(showSettingsFromMenu),
            keyEquivalent: ","
        )
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        let quitItem = NSMenuItem(
            title: AppLanguage.text("menu.quit"),
            action: #selector(quitFromMenu),
            keyEquivalent: "q"
        )
        quitItem.target = self
        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: AppLanguage.text("menu.view"))
        let sidebarItem = NSMenuItem(
            title: AppLanguage.text("sidebar.toggle"),
            action: #selector(toggleSidebarFromMenu),
            keyEquivalent: "s"
        )
        sidebarItem.keyEquivalentModifierMask = [.command, .option]
        sidebarItem.target = self
        viewMenu.addItem(sidebarItem)
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        return mainMenu
    }

    @objc private func showSettingsFromMenu() {
        statusController.closePanel()
        showSettings()
    }

    @objc private func quitFromMenu() {
        NSApp.terminate(nil)
    }

    @objc private func toggleSidebarFromMenu() {
        model.toggleSidebar()
        mainWindowController?.applySidebarMetrics()
    }

    private func showMain() {
        if mainWindowController == nil {
            mainWindowController = MainWindowController(
                model: model,
                actions: coordinator.actions,
                onClose: { [weak self] in
                    self?.model.setPreviewVisible(false)
                }
            )
        }
        mainWindowController?.show()
        model.setPreviewVisible(true)
    }

    private func showSettings() {
        if settingsController == nil {
            settingsController = SettingsWindowController(model: model) { [weak self] in
                DispatchQueue.main.async {
                    self?.settingsController = nil
                }
            }
        }
        settingsController?.show()
    }
}
