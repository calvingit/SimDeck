import SwiftUI
import AVDCore

struct MainView: View {
    @ObservedObject var model: AppModel
    let actions: PanelActions

    @Environment(\.colorScheme) private var colorScheme
    @State private var touchStartDate: Date?

    private var selected: DeviceEntry? {
        let entries = model.deviceEntries
        return entries.first { $0.id == model.selectedDeviceID }
            ?? entries.first { $0.status == .running }
            ?? entries.first { $0.status == .starting }
            ?? entries.first
    }

    private var selectedRunning: RunningEmulator? { selected?.device }
    private var previewSerial: String? { selectedRunning?.serial }
    private var previewSimulator: SimulatorDevice? { selected?.simulator }

    var body: some View {
        HStack(spacing: 0) {
            leftList.frame(width: 224)
            Divider()
            VStack(spacing: 0) {
                if let entry = selected {
                    workspaceHeader(entry)
                    Divider()
                }
                previewArea
                    .padding(14)
                Divider()
                bottomBar
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 740, minHeight: 480)
        .onAppear {
            updatePreview()
            model.setPreviewVisible(true)
        }
        .onDisappear { model.setPreviewVisible(false) }
        .onChange(of: selected?.id) { _, _ in updatePreview() }
        .onChange(of: selectedRunning) { _, _ in updatePreview() }
        // iOS 设备没有 RunningEmulator，状态流转（Booting→Booted 等）靠状态标题变化触发。
        .onChange(of: selected?.statusTitle) { _, _ in updatePreview() }
    }

    private func updatePreview() {
        touchStartDate = nil
        model.setPreviewTarget(
            serial: previewSerial,
            avdName: selected?.avd?.name ?? selectedRunning?.avdName,
            booted: selectedRunning?.isBooted == true || previewSimulator?.isBooted == true,
            isRealDevice: selectedRunning?.isRealDevice == true,
            simulator: previewSimulator
        )
    }

    private var leftList: some View {
        VStack(spacing: 0) {
            HStack {
                Text(AppLanguage.text("field.device")).font(.headline)
                Spacer()
                Text(model.deviceEntries.count.formatted())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            Divider()
            if model.deviceEntries.isEmpty {
                Text(model.isRefreshing ? AppLanguage.text("device.loading") : AppLanguage.text("device.empty"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: Binding(
                    get: { selected?.id },
                    set: { model.selectedDeviceID = $0 }
                )) {
                    DeviceGroups(entries: model.deviceEntries) { entry in
                        DeviceIdentity(entry: entry)
                            .padding(.vertical, 3)
                            .tag(entry.id)
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

    private var previewArea: some View {
        GeometryReader { geo in
            let fitRect = displayedFrameSize.map { aspectFitRect(contentSize: $0, container: geo.size) }
            ZStack {
                if let fitRect {
                    Group {
                        if let cgImage = model.previewFrame {
                            Image(decorative: cgImage, scale: 1.0)
                                .resizable()
                        } else if let nsImage = model.previewImage {
                            Image(nsImage: nsImage)
                                .resizable()
                        }
                    }
                    .frame(width: fitRect.width, height: fitRect.height)
                    .position(x: fitRect.midX, y: fitRect.midY)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "desktopcomputer")
                            .font(.system(size: 30))
                            .foregroundStyle(.secondary)
                        Text(previewMessage)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                if fitRect != nil && (previewSerial != nil || previewSimulator != nil) {
                    let badge = pipelineBadge
                    VStack {
                        HStack {
                            Label(badge.text, systemImage: "dot.radiowave.left.and.right")
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .foregroundStyle(badge.color)
                                .background(.regularMaterial, in: Capsule())
                            Spacer()
                        }
                        Spacer()
                    }
                    .padding(8)
                    .allowsHitTesting(false)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .background(Color(white: colorScheme == .dark ? 0.16 : 0.86), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if touchStartDate == nil {
                            touchStartDate = Date()
                        }
                    }
                    .onEnded { value in
                        defer { touchStartDate = nil }
                        guard let fitRect else { return }
                        let elapsedMs = max(
                            100,
                            Int(Date().timeIntervalSince(touchStartDate ?? value.time) * 1000)
                        )
                        handleTouch(value: value, elapsedMs: elapsedMs, fitRect: fitRect)
                    }
            )
            // 双指捏合（触控板）→ baguette pinch；仅 iOS 增强档在 handleIOSPinch 内生效。
            .simultaneousGesture(
                MagnifyGesture()
                    .onEnded { value in handleIOSPinch(magnification: value.magnification) }
            )
        }
    }

    private var pipelineBadge: (text: String, color: Color) {
        switch model.previewPipeline {
        case .adbStream: return (AppLanguage.text("preview.liveBadge"), .green)
        case .polling: return (AppLanguage.text("preview.pollingBadge"), .orange)
        case .iosStream: return (AppLanguage.text("ios.preview.liveBadge"), .green)
        case .iosPolling: return (AppLanguage.text("preview.pollingBadge"), .orange)
        }
    }

    private var displayedFrameSize: CGSize? {
        if let frame = model.previewFrame {
            return CGSize(width: frame.width, height: frame.height)
        }
        if let image = model.previewImage {
            return image.size
        }
        return nil
    }

    private func aspectFitRect(contentSize: CGSize, container: CGSize) -> CGRect {
        let inset: CGFloat = 12
        let availableWidth = max(0, container.width - inset * 2)
        let availableHeight = max(0, container.height - inset * 2)
        guard contentSize.width > 0, contentSize.height > 0,
              availableWidth > 0, availableHeight > 0 else { return .zero }
        let scale = min(availableWidth / contentSize.width, availableHeight / contentSize.height)
        let width = contentSize.width * scale
        let height = contentSize.height * scale
        return CGRect(
            x: (container.width - width) / 2,
            y: (container.height - height) / 2,
            width: width,
            height: height
        )
    }

    /// 把预览上的点击/拖拽位置映射为设备分辨率坐标。
    /// 捕获帧包含模拟器窗口标题栏：按帧宽高比与设备分辨率宽高比之差，
    /// 推算顶部标题栏高度并裁掉。
    private func mappedPoint(
        _ point: CGPoint,
        fitRect: CGRect,
        frame: CGSize,
        resolution: CGSize
    ) -> CGPoint? {
        guard frame.width > 0, frame.height > 0,
              fitRect.width > 0, fitRect.height > 0 else { return nil }

        let imageX = (point.x - fitRect.minX) / fitRect.width * frame.width
        let imageY = (point.y - fitRect.minY) / fitRect.height * frame.height
        guard imageX >= 0, imageY >= 0, imageX <= frame.width, imageY <= frame.height else {
            return nil
        }

        let contentHeight = frame.width * resolution.height / resolution.width
        let extraHeight = max(0, frame.height - contentHeight)
        guard imageY >= extraHeight else { return nil }

        let x = imageX / frame.width * resolution.width
        let y = (imageY - extraHeight) / contentHeight * resolution.height
        guard x >= 0, y >= 0, x <= resolution.width, y <= resolution.height else {
            return nil
        }
        return CGPoint(x: x, y: y)
    }

    private func handleTouch(value: DragGesture.Value, elapsedMs: Int, fitRect: CGRect) {
        if selected?.platform == .iosSimulator {
            handleIOSTouch(value: value, elapsedMs: elapsedMs, fitRect: fitRect)
            return
        }
        guard let running = selectedRunning, running.isBooted,
              let frameSize = displayedFrameSize,
              let resolution = model.deviceResolution else {
            return
        }
        guard let start = mappedPoint(
            value.startLocation,
            fitRect: fitRect,
            frame: frameSize,
            resolution: resolution
        ), let end = mappedPoint(
            value.location,
            fitRect: fitRect,
            frame: frameSize,
            resolution: resolution
        ) else {
            return
        }

        let dx = end.x - start.x
        let dy = end.y - start.y
        let distance = sqrt(dx * dx + dy * dy)

        if distance < Double(resolution.width) * 0.01 {
            if elapsedMs >= 500 {
                // 长按：原地 swipe 带时长
                actions.sendSwipe(
                    running,
                    Int(start.x), Int(start.y),
                    Int(start.x), Int(start.y),
                    800
                )
            } else {
                actions.sendTap(running, Int(end.x), Int(end.y))
            }
        } else {
            actions.sendSwipe(
                running,
                Int(start.x), Int(start.y),
                Int(end.x), Int(end.y),
                elapsedMs
            )
        }
    }

    /// iOS 触摸映射：baguette 帧与 simctl 截图都只含屏幕内容（无 Android 捕获的窗口标题栏），
    /// 预览位置按比例线性映射到 device points；手势编码由 AVDCore 的 IOSGesture 完成。
    private func handleIOSTouch(value: DragGesture.Value, elapsedMs: Int, fitRect: CGRect) {
        guard let simulator = selected?.simulator, simulator.isBooted,
              model.isEnhancedTierAvailable,
              let screen = model.iosScreenPoints[simulator.udid] else {
            return
        }
        guard let start = mappedIOSPoint(value.startLocation, fitRect: fitRect, screen: screen),
              let end = mappedIOSPoint(value.location, fitRect: fitRect, screen: screen) else {
            return
        }
        let dx = end.x - start.x
        let dy = end.y - start.y
        let distance = sqrt(dx * dx + dy * dy)

        if distance < screen.width * 0.01 {
            // 长按用 tap 的持续按压表达（wire duration 单位秒）；短按走默认 50ms。
            let duration: Double = elapsedMs >= 500 ? 0.8 : 0.05
            actions.sendIOSGesture(simulator, .tap(
                x: Int(end.x), y: Int(end.y),
                width: Int(screen.width), height: Int(screen.height),
                duration: duration
            ))
        } else {
            actions.sendIOSGesture(simulator, .swipe(
                startX: Int(start.x), startY: Int(start.y),
                endX: Int(end.x), endY: Int(end.y),
                width: Int(screen.width), height: Int(screen.height),
                duration: Double(elapsedMs) / 1000
            ))
        }
    }

    /// 触控板捏合（双指）→ baguette 双指 pinch：中心取屏幕中心，起始间距 120pt，
    /// 结束间距按缩放比例换算并夹在屏幕可表达范围内。
    private func handleIOSPinch(magnification: CGFloat) {
        guard selected?.platform == .iosSimulator,
              let simulator = selected?.simulator, simulator.isBooted,
              model.isEnhancedTierAvailable,
              let screen = model.iosScreenPoints[simulator.udid] else {
            return
        }
        let base: CGFloat = 120
        let endSpread = min(max(base * magnification, 20), max(screen.width, screen.height))
        actions.sendIOSGesture(simulator, .pinch(
            cx: Int(screen.width / 2), cy: Int(screen.height / 2),
            startSpread: Int(base), endSpread: Int(endSpread),
            width: Int(screen.width), height: Int(screen.height)
        ))
    }

    private func mappedIOSPoint(_ point: CGPoint, fitRect: CGRect, screen: CGSize) -> CGPoint? {
        guard fitRect.width > 0, fitRect.height > 0 else { return nil }
        let x = (point.x - fitRect.minX) / fitRect.width * screen.width
        let y = (point.y - fitRect.minY) / fitRect.height * screen.height
        guard x >= 0, y >= 0, x <= screen.width, y <= screen.height else { return nil }
        return CGPoint(x: x, y: y)
    }

    @ViewBuilder
    private var bottomBar: some View {
        if selected?.platform == .iosSimulator {
            iosBottomBar
        } else {
            HStack(spacing: 14) {
                keyButton(AppLanguage.text("key.back"), icon: "arrow.uturn.backward", code: 4)
                keyButton(AppLanguage.text("key.home"), icon: "house", code: 3)
                keyButton(AppLanguage.text("key.recents"), icon: "square.stack.3d.up", code: 187)
                Divider()
                    .frame(height: 26)
                keyButton(AppLanguage.text("key.power"), icon: "power", code: 26)
                keyButton(AppLanguage.text("key.volumeUp"), icon: "speaker.wave.2", code: 24)
                keyButton(AppLanguage.text("key.volumeDown"), icon: "speaker.wave.1", code: 25)
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
        }
    }

    /// iOS 按键条：增强档显示 Home/Lock/音量（baguette button press）；
    /// 基础档没有 baguette，隐藏输入控件并说明原因。检测到 Device Hub 影子时先提示修复。
    @ViewBuilder
    private var iosBottomBar: some View {
        VStack(spacing: 0) {
            if let simulator = selected?.simulator,
               model.shadowedUDIDs.contains(simulator.udid),
               selected?.status == .running {
                shadowBanner(simulator)
            }
            if model.isEnhancedTierAvailable {
                HStack(spacing: 14) {
                    iosKeyButton(AppLanguage.text("ios.key.home"), icon: "house", key: .home)
                    iosKeyButton(AppLanguage.text("ios.key.lock"), icon: "lock", key: .lock)
                    Divider()
                        .frame(height: 26)
                    iosKeyButton(AppLanguage.text("ios.key.volumeUp"), icon: "speaker.wave.2", key: .volumeUp)
                    iosKeyButton(AppLanguage.text("ios.key.volumeDown"), icon: "speaker.wave.1", key: .volumeDown)
                }
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
            } else {
                Text(AppLanguage.text("ios.input.basicTierNotice"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func shadowBanner(_ simulator: SimulatorDevice) -> some View {
        HStack(spacing: 10) {
            Label(AppLanguage.text("ios.shadow.banner"), systemImage: "exclamationmark.triangle")
                .font(.callout)
            Spacer(minLength: 8)
            Button(AppLanguage.text("ios.shadow.action")) {
                actions.healSimulator(simulator)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 14)
        .padding(.top, 10)
    }

    private func iosKeyButton(_ title: String, icon: String, key: IOSKey) -> some View {
        Button {
            if let simulator = selected?.simulator {
                actions.sendIOSGesture(simulator, .key(key))
            }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                Text(title)
                    .font(.system(size: 10))
            }
            .frame(width: 56)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(selected?.simulator?.isBooted != true)
        .help(title)
    }

    private func keyButton(_ title: String, icon: String, code: Int) -> some View {
        Button {
            guard let running = selectedRunning else { return }
            actions.sendKey(running, code)
        } label: {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                Text(title)
                    .font(.system(size: 10))
            }
            .frame(width: 56)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(selectedRunning?.isBooted != true)
        .help(title)
    }

    private var previewMessage: String {
        guard let selected else { return AppLanguage.text("preview.selectDevice") }
        if selected.platform == .iosSimulator {
            if selected.status == .stopped { return AppLanguage.text("ios.preview.startFirst") }
            return model.previewStatus ?? AppLanguage.text("preview.connecting")
        }
        if selected.status == .starting { return AppLanguage.text("preview.starting") }
        if selected.status == .stopped { return AppLanguage.text("preview.startAVD") }
        if selectedRunning?.isBooted != true { return AppLanguage.text("preview.waitingForDevice") }
        return model.previewStatus ?? AppLanguage.text("preview.connecting")
    }

    // MARK: - 设备操作

    private func workspaceHeader(_ entry: DeviceEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.name).font(.title2.weight(.semibold))
                        .lineLimit(1).truncationMode(.middle).help(entry.name)
                    HStack(spacing: 8) {
                        Text(entry.metadata).foregroundStyle(.secondary)
                        Label(entry.statusTitle, systemImage: "circle.fill")
                            .foregroundStyle(entry.statusColor)
                    }
                    .font(.caption)
                }
                Spacer(minLength: 8)
                primaryActions(entry)
            }
            HStack(spacing: 8) {
                if entry.platform == .iosSimulator {
                    if let simulator = entry.simulator {
                        iosManagementMenu(simulator)
                    }
                } else {
                    developerMenu(entry)
                    if let avd = entry.avd {
                        snapshotMenu(avd, entry.device)
                        managementMenu(avd, entry.device)
                    }
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func primaryActions(_ entry: DeviceEntry) -> some View {
        if entry.platform == .iosSimulator, let simulator = entry.simulator {
            if model.busySimulators.contains(simulator.udid) {
                ProgressView().controlSize(.small)
            } else if entry.status == .starting {
                ProgressView().controlSize(.small).accessibilityLabel(AppLanguage.text("device.starting"))
            } else if entry.status == .running {
                Button(AppLanguage.text("action.restart")) { actions.rebootSimulator(simulator) }
                Button(AppLanguage.text("action.shutdown")) { actions.shutdownSimulator(simulator) }
            } else {
                Button {
                    actions.bootSimulator(simulator)
                } label: {
                    Label(AppLanguage.text("action.start"), systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!simulator.isAvailable)
            }
        } else if let avd = entry.avd {
            if entry.status == .starting {
                ProgressView().controlSize(.small).accessibilityLabel(AppLanguage.text("device.starting"))
                Button(AppLanguage.text("action.cancelStart")) {
                    if let device = entry.device {
                        actions.shutdown(device, avd)
                    } else {
                        actions.cancelStart(avd)
                    }
                }
            } else if let device = entry.device {
                Button(AppLanguage.text("action.restart")) { actions.softReboot(device, avd) }
                Button(AppLanguage.text("action.shutdown")) { actions.shutdown(device, avd) }
            } else {
                Button {
                    actions.start(avd)
                } label: {
                    Label(AppLanguage.text("action.start"), systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
            }
        } else if let device = entry.device, device.isRealDevice {
            Button(AppLanguage.text("action.softReboot")) { actions.softReboot(device, nil) }
                .disabled(!device.isBooted)
        }
    }

    private func developerMenu(_ entry: DeviceEntry) -> some View {
        Menu {
            Button(AppLanguage.text("action.screenshot")) {
                if let device = entry.device { actions.screenshot(device, entry.avd) }
            }
            .disabled(entry.device == nil || (entry.device?.isRealDevice == true && entry.device?.isBooted == false))
            Button(AppLanguage.text("action.adbShell")) {
                if let device = entry.device { actions.openShell(device, entry.avd) }
            }
            .disabled(entry.device == nil)
            Button("Logcat") {
                if let device = entry.device { actions.openLogcat(device, entry.avd) }
            }
            .disabled(entry.device == nil)
            if entry.avd != nil {
                Divider()
                Button(AppLanguage.text("action.openStudio"), action: actions.openStudio)
            }
        } label: {
            Label(AppLanguage.text("menu.developerTools"), systemImage: "terminal")
        }
    }

    private func iosManagementMenu(_ simulator: SimulatorDevice) -> some View {
        Menu {
            Button(AppLanguage.text("action.screenshot")) { actions.screenshotSimulator(simulator) }
                .disabled(!simulator.isBooted)
            Button(AppLanguage.text("ios.menu.installApp")) { actions.installAppSimulator(simulator) }
                .disabled(!simulator.isBooted)
            Divider()
            Button(AppLanguage.text("ios.menu.launchApp")) { actions.launchAppSimulator(simulator) }
                .disabled(!simulator.isBooted)
            Button(AppLanguage.text("ios.menu.terminateApp")) { actions.terminateAppSimulator(simulator) }
                .disabled(!simulator.isBooted)
            Button(AppLanguage.text("ios.menu.openURL")) { actions.openURLSimulator(simulator) }
                .disabled(!simulator.isBooted)
            Divider()
            // 日志走 `simctl spawn`，要求设备已启动。
            Button(AppLanguage.text("ios.menu.logs")) { actions.openSimulatorLog(simulator) }
                .disabled(!simulator.isBooted)
            Button(AppLanguage.text("ios.menu.rename")) { actions.renameSimulator(simulator) }
            Divider()
            // erase/delete 运行中可用（erase 由服务层先关机），无需先停用。
            Button(AppLanguage.text("ios.menu.erase"), role: .destructive) { actions.eraseSimulator(simulator) }
            Button(AppLanguage.text("ios.menu.delete"), role: .destructive) { actions.deleteSimulator(simulator) }
        } label: {
            Label(AppLanguage.text("menu.manage"), systemImage: "gearshape")
        }
    }

    private func snapshotMenu(_ avd: AVD, _ device: RunningEmulator?) -> some View {
        Menu {
            Button(AppLanguage.text("menu.saveSnapshot")) { actions.saveSnapshot(avd, device) }
                .disabled(device == nil)
            Button(AppLanguage.text("menu.loadSnapshot")) { actions.loadSnapshot(avd, device) }
                .disabled(device == nil)
            Divider()
            Button(AppLanguage.text("menu.deleteSnapshot"), role: .destructive) { actions.deleteSnapshot(avd, device) }
        } label: {
            Label(AppLanguage.text("menu.snapshots"), systemImage: "camera.on.rectangle")
        }
    }

    private func managementMenu(_ avd: AVD, _ device: RunningEmulator?) -> some View {
        Menu {
            Button(AppLanguage.text("action.coldBoot")) { actions.coldBoot(avd, device) }
                .disabled(model.isStarting(avd.name) || device?.isBooted == false)
            Divider()
            Button(AppLanguage.text("menu.avdDetails")) { actions.details(avd, device) }
            Button(AppLanguage.text("action.openAVDFolder")) { actions.openDirectory(avd) }
            Button(AppLanguage.text("action.openEmulatorLog")) { actions.openLog(avd) }
            Button(model.isPinned(avd) ? AppLanguage.text("action.unpin") : AppLanguage.text("action.pin")) { actions.togglePinned(avd) }
            Menu(AppLanguage.text("menu.copyDeviceInfo")) {
                Button(AppLanguage.text("menu.copyAVDName")) { actions.copyName(avd) }
                Button(AppLanguage.text("menu.copyAVDPath")) { actions.copyPath(avd) }
                Button(AppLanguage.text("menu.copyLaunchCommand")) { actions.copyCommand(avd) }
            }
            Divider()
            Button(AppLanguage.text("menu.renameAVD")) { actions.rename(avd, device) }
            Button(AppLanguage.text("menu.moveAVD")) { actions.move(avd, device) }
            Divider()
            Button(AppLanguage.text("menu.wipeData"), role: .destructive) { actions.wipe(avd, device) }
            Button(AppLanguage.text("menu.deleteAVD"), role: .destructive) { actions.delete(avd, device) }
        } label: {
            Label(AppLanguage.text("menu.manage"), systemImage: "gearshape")
        }
    }
}
