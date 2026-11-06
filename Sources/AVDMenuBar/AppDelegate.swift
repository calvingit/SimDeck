import AppKit

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

        if CommandLine.arguments.contains("--show-panel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.statusController.showPanel()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.stopPreview()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
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
