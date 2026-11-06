import AppKit
import AVDCore

final class AppCoordinator {
    private let model: AppModel
    private let showSettings: () -> Void
    private let quitApp: () -> Void
    private let togglePanelPin: () -> Void
    private let openMain: () -> Void

    lazy var actions: PanelActions = makeActions()

    func previewCreateAVD() {
        promptCreateAVD()
    }

    init(
        model: AppModel,
        showSettings: @escaping () -> Void,
        quit: @escaping () -> Void,
        togglePanelPin: @escaping () -> Void,
        openMain: @escaping () -> Void
    ) {
        self.model = model
        self.showSettings = showSettings
        self.quitApp = quit
        self.togglePanelPin = togglePanelPin
        self.openMain = openMain
    }

    private func makeActions() -> PanelActions {
        PanelActions(
            start: { [weak self] avd in self?.model.start(avd) },
            shutdown: { [weak self] device, avd in self?.shutdown(device: device, avd: avd) },
            cancelStart: { [weak self] avd in
                self?.model.shutdown(displayName: avd.name, serial: nil, avdName: avd.name)
            },
            softReboot: { [weak self] device, avd in
                self?.model.softReboot(
                    displayName: avd?.name ?? device.displayName,
                    serial: device.serial,
                    avdName: avd?.name ?? device.avdName
                )
            },
            coldBoot: { [weak self] avd, device in
                self?.model.coldBoot(displayName: avd.name, serial: device?.serial, avd: avd)
            },
            wipe: { [weak self] avd, device in self?.confirmWipe(avd: avd, device: device) },
            delete: { [weak self] avd, device in self?.confirmDelete(avd: avd, device: device) },
            togglePinned: { [weak self] avd in self?.model.togglePinned(avd) },
            rename: { [weak self] avd, device in self?.promptRename(avd: avd, device: device) },
            move: { [weak self] avd, device in self?.promptMove(avd: avd, device: device) },
            create: { [weak self] in self?.promptCreateAVD() },
            refresh: { [weak self] in self?.model.refreshAll() },
            settings: { [weak self] in self?.showSettings() },
            togglePin: { [weak self] in self?.togglePanelPin() },
            quit: { [weak self] in self?.quitApp() },
            copyName: { [weak self] avd in self?.copyToPasteboard(avd.name) },
            copyPath: { [weak self] avd in self?.copyToPasteboard(avd.path) },
            copyCommand: { [weak self] avd in self?.copyLaunchCommand(avd) },
            openDirectory: { [weak self] avd in self?.openDirectory(avd) },
            openLog: { [weak self] avd in self?.openLog(avd) },
            details: { [weak self] avd, device in self?.showDetails(avd: avd, device: device) },
            saveSnapshot: { [weak self] avd, device in self?.promptSaveSnapshot(avd: avd, device: device) },
            loadSnapshot: { [weak self] avd, device in self?.promptLoadSnapshot(avd: avd, device: device) },
            deleteSnapshot: { [weak self] avd, device in self?.promptDeleteSnapshot(avd: avd, device: device) },
            openShell: { [weak self] device, _ in self?.openTerminal(device: device, command: .shell) },
            openLogcat: { [weak self] device, _ in self?.openTerminal(device: device, command: .logcat) },
            screenshot: { [weak self] device, avd in self?.takeScreenshot(device: device, avd: avd) },
            openStudio: { [weak self] in self?.openAndroidStudio() },
            selectDevice: { [weak self] id in
                self?.model.selectedDeviceID = id
                self?.openMain()
            },
            openMain: { [weak self] in self?.openMain() },
            sendKey: { [weak self] device, keycode in
                self?.model.sendKey(serial: device.serial, keycode: keycode)
            },
            sendTap: { [weak self] device, x, y in
                self?.model.sendTap(serial: device.serial, x: x, y: y)
            },
            sendSwipe: { [weak self] device, x1, y1, x2, y2, durationMs in
                self?.model.sendSwipe(
                    serial: device.serial,
                    x1: x1, y1: y1, x2: x2, y2: y2,
                    durationMs: durationMs
                )
            }
        )
    }

    // MARK: - 生命周期

    private func shutdown(device: RunningEmulator, avd: AVD?) {
        guard !device.isRealDevice else { return }
        model.shutdown(
            displayName: avd?.name ?? device.displayName,
            serial: device.serial,
            avdName: avd?.name ?? device.avdName
        )
    }

