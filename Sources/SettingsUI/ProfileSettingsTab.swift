import AppKit
import ClipboardSettings
import DesktopSettings
import ExplorerSettings
import SuiteCore
import SwiftUI
import SuiteFilesCore

/// Settings › Profile: the suite's settings saved as named profiles, on this Mac or in iCloud Drive (for
/// every Mac on the account), to create, load, save and switch between. Loading one replaces the settings of
/// Explorer, Clipboard, Viewer and Bindings and applies them at once; only a setting Explorer can't apply
/// while it runs makes it offer to reopen, and it asks first.
final class ProfilesModel: ObservableObject {
    @Published private(set) var files: [ProfileFile] = []
    private let store: ProfileStore

    init(store: ProfileStore = ProfileStore()) {
        self.store = store
        reload()
    }

    func reload() { files = store.list() }

    /// The file of the profile last loaded or saved, if it is still there.
    var current: ProfileFile? {
        guard let path = SuiteDefaults.explorer.string(forKey: SettingsProfile.currentKey) else { return nil }
        let wanted = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return files.first { $0.url.resolvingSymlinksInPath().path == wanted }
    }

    private func setCurrent(_ url: URL?) {
        SuiteDefaults.explorer.set(url?.resolvingSymlinksInPath().path, forKey: SettingsProfile.currentKey)
        objectWillChange.send()
    }

    /// Each app's settings as they are now.
    private var currentSettings: [String: [String: Any]] {
        var settings: [String: [String: Any]] = [:]
        for domain in SettingsProfile.domains {
            settings[domain] = SuiteDefaults.explorer.persistentDomain(forName: domain) ?? [:]
        }
        return settings
    }

    func create(named name: String, in location: ProfileLocation) {
        attempt {
            let url = try store.save(SettingsProfile.capture(name: name, from: currentSettings), in: location)
            reload()
            setCurrent(url)
        }
    }

    /// Replaces what `file` holds with the settings as they are now.
    func saveCurrentSettings(into file: ProfileFile) {
        attempt {
            let url = try store.save(SettingsProfile.capture(name: file.name, from: currentSettings), in: file.location)
            reload()
            setCurrent(url)
        }
    }

