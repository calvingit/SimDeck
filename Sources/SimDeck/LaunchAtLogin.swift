import ServiceManagement

enum LaunchAtLogin {
    /// 已注册（包括等待系统批准）视为开启，避免开关与系统实际状态来回跳。
    static var isEnabled: Bool {
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }

    static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static func setEnabled(_ enabled: Bool) throws {
        let status = SMAppService.mainApp.status
        if enabled {
            if status == .enabled || status == .requiresApproval { return }
            try SMAppService.mainApp.register()
        } else {
            if status == .enabled || status == .requiresApproval {
                try SMAppService.mainApp.unregister()
            }
        }
    }
}
