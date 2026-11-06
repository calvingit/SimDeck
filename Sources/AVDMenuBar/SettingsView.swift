import AppKit
import SwiftUI
import AVDCore

struct SettingsView: View {
    @ObservedObject var model: AppModel

    @State private var saved: SettingsDraft
    @State private var draft: SettingsDraft
    @State private var pathMessage: String?
    @State private var pathError = false
    @State private var testID: UUID?
    @State private var loginMessage: String?
    @State private var loginError = false
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @AppStorage(AppAppearance.defaultsKey) private var appearanceRaw = AppAppearance.system.rawValue
    @AppStorage(AppLanguage.defaultsKey) private var languageRaw = AppLanguage.system.rawValue

    init(model: AppModel) {
        self.model = model
        let paths = model.currentDraft()
        _saved = State(initialValue: paths)
        _draft = State(initialValue: paths)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                pathsSection
                Divider()
                loginSection
                Divider()
                appearanceSection
                Divider()
                languageSection
            }
            .padding(22)
        }
        .frame(width: 660, height: 520)
    }

    private var pathsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(AppLanguage.text("settings.tools"), systemImage: "wrench.and.screwdriver").font(.headline)
            Text(AppLanguage.text("settings.tools.help"))
                .font(.caption).foregroundStyle(.secondary)

            pathRow("avdmanager", detected: model.tools?.avdmanager.path, keyPath: \.avdmanagerPath)
            pathRow("emulator", detected: model.tools?.emulator?.path, keyPath: \.emulatorPath)
            pathRow("adb", detected: model.tools?.adb?.path, keyPath: \.adbPath)

            HStack {
                Button(AppLanguage.text("settings.tools.useAuto")) {
                    updateDraft(SettingsDraft(avdmanagerPath: "", emulatorPath: "", adbPath: ""))
                    runTest()
                }
                Button(AppLanguage.text("settings.tools.test"), action: runTest).disabled(testID != nil)
                if testID != nil {
                    ProgressView().controlSize(.small).accessibilityLabel(AppLanguage.text("settings.tools.testing"))
                }
                Spacer()
                Button(AppLanguage.text("settings.tools.revert")) { updateDraft(saved) }
                    .disabled(draft == saved)
                Button(AppLanguage.text("settings.tools.save"), action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(draft == saved)
            }

            if let pathMessage {
                ScrollView {
                    Text(pathMessage)
                        .font(.caption)
                        .foregroundStyle(pathError ? Color.red : Color.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 76)
            }
        }
    }

    private var loginSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(AppLanguage.text("settings.login"), systemImage: "power").font(.headline)
            Toggle(AppLanguage.text("settings.login.toggle"), isOn: Binding(
                get: { launchAtLogin },
                set: { enabled in
                    do {
                        try LaunchAtLogin.setEnabled(enabled)
                        loginError = false
                        loginMessage = enabled && LaunchAtLogin.requiresApproval
                            ? AppLanguage.text("settings.login.approval")
                            : nil
                    } catch {
                        loginError = true
                        loginMessage = AppLanguage.text("settings.login.failure", error.localizedDescription)
                    }
                    launchAtLogin = LaunchAtLogin.isEnabled
                }
            ))
            Text(AppLanguage.text("settings.login.help"))
                .font(.caption).foregroundStyle(.secondary)
            if let loginMessage {
                Text(loginMessage)
                    .font(.caption)
                    .foregroundStyle(loginError ? Color.red : Color.secondary)
            }
        }
    }

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(AppLanguage.text("settings.appearance"), systemImage: "paintbrush").font(.headline)
            Picker(AppLanguage.text("settings.appearance.theme"), selection: $appearanceRaw) {
                ForEach(AppAppearance.allCases, id: \.rawValue) { appearance in
                    Text(appearance.title).tag(appearance.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: appearanceRaw) { _, newValue in
                AppAppearance.apply(rawValue: newValue)
            }
            Text(AppLanguage.text("settings.appearance.help"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(AppLanguage.text("settings.language"), systemImage: "globe").font(.headline)
            Picker(AppLanguage.text("settings.language"), selection: $languageRaw) {
                Text(AppLanguage.text("settings.language.system")).tag(AppLanguage.system.rawValue)
                Text("简体中文").tag(AppLanguage.simplifiedChinese.rawValue)
                Text("English").tag(AppLanguage.english.rawValue)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            Text(AppLanguage.text("settings.language.restart"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func pathRow(
        _ label: String,
        detected: String?,
        keyPath: WritableKeyPath<SettingsDraft, String>
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .frame(width: 92, alignment: .leading)
            TextField("", text: Binding(
                get: { draft[keyPath: keyPath] },
                set: { updatePath($0, at: keyPath) }
            ), prompt: Text(saved[keyPath: keyPath].isEmpty ? (detected ?? AppLanguage.text("settings.tools.auto")) : AppLanguage.text("settings.tools.auto")))
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel(label)
            Button(AppLanguage.text("settings.tools.choose")) {
                let panel = NSOpenPanel()
                panel.canChooseFiles = true
                panel.canChooseDirectories = false
                panel.allowsMultipleSelection = false
                panel.showsHiddenFiles = true
                NSApp.activate(ignoringOtherApps: true)
                if panel.runModal() == .OK, let url = panel.url {
                    updatePath(url.path, at: keyPath)
                }
            }
            .accessibilityLabel(AppLanguage.text("settings.tools.choosePath", label))
        }
    }

    private func updatePath(_ path: String, at keyPath: WritableKeyPath<SettingsDraft, String>) {
        var updated = draft
        updated[keyPath: keyPath] = path
        updateDraft(updated)
    }

    private func updateDraft(_ updated: SettingsDraft) {
        guard updated != draft else { return }
        draft = updated
        testID = nil
        pathMessage = nil
    }

    private func runTest() {
        let id = UUID()
        testID = id
        pathMessage = nil
        model.testConfiguration(draft) { result in
            guard testID == id else { return }
            pathMessage = AppLanguage.text("settings.tools.result") + result
            pathError = result.hasPrefix("✗")
            testID = nil
        }
    }

    private func save() {
        testID = nil
        if let error = model.applySettings(draft) {
            pathMessage = AppLanguage.text("settings.tools.saveFailed", error)
            pathError = true
        } else {
            saved = draft
            pathMessage = AppLanguage.text("settings.tools.saved")
            pathError = false
        }
    }
}
