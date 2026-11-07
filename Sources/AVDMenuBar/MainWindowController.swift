import AppKit
import SwiftUI

final class MainWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    private let onClose: () -> Void

    init(model: AppModel, actions: PanelActions, onClose: @escaping () -> Void) {
        self.onClose = onClose
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = "AVD MenuBar"
        window.identifier = NSUserInterfaceItemIdentifier("main")
        window.setFrameAutosaveName("AVDMenuBarMain")
        window.contentMinSize = NSSize(width: 740, height: 480)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: MainView(model: model, actions: actions)
        )
        window.delegate = self
        window.center()
    }

    func show() {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