    private func confirmWipe(avd: AVD, device: RunningEmulator?) {
        let message = AppLanguage.text("wipe.confirmMessage", avd.name, avd.path, device?.serial ?? AppLanguage.text("device.stopped"))
        guard Alerts.confirmDestructive(
            title: AppLanguage.text("wipe.confirmTitle", avd.name),
            message: message,
            actionTitle: AppLanguage.text("action.wipeData")
        ) else { return }
        model.wipeData(displayName: avd.name, serial: device?.serial, avd: avd)
    }

    private func confirmDelete(avd: AVD, device: RunningEmulator?) {
        var message = AppLanguage.text("avd.delete.confirmMessage", avd.name, avd.path, device?.serial ?? AppLanguage.text("device.stopped"))
        if device != nil {
            message += AppLanguage.text("avd.delete.runningWarning")
        } else {
            message += AppLanguage.text("avd.delete.recheckWarning")
        }
        guard Alerts.confirmDestructive(
            title: AppLanguage.text("avd.delete.confirmTitle", avd.name),
            message: message,
            actionTitle: AppLanguage.text("action.delete")
        ) else { return }
        model.delete(avd, serial: device?.serial)
    }

    private func promptRename(avd: AVD, device: RunningEmulator?) {
        guard let name = promptText(
            title: AppLanguage.text("avd.rename.title"),
            message: AppLanguage.text("avd.rename.prompt"),
            defaultValue: avd.name
        ), name != avd.name else {
            return
        }
        if device != nil {
            guard Alerts.confirmDestructive(
                title: AppLanguage.text("avd.rename.stopTitle"),
                message: AppLanguage.text("avd.rename.stopMessage", avd.name),
                actionTitle: AppLanguage.text("avd.rename.stopAction")
            ) else { return }
        }
        model.renameAVD(avd: avd, serial: device?.serial, newName: name)
    }

    private func promptMove(avd: AVD, device: RunningEmulator?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = AppLanguage.text("action.choose")
        panel.message = AppLanguage.text("avd.move.chooseFolder", avd.name)
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let parent = panel.url else { return }

        let target = parent.appendingPathComponent("\(avd.name).avd")
        guard target.path != avd.path else { return }
        guard !FileManager.default.fileExists(atPath: target.path) else {
            Alerts.error(AppLanguage.text("avd.move.destinationExists"), AppLanguage.text("avd.move.existingDirectory", target.path))
            return
        }
        guard Alerts.confirmDestructive(
            title: AppLanguage.text("avd.move.confirmTitle", avd.name),
            message: AppLanguage.text("avd.move.confirmMessage", target.path),
            actionTitle: AppLanguage.text("action.move")
        ) else { return }
        model.moveAVD(avd: avd, serial: device?.serial, newPath: target.path)
    }

    // MARK: - 创建 AVD

