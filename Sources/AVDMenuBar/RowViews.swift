import SwiftUI
import AVDCore

struct DeviceEntry: Identifiable {
    enum ID: Hashable {
        case avd(String)
        case connected(String)
        case iosSimulator(String)
    }

    enum Platform: Hashable {
        case android
        case iosSimulator
    }

    enum Status: CaseIterable {
        case running, starting, stopped

        var title: String {
            switch self {
            case .running: return AppLanguage.text("device.running")
            case .starting: return AppLanguage.text("device.starting")
            case .stopped: return AppLanguage.text("device.stopped")
            }
        }

        var color: Color {
            switch self {
            case .running: return .green
            case .starting: return .orange
            case .stopped: return .secondary
            }
        }
    }

    let avd: AVD?
    let device: RunningEmulator?
    let simulator: SimulatorDevice?
    let props: DeviceProps?
    let isPinned: Bool
    let status: Status
    let platform: Platform

    init(
        avd: AVD? = nil,
        device: RunningEmulator? = nil,
        simulator: SimulatorDevice? = nil,
        props: DeviceProps? = nil,
        isPinned: Bool,
        status: Status,
        platform: Platform = .android
    ) {
        self.avd = avd
        self.device = device
        self.simulator = simulator
        self.props = props
        self.isPinned = isPinned
        self.status = status
        self.platform = platform
    }

    var id: ID {
        switch platform {
        case .iosSimulator:
            return .iosSimulator(simulator?.udid ?? "")
        case .android:
            if let avd { return .avd(avd.name) }
            return .connected(device!.serial)
        }
    }

    var name: String { avd?.name ?? simulator?.name ?? props?.model ?? device!.displayName }
    var statusTitle: String {
        switch platform {
        case .iosSimulator:
            guard let simulator else { return status.title }
            if !simulator.isAvailable { return AppLanguage.text("ios.unavailable") }
            switch simulator.state {
            case "Booted": return AppLanguage.text("device.running")
            case "Shutdown": return AppLanguage.text("device.stopped")
            case "Booting", "Creating", "Shutting Down": return AppLanguage.text("device.starting")
            default: return simulator.state
            }
        case .android:
            if device?.isRealDevice == true {
                return device?.isBooted == true ? AppLanguage.text("device.connected") : AppLanguage.text("device.notReady")
            }
            return status.title
        }
    }
    var statusColor: Color {
        switch platform {
        case .iosSimulator:
            return status.color
        case .android:
            return device?.isBooted == false ? .orange : status.color
        }
    }

    var metadata: String {
        switch platform {
        case .iosSimulator:
            guard let simulator else { return "" }
            return ["iOS \(simulator.runtimeVersion)", simulator.deviceTypeName]
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
        case .android:
            let type = device?.isRealDevice == true ? AppLanguage.text("device.physical") : "AVD"
            let version = avd?.androidVersion ?? props?.androidVersion
            let api = avd?.apiLevel ?? props?.apiLevel
            return ([type] + [version.map { "Android \($0)" }, api.map { "API \($0)" }]
                .compactMap { $0 }).joined(separator: " · ")
        }
    }

    /// iOS 状态原文 → 面板分组；未知状态按未运行分组，标题原样展示。
    static func status(forSimulator simulator: SimulatorDevice) -> Status {
        switch simulator.state {
        case "Booted": return .running
        case "Booting", "Creating", "Shutting Down": return .starting
        default: return .stopped
        }
    }
}

extension AppModel {
    var deviceEntries: [DeviceEntry] {
        let byName = runningByAVD
        let known = pinnedFirst(avds).map { avd in
            let device = byName[avd.name]
            let status: DeviceEntry.Status
            if isStarting(avd.name) || device?.isBooted == false {
                status = .starting
            } else {
                status = device == nil ? .stopped : .running
            }
            return DeviceEntry(avd: avd, device: device, props: nil,
                               isPinned: isPinned(avd), status: status)
        }
        let knownSerials = Set(known.compactMap { $0.device?.serial })
        let androidEntries = known + sortedRunning.filter { !knownSerials.contains($0.serial) }.map { device in
            DeviceEntry(avd: nil, device: device, props: deviceProps[device.serial], isPinned: false,
                        status: !device.isRealDevice && !device.isBooted ? .starting : .running)
        }
        let iosEntries = simulators.map { simulator in
            DeviceEntry(simulator: simulator,
                        isPinned: false,
                        status: DeviceEntry.status(forSimulator: simulator),
                        platform: .iosSimulator)
        }
        return androidEntries + iosEntries
    }
}

struct DeviceIdentity: View {
    let entry: DeviceEntry

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(entry.statusColor)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(entry.name)
                        .fontWeight(.medium)
                        .truncationMode(.middle)
                    if entry.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(AppLanguage.text("device.pinned"))
                    }
                }
                Text(entry.metadata)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("\(entry.name) · \(entry.statusTitle)")
        .accessibilityElement(children: .combine)
        .accessibilityValue(entry.statusTitle)
    }
}

struct DeviceGroups<Row: View>: View {
    let entries: [DeviceEntry]
    @ViewBuilder let row: (DeviceEntry) -> Row

    var body: some View {
        ForEach(DeviceEntry.Status.allCases, id: \.self) { status in
            let group = entries.filter { $0.status == status }
            if !group.isEmpty {
                Section {
                    ForEach(group, content: row)
                } header: {
                    Text("\(status.title) · \(group.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)
                }
            }
        }
    }
}
