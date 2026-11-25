import AppKit
import ClipboardSettings
import SuiteCore
import SwiftUI

/// The Clipboard tab's state: Clipboard's settings, and what it reports about itself.
final class ClipboardSettingsModel: ObservableObject {
    let settings = ClipboardSettings.forExplorer()
    private var observers: [NSObjectProtocol] = []

    init() {
        observers.append(ClipboardMessage.statusDidChange.observe { [weak self] _ in
            self?.settings.reload()
            self?.objectWillChange.send()
        })
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.objectWillChange.send()
            })
        }
    }

    /// A setting Clipboard applies as soon as it hears about it.
    func binding<Value>(_ keyPath: ReferenceWritableKeyPath<ClipboardSettings, Value>) -> Binding<Value> {
        Binding(get: { self.settings[keyPath: keyPath] }, set: { value in
            self.objectWillChange.send()
            self.settings[keyPath: keyPath] = value
            ClipboardMessage.settingsDidChange.post()
        })
    }

    /// Off, Clipboard quits (it reads the setting); on, Explorer starts it again.
    var isEnabled: Binding<Bool> {
        Binding(get: { self.settings.isEnabled }, set: { on in
            self.objectWillChange.send()
            self.settings.isEnabled = on
            on ? ExplorerLink.launchClipboard() : ClipboardMessage.settingsDidChange.post()
        })
    }

    var opensAtLogin: Binding<Bool> {
        Binding(get: { self.settings.loginStatus != .off }, set: { on in
            ClipboardMessage.setOpensAtLogin.post(["on": on])
        })
    }

    var ignoredApps: [String] { settings.ignoredApps }

    func ignore(_ bundleID: String) {
        guard !settings.ignoredApps.contains(bundleID) else { return }
        objectWillChange.send()
        settings.ignoredApps.append(bundleID)
    }

    func stopIgnoring(_ bundleID: String) {
        objectWillChange.send()
        settings.ignoredApps.removeAll { $0 == bundleID }
    }

    func chooseAppToIgnore() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = UIL("Ignore")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier { ignore(id) }
        }
    }

    /// Running apps with a Dock icon, the likely ones to ignore (a password manager).
    var runningApps: [(id: String, name: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in app.bundleIdentifier.map { ($0, app.localizedName ?? $0) } }
            .filter { !ignoredApps.contains($0.0) && $0.0 != Bundle.main.bundleIdentifier }
            .sorted { $0.1.localizedStandardCompare($1.1) == .orderedAscending }
    }

    static func appName(_ bundleID: String) -> String? {
        if let name = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName {
            return name
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

struct ClipboardSettingsView: View {
    @ObservedObject var model: ClipboardSettingsModel
    static let height: CGFloat = 540

    var body: some View {
        Form {
            Section {
                Toggle(isOn: model.isEnabled) {
                    Text(UIL("Keep a clipboard history"))
                    Text(UIL("Clipboard keeps what you copy, as Windows does. Hold \u{2318}V in any app to see the list, "
                         + "or use Edit \u{203a} Clipboard History in Explorer."))
                }
            }
            if model.settings.isEnabled {
                Section {
                    Toggle(UIL("Hold \u{2318}V to open the history"), isOn: model.binding(\.holdsCommandV))
                } footer: {
                    Note(UIL("A short \u{2318}V still pastes. Keep \u{2318} down and press V again to go down the list, "
                         + "then let go of \u{2318} to paste. In the list, \u{2318}1 to \u{2318}9 paste the nine latest."))
                }

                Section {
                    Picker(UIL("Show in the list"), selection: model.binding(\.quickListSize)) {
                        let size = model.settings.quickListSize
                        ForEach(ClipboardSettings.quickListChoices + (ClipboardSettings.quickListChoices.contains(size)
                            ? [] : [size]), id: \.self) { n in Text(String(format: UIL("The latest %d"), n)).tag(n) }
                    }
                    Toggle(UIL("Keep the pinned list above other windows"), isOn: model.binding(\.pinnedListOnTop))
                } header: {
                    Text(UIL("List"))
                } footer: {
                    Note(UIL("\u{201C}Show All\u{201D} at the end of the list opens the whole history in a window. The pin at the "
                         + "top of the list keeps it open when you click elsewhere or paste."))
                }

                Section(UIL("History")) {
                    Picker(UIL("Keep the last"), selection: model.binding(\.historyLimit)) {
                        let limit = model.settings.historyLimit
                        ForEach(ClipboardSettings.limitChoices + (ClipboardSettings.limitChoices.contains(limit)
                            ? [] : [limit]), id: \.self) { n in Text(String(format: UIL("%d items"), n)).tag(n) }
                    }
                    Picker(UIL("Forget items after"), selection: model.binding(\.expiryDays)) {
                        Text(UIL("Never")).tag(0)
                        Text(UIL("1 day")).tag(1)
                        Text(UIL("1 week")).tag(7)
                        Text(UIL("1 month")).tag(30)
                    }
                    Toggle(UIL("Open Clipboard at login"), isOn: model.opensAtLogin)
                    if model.settings.loginStatus == .needsApproval {
                        HStack {
                            Note(UIL("Turn Clipboard on in System Settings \u{203a} General \u{203a} Login Items."))
                            Spacer()
                            Button(UIL("Open Login Items")) {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                            }
                        }
                    }
                    Button(UIL("Clear History")) { ClipboardMessage.clearHistory.post() }
                }

                if ClipboardBackupPlace.iCloudDrive != nil {
                    Section {
                        Toggle(UIL("Back up the history to iCloud Drive"), isOn: model.binding(\.backsUpToICloud))
                    } footer: {
                        Note(String(format: UIL("Each Mac keeps its own copy of the history in iCloud Drive \u{203a} Explorer \u{203a} Clipboard \u{203a} %@. After reinstalling, or on a new Mac, turning this on brings the history back."), ClipboardBackupPlace.machineName))
                    }
                }

                Section(UIL("Pasting")) {
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: model.settings.canPaste ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(model.settings.canPaste ? .green : .orange)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(UIL(model.settings.canPaste
                                 ? "Clipboard pastes the item you choose into the app you were using."
                                 : "Holding \u{2318}V and pasting into the app you were using need Accessibility access for Clipboard. Until then, the item you choose is copied: press \u{2318}V to paste it."))
                                .fixedSize(horizontal: false, vertical: true)
                            if !model.settings.canPaste {
                                Button(UIL("Open Accessibility Settings")) { ClipboardMessage.requestAccessibility.post() }
                            }
                        }
                    }
                }

                Section {
                    ForEach(model.ignoredApps, id: \.self) { id in
                        HStack {
                            AppLabel(bundleID: id)
                            Spacer()
                            Button { model.stopIgnoring(id) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                                .help(UIL("Keep copies from this app again"))
                        }
                    }
                    Menu(UIL("Add App")) {
                        ForEach(model.runningApps, id: \.id) { app in
                            Button(app.name) { model.ignore(app.id) }
                        }
                        Divider()
                        Button(UIL("Choose")) { model.chooseAppToIgnore() }
                    }
                    .fixedSize()
                } header: {
                    Text(UIL("Apps to ignore"))
                } footer: {
                    Note(UIL("What is copied in these apps is not kept. Passwords that password managers mark as "
                         + "private are never kept, whatever the app."))
                }
            }
        }
        .formStyle(.grouped)
        // Taller than the other tabs: it scrolls rather than making the window taller than the screen.
        .frame(height: model.settings.isEnabled ? Self.height : nil)
    }
}

private struct Note: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

private struct AppLabel: View {
    let bundleID: String

    var body: some View {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        HStack {
            if let url {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 20, height: 20)
            } else {
                Image(systemName: "app.dashed").frame(width: 20, height: 20)
            }
            VStack(alignment: .leading) {
                Text(ClipboardSettingsModel.appName(bundleID) ?? bundleID)
                if url == nil { Text(bundleID).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}