    /// After asking: the profile's settings replace the current ones and apply at once.
    func load(_ file: ProfileFile) {
        let alert = NSAlert()
        alert.messageText = String(format: UIL("Load \u{201C}%@\u{201D}?"), file.name)
        alert.informativeText = UIL("Its settings replace those of Explorer, Clipboard, Viewer and Bindings.")
        alert.addButton(withTitle: UIL("Load"))
        alert.addButton(withTitle: UIL("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        attempt {
            let profile = try store.read(file)
            var changedKeys = Set<String>()
            for (domain, change) in profile.changes(from: currentSettings) {
                let isExplorer = domain == SuiteDefaults.explorerDomain
                let defaults = isExplorer ? SuiteDefaults.explorer : UserDefaults(suiteName: domain)
                for key in change.remove where defaults?.object(forKey: key) != nil {
                    defaults?.removeObject(forKey: key)
                    if isExplorer { changedKeys.insert(key) }
                }
                for (key, value) in change.set where !(defaults?.object(forKey: key) as AnyObject).isEqual(value) {
                    defaults?.set(value, forKey: key)
                    if isExplorer { changedKeys.insert(key) }
                }
                defaults?.synchronize()
            }
            setCurrent(file.url)
            Self.applyLive()
            ClipboardMessage.settingsDidChange.post()
            offerToReopen(for: changedKeys.filter { !Self.appliesLive($0) })
        }
    }

    /// Explorer's settings that take effect as soon as they are written, once the parts that keep them are
    /// told (`applyLive`); window frames apply when those windows next open.
    private static let liveKeys: Set<String> = [
        "CheckForUpdates", "InstallUpdatesAutomatically", "UpdateFeed", "BarSettings",
        "BarPinnedApps", "FolderViewOptions", "DefaultFolderViewOptions", "LeftSidebar", "LeftSidebarShown",
        "RightSidebar", "RightSidebarShown", "UseExplorer", "OpenFoldersFromOtherApps", "QuitFinder",
        "RedirectFinder", "RedirectFinderAsks", "SearchScope", "ShowFileExtensions", "ShowHiddenFiles",
        "ShowSyncBadges", "SyncBadgeStyle", "SidebarPlaces", "ToolbarLayout", "ShowToolbarLabels", "UseTabs",
        "OpenFoldersInNewTab", "SideBySideInOneWindow", "QuickAccessFolders", "ShowMenuBarIcon",
        "ReturnKeyRenames", "OpenPicturesInViewer", "ShowThumbnails", "ShowFullNameOfSelection",
        "TrashIncludesICloudDrive", "OpenFolderAfterRestore", "NewWindowWidth",
    ]

    private static func appliesLive(_ key: String) -> Bool {
        liveKeys.contains(key) || key.hasPrefix(SettingsProfile.windowFramePrefix)
    }

    /// Explorer applies what was written: the parts that keep settings read them again, the others redraw.
    private static func applyLive() {
        ExplorerLink.send(.applySettings)
        DesktopMessage.applySettings.post()
        BarApp.settingsChanged()
    }

    /// Only for settings Explorer can't apply while it runs, and only if you agree.
    private func offerToReopen(for keys: Set<String>) {
        guard !keys.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = UIL("Reopen Explorer to finish loading the profile?")
        alert.informativeText = UIL("Some of its settings take effect when Explorer opens again. Everything else is already applied.")
        alert.addButton(withTitle: UIL("Reopen"))
        alert.addButton(withTitle: UIL("Later"))
        if alert.runModal() == .alertFirstButtonReturn { ExplorerLink.send(.relaunch) }
    }

    func move(_ file: ProfileFile, to location: ProfileLocation) {
        attempt {
            let wasCurrent = current == file
            let url = try store.move(file, to: location)
            reload()
            if wasCurrent { setCurrent(url) }
        }
    }

    func remove(_ file: ProfileFile) {
        attempt {
            if current == file { setCurrent(nil) }
            try store.remove(file)
            reload()
        }
    }

    private func attempt(_ work: () throws -> Void) {
        do {
            try work()
        } catch {
            let alert = NSAlert()
            alert.messageText = UIL("The profile couldn\u{2019}t be saved or read")
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}

struct ProfileSettingsView: View {
    @StateObject private var model: ProfilesModel

    init(model: ProfilesModel = ProfilesModel()) {
        _model = StateObject(wrappedValue: model)
    }
    @State private var newName = ""
    @State private var newLocation = ProfileLocation.thisMac

    var body: some View {
        Form {
            Section(UIL("Current profile")) {
                if let current = model.current {
                    LabeledContent(UIL("Profile")) {
                        Label(current.name, systemImage: icon(current.location))
                    }
                    HStack {
                        Button(UIL("Save Current Settings")) { model.saveCurrentSettings(into: current) }
                        Spacer()
                        Text(UIL("Changes made since loading it are kept in it only when you save."))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                } else {
                    Text(UIL("Your settings aren\u{2019}t saved in a profile yet."))
                        .foregroundStyle(.secondary)
                }
            }
            Section(UIL("New profile")) {
                TextField(UIL("Name"), text: $newName, prompt: Text("Work, Home, Presentation"))
                Picker(UIL("Keep it on"), selection: $newLocation) {
                    ForEach(ProfileLocation.allCases, id: \.self) { loc in
                        Text(UIL(loc == .thisMac ? "This Mac" : "iCloud Drive")).tag(loc)
                    }
                }
                .pickerStyle(.segmented)
                HStack {
                    Button(UIL("Create from Current Settings")) {
                        model.create(named: newName.trimmingCharacters(in: .whitespaces), in: newLocation)
                        newName = ""
                    }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    Spacer()
                }
                (newLocation == .thisMac
                     ? Text(UIL("Kept in ~/Library/Application Support/Explorer/Profiles."))
                     : Text(UIL("Kept in iCloud Drive \u{203a} Explorer \u{203a} Profiles: every Mac on your iCloud account can load it.")))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section(UIL("Profiles")) {
                if model.files.isEmpty {
                    Text(UIL("None yet. A profile holds the settings of Explorer, Clipboard, Viewer and Bindings."))
                        .foregroundStyle(.secondary)
                }
                ForEach(model.files, id: \.url) { file in
                    row(file)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.reload() }
    }

    private func row(_ file: ProfileFile) -> some View {
        let isCurrent = model.current == file
        return HStack(spacing: 10) {
            Image(systemName: icon(file.location))
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .help(UIL(file.location == .thisMac ? "This Mac" : "iCloud Drive"))
            VStack(alignment: .leading, spacing: 1) {
                Text(file.name).fontWeight(isCurrent ? .semibold : .regular)
                Text((isCurrent ? UIL("Current, ") : "") + UIL("saved ")
                     + file.modified.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(UIL("Load")) { model.load(file) }
            Menu {
                Button(UIL("Save Current Settings Here")) { model.saveCurrentSettings(into: file) }
                if file.location == .thisMac {
                    Button(UIL("Move to iCloud Drive")) { model.move(file, to: .iCloudDrive) }
                } else {
                    Button(UIL("Move to This Mac")) { model.move(file, to: .thisMac) }
                }
                Divider()
                Button(UIL("Move to Trash")) { model.remove(file) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private func icon(_ location: ProfileLocation) -> String {
        location == .thisMac ? "laptopcomputer" : "icloud"
    }
}
