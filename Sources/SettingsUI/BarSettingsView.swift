import AppKit
import ExplorerSettings
import Foundation
import SuiteCore
import BarSettings
import SwiftUI
import UniformTypeIdentifiers

/// Settings › Dock.
struct BarSettingsView: View {
    @ObservedObject var model: SettingsModel

    /// Written in Bar.app's defaults; the Dock is told, and started if it was just turned on.
    private func bar<Value>(_ keyPath: WritableKeyPath<BarSettings, Value>) -> Binding<Value> {
        model.binding({ BarSettings.current[keyPath: keyPath] },
                      { BarSettings.current[keyPath: keyPath] = $0; BarApp.settingsChanged() })
    }

    // Every row is always there (greyed out with the System Dock) and every note keeps its text: the
    // tab's height must not change, or the settings window lays it out wrong.
    var body: some View {
        let options = BarSettings.current
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Picker(UIL("Enable"), selection: bar(\.isShown)) {
                        Text(UIL("System Dock")).tag(false)
                        Text(UIL("Bar")).tag(true)
                    }
                    .pickerStyle(.segmented)
                    BarNote(UIL("Bar replaces the system Dock, hidden with Finder\u{2019}s icon, whose settings come "
                         + "back with the System Dock. Shown while Explorer manages files (General)."))
                }
            }
            Section(UIL("Bar")) {
                Toggle(UIL("Show Launcher"), isOn: bar(\.showsLauncher))
                Slider(value: bar(\.iconSize), in: BarSettings.iconSizes, step: 8) {
                    Text(UIL("Size"))
                } minimumValueLabel: {
                    Text(UIL("Small"))
                } maximumValueLabel: {
                    Text(UIL("Large"))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Picker(UIL("By default"), selection: bar(\.autohides)) {
                        Text(UIL("Hides automatically")).tag(true)
                        Text(UIL("Stays on screen")).tag(false)
                    }
                    BarNote(UIL("Hidden, it slides in when the pointer reaches the bottom of the screen. On screen, "
                             + "maximized windows end above it."))
                }
                VStack(alignment: .leading, spacing: 6) {
                    if options.autohides { Text(UIL("Stays on screen with these apps")) }
                    else { Text(UIL("Hides automatically with these apps")) }
                    BarAppList(bundleIDs: bar(\.exceptions))
                    BarNote(UIL("While one of them is in front. Each default keeps its own list."))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Picker(UIL("In full screen"), selection: bar(\.fullScreen)) {
                        Text(UIL("Hides automatically")).tag(BarFullScreenMode.hides)
                        Text(UIL("Stays on screen")).tag(BarFullScreenMode.stays)
                        Text(UIL("As for the app")).tag(BarFullScreenMode.asForTheApp)
                    }
                    BarNote(UIL("While an app fills the screen. As for the app: the default and the lists above."))
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(UIL("Other apps\u{2019} windows"))
                        Spacer()
                        if BarMessage.windowFittingAllowed {
                            Label(UIL("Allowed"), systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.secondary)
                        } else {
                            Button(UIL("Allow")) { BarMessage.allowWindowFitting.post() }
                        }
                    }
                    BarNote(UIL("To keep them above Bar and show the minimized ones in it, Bar needs the "
                             + "Accessibility permission (Privacy & Security \u{203a} Accessibility)."))
                }
            }
            .disabled(!options.isShown)
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .onReceive(DistributedNotificationCenter.default().publisher(for: ExplorerLink.explorerDidChange)) { _ in
            model.objectWillChange.send()
        }
        .onReceive(DistributedNotificationCenter.default().publisher(for: BarMessage.statusDidChange.name)) { _ in
            model.objectWillChange.send()
        }
    }
}

/// Grey explanation under a setting, as in the other tabs.
private struct BarNote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// Apps by bundle identifier, each with its icon and name, added from the running apps or the Applications
/// folder and removed with the minus button. A fixed height, so the tab keeps its own.
private struct BarAppList: View {
    @Binding var bundleIDs: [String]
    @State private var selection: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(bundleIDs, id: \.self) { id in
                        BarAppRow(bundleID: id, selected: selection == id)
                            .contentShape(Rectangle())
                            .onTapGesture { selection = id }
                    }
                    if bundleIDs.isEmpty {
                        Text(UIL("No apps")).foregroundStyle(.tertiary).padding(.top, 30)
                    }
                }
            }
            .frame(height: 96)
            Divider()
            HStack(spacing: 0) {
                Menu {
                    ForEach(runningApps, id: \.bundleID) { app in
                        Button {
                            add(app.bundleID)
                        } label: {
                            Label { Text(app.name) } icon: { Image(nsImage: app.icon) }
                        }
                    }
                    Divider()
                    Button(UIL("Choose an App")) { choose() }
                } label: {
                    Image(systemName: "plus").frame(width: 22, height: 18)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                Divider().frame(height: 16)
                Button {
                    bundleIDs.removeAll { $0 == selection }
                    selection = nil
                } label: {
                    Image(systemName: "minus").frame(width: 22, height: 18)
                }
                .buttonStyle(.borderless)
                .disabled(selection == nil)
                Spacer()
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
    }

    private struct RunningApp { let bundleID: String; let name: String; let icon: NSImage }

    /// The apps running now with a Dock icon, by name, those already listed left out.
    private var runningApps: [RunningApp] {
        NSWorkspace.shared.runningApplications.compactMap { app -> RunningApp? in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier, !bundleIDs.contains(id)
            else { return nil }
            let icon = app.icon ?? NSImage()
            icon.size = NSSize(width: 16, height: 16)
            return RunningApp(bundleID: id, name: app.localizedName ?? id, icon: icon)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func add(_ id: String) {
        guard !bundleIDs.contains(id) else { return }
        bundleIDs.append(id)
        selection = id
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier { add(id) }
        }
    }
}

private struct BarAppRow: View {
    let bundleID: String
    let selected: Bool

    var body: some View {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        HStack(spacing: 6) {
            if let url {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 18, height: 18)
                Text(FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
            } else {
                Image(systemName: "app.dashed").frame(width: 18, height: 18)
                Text(bundleID).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .foregroundStyle(selected ? Color.white : Color.primary)
        .background(selected ? Color.accentColor : Color.clear)
    }
}

/// Bar.app, as its settings tab sees it.
enum BarApp {
    /// The Dock reads them again; turned on while the Dock isn't running, it is started.
    static func settingsChanged() {
        BarMessage.applySettings.post()
        guard BarSettings.current.isShown,
              NSRunningApplication.runningApplications(withBundleIdentifier: BarSettings.domain).isEmpty,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: BarSettings.domain) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }
}