    private func promptCreateAVD() {
        model.provisioningOptions { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                Alerts.error(AppLanguage.text("avd.create.unavailable"), error.localizedDescription)
            case .success(let options):
                guard let selection = self.showCreateForm(
                    images: options.images,
                    devices: options.devices
                ) else { return }
                self.model.createAVD(
                    name: selection.name,
                    imageID: selection.imageID,
                    device: selection.device
                )
            }
        }
    }

    private func showCreateForm(
        images: [SystemImage],
        devices: [String]
    ) -> (name: String, imageID: String, device: String)? {
        guard !images.isEmpty else {
            Alerts.error(AppLanguage.text("avd.create.noImages"), AppLanguage.text("avd.create.installImage"))
            return nil
        }
        guard !devices.isEmpty else {
            Alerts.error(AppLanguage.text("avd.create.noDevices"), AppLanguage.text("avd.create.emptyDevices"))
            return nil
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"

        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 330, height: 24))
        nameField.stringValue = "AVD_\(formatter.string(from: Date()))"

        let devicePopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 330, height: 26), pullsDown: false)
        devicePopup.addItems(withTitles: devices)
        if let index = devices.firstIndex(of: "pixel_7a") {
            devicePopup.selectItem(at: index)
        } else if let index = devices.firstIndex(of: "medium_phone") {
            devicePopup.selectItem(at: index)
        }

        let imagePopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 330, height: 26), pullsDown: false)
        imagePopup.addItems(withTitles: images.map(\.display))

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        let fields: [(String, NSView)] = [
            ("field.name", nameField),
            ("field.device", devicePopup),
            ("field.systemImage", imagePopup)
        ]
        let labels = fields.map { NSTextField(labelWithString: AppLanguage.text($0.0)) }
        let labelWidth = ceil(labels.map { $0.intrinsicContentSize.width }.max() ?? 0)
        for (label, field) in zip(labels, fields) {
            let control = field.1
            label.alignment = .right
            label.widthAnchor.constraint(equalToConstant: labelWidth).isActive = true
            control.widthAnchor.constraint(equalToConstant: 330).isActive = true
            let row = NSStackView(views: [label, control])
            row.orientation = .horizontal
            row.spacing = 8
            stack.addArrangedSubview(row)
        }
        stack.frame = NSRect(x: 0, y: 0, width: max(420, labelWidth + 338), height: 108)

        let alert = NSAlert()
        alert.messageText = AppLanguage.text("avd.create.title")
        alert.informativeText = AppLanguage.text("avd.create.instructions")
        alert.accessoryView = stack
        alert.addButton(withTitle: AppLanguage.text("action.create"))
        alert.addButton(withTitle: AppLanguage.text("action.cancel"))
        alert.window.initialFirstResponder = nameField
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            Alerts.error(AppLanguage.text("avd.create.emptyName"), AppLanguage.text("avd.create.enterName"))
            return nil
        }
        let device = devices[devicePopup.indexOfSelectedItem]
        let image = images[imagePopup.indexOfSelectedItem]
        return (name, image.id, device)
    }

    // MARK: - 信息与复制

    private func showDetails(avd: AVD, device: RunningEmulator?) {
        var lines: [String] = [
            AppLanguage.text("details.name", avd.name),
            AppLanguage.text("details.path", avd.path)
        ]
        if let version = avd.androidVersion {
            lines.append(AppLanguage.text("details.android", version) + (avd.codename.map { " (\($0))" } ?? ""))
        }
        if let api = avd.apiLevel { lines.append(AppLanguage.text("details.api", String(api))) }
        if let abi = avd.abi { lines.append(AppLanguage.text("details.abi", abi)) }
        if let deviceName = avd.deviceName { lines.append(AppLanguage.text("details.device", deviceName)) }
        if let target = avd.target { lines.append(AppLanguage.text("details.target", target)) }
        if let skin = avd.skin { lines.append(AppLanguage.text("details.skin", skin)) }
        if let sdcard = avd.sdcard { lines.append(AppLanguage.text("details.sdcard", sdcard)) }
        if let device {
            lines.append(AppLanguage.text("details.serial", device.serial))
            lines.append(AppLanguage.text("details.status", device.isBooted ? AppLanguage.text("device.booted") : AppLanguage.text("device.starting")))
        } else {
            lines.append(AppLanguage.text("details.stopped"))
        }
        let snapshots = model.snapshotNames(for: avd)
        lines.append(AppLanguage.text("details.snapshots", String(snapshots.count)) + (snapshots.isEmpty ? AppLanguage.text("details.none") : snapshots.joined(separator: ", ")))

        let alert = NSAlert()
        alert.messageText = avd.name
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: AppLanguage.text("action.ok"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func copyLaunchCommand(_ avd: AVD) {
        let emulator = model.tools?.emulator?.path ?? "emulator"
        copyToPasteboard("\(shellQuote(emulator)) -avd \(shellQuote(avd.name))")
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func openDirectory(_ avd: AVD) {
        let url = URL(fileURLWithPath: avd.path)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            Alerts.error(AppLanguage.text("avd.folderMissing.title"), AppLanguage.text("avd.folderMissing.detail", avd.path))
        }
    }

    private func openLog(_ avd: AVD) {
        let url = model.logFileURL(for: avd)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            let directory = AppModel.logDirectory
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(directory)
        }
    }

    // MARK: - 快照

    private func promptSaveSnapshot(avd: AVD, device: RunningEmulator?) {
        guard let device else {
            Alerts.error(AppLanguage.text("snapshot.save.unavailable"), AppLanguage.text("avd.startFirst", avd.name))
            return
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        guard let name = promptText(
            title: AppLanguage.text("snapshot.save.title"),
            message: AppLanguage.text("snapshot.save.namePrompt"),
            defaultValue: "snapshot-\(formatter.string(from: Date()))"
        ) else { return }
        model.saveSnapshot(avd: avd, serial: device.serial, name: name)
    }

    private func promptLoadSnapshot(avd: AVD, device: RunningEmulator?) {
        guard let device else {
            Alerts.error(AppLanguage.text("snapshot.load.unavailable"), AppLanguage.text("avd.startFirst", avd.name))
            return
        }
        let names = model.snapshotNames(for: avd)
        guard !names.isEmpty else {
            Alerts.error(AppLanguage.text("snapshot.empty.title"), AppLanguage.text("snapshot.load.empty", avd.name))
            return
        }
        guard let name = choose(
            title: AppLanguage.text("snapshot.load.title"),
            message: AppLanguage.text("snapshot.load.warning"),
            items: names
        ) else { return }
        guard Alerts.confirmDestructive(
            title: AppLanguage.text("snapshot.load.confirmTitle", name),
            message: AppLanguage.text("snapshot.load.confirmMessage"),
            actionTitle: AppLanguage.text("action.load")
        ) else { return }
        model.loadSnapshot(avd: avd, serial: device.serial, name: name)
    }

    private func promptDeleteSnapshot(avd: AVD, device: RunningEmulator?) {
        let names = model.snapshotNames(for: avd)
        guard !names.isEmpty else {
            Alerts.error(AppLanguage.text("snapshot.empty.title"), AppLanguage.text("snapshot.delete.empty", avd.name))
            return
        }
        guard let name = choose(
            title: AppLanguage.text("snapshot.delete.title"),
            message: AppLanguage.text("snapshot.delete.prompt"),
            items: names
        ) else { return }
        guard Alerts.confirmDestructive(
            title: AppLanguage.text("snapshot.delete.confirmTitle", name),
            message: AppLanguage.text("snapshot.delete.confirmMessage"),
            actionTitle: AppLanguage.text("action.delete")
        ) else { return }
        model.deleteSnapshot(avd: avd, serial: device?.serial, name: name)
    }

    // MARK: - 开发工具

    private enum TerminalCommand {
        case shell
        case logcat
    }

    private func openTerminal(device: RunningEmulator, command: TerminalCommand) {
        guard let adb = model.tools?.adb else {
            Alerts.error(AppLanguage.text("adb.missing.title"), AppLanguage.text("adb.missing.detail"))
            return
        }
        let subcommand = command == .shell ? "shell" : "logcat"
        let line = "\(shellQuote(adb.path)) -s \(shellQuote(device.serial)) \(subcommand)"
        do {
            try TerminalLauncher.open(command: line, identifier: device.serial)
        } catch {
            Alerts.error(AppLanguage.text("terminal.openFailed"), error.localizedDescription)
        }
    }

    private func takeScreenshot(device: RunningEmulator, avd: AVD?) {
        model.screenshot(device: device, avd: avd) { result in
            switch result {
            case .success(let url):
                NSWorkspace.shared.open(url)
            case .failure(let error):
                Alerts.error(AppLanguage.text("screenshot.failed"), error.localizedDescription)
            }
        }
    }

    private func openAndroidStudio() {
        let bundleID = "com.google.android.studio"
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(
                at: url,
                configuration: NSWorkspace.OpenConfiguration()
            ) { _, error in
                if let error {
                    DispatchQueue.main.async {
                        Alerts.error(AppLanguage.text("studio.openFailed"), error.localizedDescription)
                    }
                }
            }
        } else {
            Alerts.error(
                AppLanguage.text("studio.notFound"),
                AppLanguage.text("studio.bundleNotFound")
            )
        }
    }

    // MARK: - 输入对话框

    private func promptText(title: String, message: String, defaultValue: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: AppLanguage.text("action.confirm"))
        alert.addButton(withTitle: AppLanguage.text("action.cancel"))

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = defaultValue
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            Alerts.error(AppLanguage.text("prompt.inputRequired"), AppLanguage.text("prompt.enterValue"))
            return nil
        }
        return value
    }

    private func choose(title: String, message: String, items: [String]) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: AppLanguage.text("action.confirm"))
        alert.addButton(withTitle: AppLanguage.text("action.cancel"))

        let popup = NSPopUpButton(
            frame: NSRect(x: 0, y: 0, width: 320, height: 26),
            pullsDown: false
        )
        popup.addItems(withTitles: items)
        alert.accessoryView = popup
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let index = popup.indexOfSelectedItem
        guard items.indices.contains(index) else { return nil }
        return items[index]
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private enum TerminalLauncher {
    static func open(command: String, identifier: String) throws {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AVDMenuBar/scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeName = identifier.map { character -> Character in
            character.isLetter || character.isNumber || character == "." || character == "-" || character == "_"
                ? character
                : "_"
        }
        let url = directory.appendingPathComponent("adb-\(String(safeName)).command")
        try "#!/bin/zsh\n\(command)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
        guard NSWorkspace.shared.open(url) else {
            throw NSError(
                domain: "AVDMenuBar",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: AppLanguage.text("terminal.handlerMissing")]
            )
        }
    }
}
