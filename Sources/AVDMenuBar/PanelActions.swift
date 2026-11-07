import AVDCore

struct PanelActions {
    var start: (AVD) -> Void
    var shutdown: (RunningEmulator, AVD?) -> Void
    var cancelStart: (AVD) -> Void
    var softReboot: (RunningEmulator, AVD?) -> Void
    var coldBoot: (AVD, RunningEmulator?) -> Void
    var wipe: (AVD, RunningEmulator?) -> Void
    var delete: (AVD, RunningEmulator?) -> Void
    var togglePinned: (AVD) -> Void
    var rename: (AVD, RunningEmulator?) -> Void
    var move: (AVD, RunningEmulator?) -> Void
    var create: () -> Void
    var refresh: () -> Void
    var settings: () -> Void
    var togglePin: () -> Void
    var quit: () -> Void
    var copyName: (AVD) -> Void
    var copyPath: (AVD) -> Void
    var copyCommand: (AVD) -> Void
    var openDirectory: (AVD) -> Void
    var openLog: (AVD) -> Void
    var details: (AVD, RunningEmulator?) -> Void
    var saveSnapshot: (AVD, RunningEmulator?) -> Void
    var loadSnapshot: (AVD, RunningEmulator?) -> Void
    var deleteSnapshot: (AVD, RunningEmulator?) -> Void
    var openShell: (RunningEmulator, AVD?) -> Void
    var openLogcat: (RunningEmulator, AVD?) -> Void
    var screenshot: (RunningEmulator, AVD?) -> Void
    var openStudio: () -> Void
    var selectDevice: (DeviceEntry.ID) -> Void
    var openMain: () -> Void
    var sendKey: (RunningEmulator, Int) -> Void
    var sendTap: (RunningEmulator, Int, Int) -> Void
    var sendSwipe: (RunningEmulator, Int, Int, Int, Int, Int) -> Void
    var bootSimulator: (SimulatorDevice) -> Void
    var shutdownSimulator: (SimulatorDevice) -> Void
    var rebootSimulator: (SimulatorDevice) -> Void
    var eraseSimulator: (SimulatorDevice) -> Void
    var deleteSimulator: (SimulatorDevice) -> Void
    var renameSimulator: (SimulatorDevice) -> Void
    var createSimulator: () -> Void
    var screenshotSimulator: (SimulatorDevice) -> Void
    var sendIOSGesture: (SimulatorDevice, IOSGesture) -> Void
    var healSimulator: (SimulatorDevice) -> Void
    var installAppSimulator: (SimulatorDevice) -> Void
    var launchAppSimulator: (SimulatorDevice) -> Void
    var terminateAppSimulator: (SimulatorDevice) -> Void
    var openURLSimulator: (SimulatorDevice) -> Void
    var openSimulatorLog: (SimulatorDevice) -> Void
}
