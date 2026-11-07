import SwiftUI
import AVDCore

struct AVDPanelView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var pinned: PanelState
    let actions: PanelActions

    @State private var explicitPlatform: DeviceEntry.Platform?

    /// 当前平台标签：未手动选择时按设备情况给默认值（只有 iOS 模拟器时落在 iOS）。
    private var activePlatform: DeviceEntry.Platform {
        explicitPlatform ?? .initialSelection(for: model.deviceEntries)
    }

    private var platformBinding: Binding<DeviceEntry.Platform> {
        Binding(
            get: { activePlatform },
            set: { explicitPlatform = $0 }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 390, height: 420)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "iphone")
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(AppLanguage.text("panel.title"))
                    .font(.system(size: 15, weight: .semibold))
                Text(headerSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: actions.togglePin) {
                Image(systemName: pinned.isPinned ? "pin.fill" : "pin")
            }
            .buttonStyle(.borderless)
            .help(pinned.isPinned ? AppLanguage.text("panel.unpin") : AppLanguage.text("panel.pin"))
            .accessibilityLabel(pinned.isPinned ? AppLanguage.text("panel.unpin") : AppLanguage.text("panel.pin"))

            Button(action: actions.refresh) {
                if model.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .disabled(model.isRefreshing)
            .help(AppLanguage.text("action.refresh"))
            .accessibilityLabel(AppLanguage.text("action.refresh"))

            Button(action: actions.settings) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help(AppLanguage.text("action.settings"))
            .accessibilityLabel(AppLanguage.text("action.settings"))
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 9)
    }

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                if model.listError != nil || model.runtimeError != nil {
                    VStack(spacing: 6) {
                        if model.listError != nil {
                            ErrorBanner(
                                title: AppLanguage.text("panel.avdListError"),
                                detail: model.listError ?? "",
                                actionTitle: AppLanguage.text("action.settings"),
                                action: actions.settings
                            )
                        }
                        if model.runtimeError != nil {
                            ErrorBanner(
                                title: AppLanguage.text("panel.runningStateError"),
                                detail: model.runtimeError ?? "",
                                actionTitle: AppLanguage.text("action.refresh"),
                                action: actions.refresh
                            )
                        }
                        if model.iosError != nil {
                            ErrorBanner(
                                title: AppLanguage.text("panel.iosError"),
                                detail: model.iosError ?? "",
                                actionTitle: AppLanguage.text("action.refresh"),
                                action: actions.refresh
                            )
                        }
                    }
                    .padding(.bottom, 4)
                }
                DevicePlatformPicker(entries: model.deviceEntries, selection: platformBinding)
                    .padding(.bottom, 2)
                let entries = model.deviceEntries.filter { $0.platform == activePlatform }
                DeviceGroups(entries: entries) { entry in
                    HStack(spacing: 8) {
                        Button {
                            actions.selectDevice(entry.id)
                        } label: {
                            DeviceIdentity(entry: entry)
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        quickActions(entry)
                    }
                    .padding(.horizontal, 4)
                }

                if entries.isEmpty && model.listError == nil && model.runtimeError == nil && model.iosError == nil {
                    if model.isRefreshing {
                        Text(AppLanguage.text("device.loading"))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 30)
                    } else {
                        emptyState
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func quickActions(_ entry: DeviceEntry) -> some View {
        if let avd = entry.avd {
            Group {
                if entry.status == .starting {
                    ProgressView().controlSize(.small).accessibilityLabel(AppLanguage.text("device.starting"))
                    Button(AppLanguage.text("action.cancel")) {
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
                    Button(AppLanguage.text("action.start")) { actions.start(avd) }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()
        } else if entry.platform == .iosSimulator, let simulator = entry.simulator {
            Group {
                if model.busySimulators.contains(simulator.udid) || entry.status == .starting {
                    ProgressView().controlSize(.small).accessibilityLabel(AppLanguage.text("device.starting"))
                } else if entry.status == .running {
                    Button(AppLanguage.text("action.restart")) { actions.rebootSimulator(simulator) }
                    Button(AppLanguage.text("action.shutdown")) { actions.shutdownSimulator(simulator) }
                } else {
                    Button(AppLanguage.text("action.start")) { actions.bootSimulator(simulator) }
                        .disabled(!simulator.isAvailable)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()
        }
    }

    private var headerSubtitle: String {
        let entries = model.deviceEntries
        let android = entries.filter { $0.platform == .android }
        let real = android.filter { $0.device?.isRealDevice == true }.count
        let avds = android.count - real
        let running = entries.filter { $0.status == .running }.count
        let iosCount = entries.filter { $0.platform == .iosSimulator }.count
        return AppLanguage.text("panel.deviceCounts", String(running), String(avds))
            + (real > 0 ? AppLanguage.text("panel.physicalCount", String(real)) : "")
            + (iosCount > 0 ? AppLanguage.text("panel.iosCount", String(iosCount)) : "")
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()

            Button(action: actions.openMain) {
                Label(AppLanguage.text("action.openMainWindow"), systemImage: "macwindow.on.rectangle")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .help(AppLanguage.text("panel.openMainHelp"))

            Button(AppLanguage.text("action.quit")) {
                actions.quit()
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "iphone.slash")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text(AppLanguage.text("device.empty"))
                .font(.headline)
            Text(AppLanguage.text("panel.emptyHelp"))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button(AppLanguage.text("action.refresh"), action: actions.refresh)
                Button(AppLanguage.text("menu.settings"), action: actions.settings)
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }
}

private struct ErrorBanner: View {
    let title: String
    let detail: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help(detail)
            }
            Spacer(minLength: 4)
            Button(actionTitle, action: action)
                .buttonStyle(.borderless)
                .controlSize(.small)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.orange.opacity(0.1)))
    }
}
