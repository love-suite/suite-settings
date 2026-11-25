import BarSettings
import AppKit
import Combine
import DesktopSettings
import ExplorerSettings
import SuiteCore
import SwiftUI
import SuiteFilesCore

/// The settings of Explorer and its companion apps, in Suite Settings, an app of its own with its own
/// Dock icon: General (what concerns every app: updates), Profile, then one tab per app. What is changed
/// here is written in each app's defaults and applied at once by that app (`ExplorerLink`).
public enum SettingsWindow {
    private static var controller: NSWindowController?

    public static func show(tab label: String? = nil) {
        if controller == nil {
            let tabs = NSTabViewController()
            tabs.tabStyle = .toolbar
            let model = SettingsModel()
            tabs.addTabViewItem(tab("General", symbol: "gearshape", GeneralSettings(model: model)))
            // Profiles hold every app's settings, so they come with General, before the apps.
            tabs.addTabViewItem(tab("Profile", symbol: "person.crop.circle", ProfileSettingsView().frame(height: 520)))
            tabs.addTabViewItem(tab("Explorer", symbol: "folder", ExplorerTab(model: model)))
            // Its own tab: the toolbar at real size is wider than a settings form can be.
            tabs.addTabViewItem(tab("Toolbar", symbol: "menubar.rectangle", ToolbarTab(model: model), width: nil))
            tabs.addTabViewItem(tab("Trash", symbol: "trash", TrashSettingsView(model: model)))
            tabs.addTabViewItem(tab("Desktop", symbol: "menubar.dock.rectangle", DesktopSettingsView(model: model)))
            tabs.addTabViewItem(tab("Bar", symbol: "dock.rectangle", BarSettingsView(model: model)))
            tabs.addTabViewItem(tab("Viewer", symbol: "photo", ViewerSettings(model: model)))
            if ExplorerLink.clipboardAppURL != nil {
                tabs.addTabViewItem(tab("Clipboard", symbol: "list.clipboard",
                                        ClipboardSettingsView(model: ClipboardSettingsModel())))
            }
            let window = NSWindow(contentViewController: tabs)
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.title = "Suite Settings"
            window.center()
            controller = NSWindowController(window: window)
        }
        if let label, let tabs = controller?.contentViewController as? NSTabViewController,
           let index = tabs.tabViewItems.firstIndex(where: { $0.identifier as? String == label }) {
            tabs.selectedTabViewItemIndex = index
        }
        NSApp.activate(ignoringOtherApps: true)
        controller?.window?.deminiaturize(nil)
        controller?.showWindow(nil)
        // What Settings shows about Explorer (its updates, its permissions), fresh.
        ExplorerLink.send(.reportStatus)
        BarMessage.reportStatus.post()
    }

    /// `width` nil: the tab sizes itself (the Explorer tab is as wide as the toolbar it shows).
    private static func tab<Content: View>(_ label: String, symbol: String, _ content: Content,
                                           width: CGFloat? = 500) -> NSTabViewItem {
        let host = NSHostingController(rootView: content.frame(width: width).fixedSize())
        host.sizingOptions = .preferredContentSize
        host.title = UIL(label)
        let item = NSTabViewItem(viewController: host)
        item.identifier = label
        item.label = UIL(label)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: UIL(label))
        return item
    }
}

/// Settings › Toolbar: as wide as the toolbar it shows, for the window width its slider sets.
private struct ToolbarTab: View {
    @ObservedObject var model: SettingsModel
    @State private var windowWidth = ToolbarSettingsView.explorerWindowWidth

    var body: some View {
        ToolbarSettingsView(model: model, windowWidth: $windowWidth)
            .frame(width: max(640, ToolbarSettingsView.tabWidth(windowWidth: windowWidth)))
    }
}

/// Reads and writes the settings where they live, and redraws when they change from elsewhere.
final class SettingsModel: ObservableObject {
    private var observers: [NSObjectProtocol] = []

    init() {
        for name in [DesktopSettings.didChange, DisplaySettings.didChange, WindowSettings.didChange,
                     BarSettings.didChange, QuickAccessStore.didChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in self?.objectWillChange.send()
            })
        }
        // The Dock's status (Accessibility) changed: redraw.
        observers.append(BarMessage.statusDidChange.observe { [weak self] _ in self?.objectWillChange.send() })
        // Changed in Explorer (its menus, its windows) or its status: redraw.
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: ExplorerLink.explorerDidChange, object: nil, queue: .main) { [weak self] _ in
            CFPreferencesAppSynchronize(SuiteDefaults.explorerDomain as CFString)
            DesktopSettings.reloadFromDefaults()
            self?.objectWillChange.send()
        })
    }

    /// A binding that writes through `set`, lets the form redraw, and has Explorer apply it.
    func binding<Value>(_ get: @escaping () -> Value, _ set: @escaping (Value) -> Void) -> Binding<Value> {
        Binding(get: get, set: { [weak self] value in
            self?.objectWillChange.send()
            set(value)
            ExplorerLink.settingsChanged()
        })
    }

    func finder<Value>(_ keyPath: ReferenceWritableKeyPath<FinderSwitches, Value>) -> Binding<Value> {
        binding({ FinderSwitches.shared[keyPath: keyPath] }, { FinderSwitches.shared[keyPath: keyPath] = $0 })
    }

    /// The desktop's settings, in Desktop's defaults: Desktop is told, not Explorer.
    func desktop<Value>(_ keyPath: WritableKeyPath<DesktopSettings, Value>) -> Binding<Value> {
        Binding(get: { DesktopSettings.current[keyPath: keyPath] }, set: { [weak self] value in
            self?.objectWillChange.send()
            DesktopSettings.current[keyPath: keyPath] = value
            CFPreferencesAppSynchronize(DesktopSettings.domain as CFString)
            DesktopMessage.applySettings.post()
        })
    }
}

private struct Note: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// What concerns every app of the suite.
/// Explorer's updater, seen from Settings: its settings in Explorer's defaults, its version from its
/// bundle, its state as Explorer reports it, Check Now asked of Explorer.
private struct UpdaterProxy {
    var currentVersion: String { ExplorerLink.explorerVersion }
    var currentBuild: String { ExplorerLink.explorerBuild }
    var publicKey: String? { ExplorerLink.hasUpdateKey ? "present" : nil }

    var settings: UpdateSettings {
        get { UpdateSettings.load() }
        nonmutating set { newValue.save() }
    }

    func check(userInitiated: Bool) { ExplorerLink.send(.checkForUpdates) }
    func describeState() -> String { ExplorerLink.updaterState }
}

private enum AppLanguage {
    static var current: String? {
        (UserDefaults(suiteName: SuiteDefaults.explorerDomain)?
            .array(forKey: "AppleLanguages") as? [String])?.first
    }

    /// The system's first preferred language, by name in the current app locale (e.g. "Français", "English").
    static var systemLanguageName: String {
        let code = String((Locale.preferredLanguages.first ?? "").prefix(2))
        return Locale.autoupdatingCurrent.localizedString(forLanguageCode: code) ?? code
    }

    static func set(_ code: String?) {
        for domain in [SuiteDefaults.explorerDomain, "local.suite.settings",
                       "local.suite.viewer", "local.suite.clipboard"] {
            let ud = UserDefaults(suiteName: domain)
            if let code { ud?.set([code], forKey: "AppleLanguages") }
            else { ud?.removeObject(forKey: "AppleLanguages") }
            ud?.synchronize()
        }
    }

    @MainActor static func restartApps() {
        ExplorerLink.send(.relaunch)
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.activates = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSApp.terminate(nil) }
    }
}

private struct GeneralSettings: View {
    @ObservedObject var model: SettingsModel
    // Int tags: String tags are encoded via hashValue for NSPopUpButton, which is randomized
    // in Swift 5+ and breaks selection matching. 0 = system default, 1 = en, 2 = fr.
    @State private var languageIndex: Int = { switch AppLanguage.current {
        case "en": return 1; case "fr": return 2; default: return 0 } }()
    @State private var pendingRestart = false

    var body: some View {
        Form {
            Section(UIL("Language")) {
                Picker(UIL("Language"), selection: $languageIndex) {
                    Text(verbatim: UIL("System default") + " (\(AppLanguage.systemLanguageName))").tag(0)
                    Text("English").tag(1)
                    Text("Français").tag(2)
                }
                .onChange(of: languageIndex) { idx in
                    AppLanguage.set(idx == 1 ? "en" : idx == 2 ? "fr" : nil)
                    pendingRestart = true
                }
                if pendingRestart {
                    HStack {
                        Button(UIL("Restart to Apply")) { AppLanguage.restartApps() }
                        Note(UIL("Explorer and Suite Settings restart to apply the change."))
                    }
                }
            }
            Section(UIL("Updates")) {
                let updater = UpdaterProxy()
                LabeledContent(UIL("Version"), value: "\(updater.currentVersion) (\(updater.currentBuild))")
                Toggle(UIL("Check for updates automatically"), isOn: model.binding({ updater.settings.checksAutomatically }, {
                    var settings = updater.settings
                    settings.checksAutomatically = $0
                    updater.settings = settings
                }))
                VStack(alignment: .leading, spacing: 4) {
                    Picker(UIL("Install them"), selection: model.binding({ updater.settings.installsAutomatically }, {
                        var settings = updater.settings
                        settings.installsAutomatically = $0
                        updater.settings = settings
                    })) {
                        Text(UIL("Automatically")).tag(true)
                        Text(UIL("After asking")).tag(false)
                    }
                    Note(UIL(updater.settings.installsAutomatically
                         ? "Once no Explorer window is open; Explorer, Viewer and Clipboard reopen by themselves."
                         : "A dialog shows what\u{2019}s new and installs it when you say so."))
                }
                HStack {
                    Button(UIL("Check Now")) { updater.check(userInitiated: true) }
                        .disabled(updater.publicKey == nil)
                    Note(updater.describeState())
                }
                VStack(alignment: .leading, spacing: 4) {
                    TextField(UIL("Releases from"), text: model.binding({ updater.settings.feedAddress }, {
                        var settings = updater.settings
                        settings.feedAddress = $0
                        updater.settings = settings
                    }), prompt: Text(UIL("GitHub releases")))
                    Note(UIL("Empty, Explorer looks at the latest release on GitHub, where scripts/publish.sh "
                         + "publishes them. A web address of another update.json works too."))
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }
}

/// The Trash: what it gathers, and what Restore does.
private struct TrashSettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section(UIL("Restore")) {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(UIL("Open the folder of restored items"),
                           isOn: model.binding({ WindowSettings.opensFolderAfterRestore },
                                               { WindowSettings.opensFolderAfterRestore = $0 }))
                    Note(UIL(WindowSettings.opensFolderAfterRestore
                         ? "Restore opens the folder each item went back to, with it selected."
                         : "Restore leaves the Trash in front. Its details view shows where each item came from."))
                }
            }
            Section(UIL("What the Trash shows")) {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(UIL("Include iCloud Drive\u{2019}s Trash"),
                           isOn: model.binding({ DisplaySettings.showsICloudTrash },
                                               { DisplaySettings.showsICloudTrash = $0 }))
                    Note(UIL(DisplaySettings.showsICloudTrash
                         ? "What was deleted from iCloud Drive, and from the Desktop and Documents when they are in iCloud, shows in the Trash: it can be restored or deleted permanently."
                         : "Items deleted from iCloud Drive stay out of Explorer\u{2019}s Trash: they can\u{2019}t be restored or deleted permanently here."))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(UIL("It gathers"))
                    ForEach(TrashLocations.all, id: \.self) { folder in
                        Label((folder.path as NSString).abbreviatingWithTildeInPath,
                              systemImage: folder.path.contains("Mobile Documents") ? "icloud"
                                  : folder.path.hasPrefix("/Volumes") ? "externaldrive" : "trash")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                HStack {
                    Button(UIL("Empty Trash")) { ExplorerLink.send(.emptyTrash) }
                    Spacer()
                    Note(UIL("Erases everything in these folders for good, after asking. It can\u{2019}t be undone."))
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }
}

private struct ViewerSettings: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(UIL("Open pictures in Viewer"),
                           isOn: model.binding({ DisplaySettings.opensPicturesInViewer },
                                               { DisplaySettings.opensPicturesInViewer = $0 }))
                    Note(UIL("Arrow keys go through the folder\u{2019}s pictures; Open in Preview edits them."))
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }
}

private struct DesktopSettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section(UIL("Icons")) {
                // Finder's View Options for the desktop: Icon Size and Grid Spacing.
                Slider(value: model.desktop(\.iconSide), in: DesktopSettings.iconSides, step: 4) {
                    Text(UIL("Size"))
                } minimumValueLabel: {
                    Text(UIL("Small"))
                } maximumValueLabel: {
                    Text(UIL("Large"))
                }
                Slider(value: model.desktop(\.gridSpacing), in: DesktopSettings.gridSpacings, step: 1) {
                    Text(UIL("Grid spacing"))
                } minimumValueLabel: {
                    Text(UIL("Tight"))
                } maximumValueLabel: {
                    Text(UIL("Wide"))
                }
                Slider(value: model.desktop(\.textSize), in: DesktopSettings.textSizes, step: 1) {
                    Text(UIL("Text size"))
                } minimumValueLabel: {
                    Text(UIL("Small"))
                } maximumValueLabel: {
                    Text(UIL("Large"))
                }
                Toggle(UIL("Names in bold, as Finder"), isOn: model.desktop(\.boldNames))
                // Finder's View Options for the desktop: Label Position, Show Item Info, Show Icon Preview.
                Picker(UIL("Label position"), selection: model.desktop(\.labelPosition)) {
                    Text(UIL("Bottom")).tag(LabelPosition.bottom)
                    Text(UIL("Right")).tag(LabelPosition.right)
                }
                .pickerStyle(.segmented)
                Toggle(UIL("Show item info"), isOn: model.desktop(\.showsItemInfo))
                Toggle(UIL("Show icon preview"), isOn: model.desktop(\.showsIconPreview))
            }
            // Finder's Settings › General.
            Section(UIL("Show these items on the desktop")) {
                Toggle(UIL("Hard disks"), isOn: model.desktop(\.showsHardDisks))
                Toggle(UIL("External disks"), isOn: model.desktop(\.showsExternalDisks))
                Toggle(UIL("CDs, DVDs, and iPods"), isOn: model.desktop(\.showsRemovableMedia))
                Toggle(UIL("Connected servers"), isOn: model.desktop(\.showsConnectedServers))
            }
            Section(UIL("Arrangement")) {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(UIL("Keep arranged in sort order"), isOn: model.desktop(\.keepArranged))
                    Note(UIL("Icons can\u{2019}t be placed by hand."))
                }
                Picker(UIL("Icons start"), selection: model.desktop(\.startsAtRight)) {
                    Text(UIL("Top right, as Finder")).tag(true)
                    Text(UIL("Top left, as Windows")).tag(false)
                }
                Picker(UIL("Folders first"), selection: model.desktop(\.foldersFirst)) {
                    Text(UIL("As Finder")).tag(FoldersFirst.asFinder)
                    Text(UIL("Always, as in Windows")).tag(FoldersFirst.always)
                    Text(UIL("Never")).tag(FoldersFirst.never)
                }
                Toggle(UIL("Align icons to grid"), isOn: model.desktop(\.snapToGrid))
                Toggle(UIL("Show where icons will land while dragging"), isOn: model.desktop(\.showDropTarget))
                Toggle(UIL("Move icons while dragging"), isOn: model.desktop(\.iconsFollowCursor))
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(UIL("Open folders and stacks when dragging onto them"), isOn: model.desktop(\.springLoading))
                    Note(Self.springLoadingNote)
                }
            }
            Section(UIL("Stacks")) {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(UIL("Use stacks"), isOn: model.desktop(\.stacks))
                    Note(UIL("Inside a stack, items follow the sort order."))
                }
                // Finder's Group Stacks By.
                Picker(UIL("Group stacks by"), selection: model.desktop(\.stackGrouping)) {
                    Text(UIL("Kind")).tag(StackGrouping.kind)
                    Text(UIL("Date Last Opened")).tag(StackGrouping.dateLastOpened)
                    Text(UIL("Date Added")).tag(StackGrouping.dateAdded)
                    Text(UIL("Date Modified")).tag(StackGrouping.dateModified)
                    Text(UIL("Date Created")).tag(StackGrouping.dateCreated)
                    Text(UIL("Tags")).tag(StackGrouping.tags)
                }
                .disabled(!DesktopSettings.current.stacks)
                Toggle(UIL("Stack folders and aliases together"), isOn: model.desktop(\.stacksFolders))
                Toggle(UIL("Stack only while sorted by type"), isOn: model.desktop(\.stacksOnlyWhenSortedByType))
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(UIL("Put items that don\u{2019}t fit into a stack"), isOn: model.desktop(\.overflowStack))
                    Note(UIL("Otherwise they are hidden."))
                }
            }
        }
        .formStyle(.grouped)
        // Taller than the screen allows on small Macs: it scrolls.
        .frame(height: 600)
    }

    /// macOS's spring-loading, which the desktop follows (System Settings › Accessibility › Pointer Control).
    private static var springLoadingNote: String {
        let system = SpringLoading.system()
        guard system.enabled else {
            return UIL("Spring-loading is off in System Settings › Accessibility › Pointer Control.")
        }
        let delay = system.delay.formatted(.number.precision(.fractionLength(0...2)))
        return String(format: UIL("After %@ s, the delay set in System Settings › Accessibility › Pointer Control."), delay)
    }
}

private struct ExplorerTab: View {
    @ObservedObject var model: SettingsModel
    /// Taller than the screen allows on small Macs: it scrolls.
    static let height: CGFloat = 600
    var body: some View {
        Form {
            Section {
                Picker(UIL("Manage files with"), selection: model.finder(\.usesExplorer)) {
                    Text("Explorer").tag(true)
                    Text("Finder").tag(false)
                }
                .pickerStyle(.segmented)
                Note(UIL("Switching back to Finder brings back its desktop and windows."))
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(UIL("Show Explorer in the menu bar"),
                           isOn: model.binding({ MenuBarIcon.isShown }, { MenuBarIcon.isShown = $0 }))
                    Note(UIL("An icon on the right of the menu bar, with New Explorer Window, the switch and Settings."))
                }
            }
            Section(UIL("Finder")) {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(UIL("Open folders from other apps in Explorer"), isOn: model.finder(\.opensFoldersFromOtherApps))
                        .disabled(!ExplorerLink.canSetDefaultViewer)
                    Note(UIL("\"Show in Finder\" in other apps opens Explorer."))
                }
                Toggle(UIL("Keep Finder closed"), isOn: model.finder(\.keepsFinderClosed))
                Toggle(UIL("Redirect Finder to Explorer"), isOn: model.finder(\.redirectsFinder))
                Toggle(UIL("Ask first"), isOn: model.finder(\.asksBeforeRedirecting))
                    .disabled(!FinderSwitches.shared.redirectsFinder)
                    .padding(.leading, 20)
            }
            .disabled(!FinderSwitches.shared.usesExplorer)
            Section(UIL("Files")) {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(UIL("Show thumbnails instead of icons"),
                           isOn: model.binding({ DisplaySettings.showsThumbnails },
                                               { DisplaySettings.showsThumbnails = $0 }))
                }
                Toggle(UIL("Show the full name of selected items"),
                       isOn: model.binding({ DisplaySettings.showsFullNameOfSelection },
                                           { DisplaySettings.showsFullNameOfSelection = $0 }))
                VStack(alignment: .leading, spacing: 4) {
                    Picker(UIL("File extensions"), selection: model.binding({ DisplaySettings.fileExtensions },
                                                                       { DisplaySettings.fileExtensions = $0 })) {
                        Text(UIL("As macOS shows them")).tag(FileExtensions.asMacOS)
                        Text(UIL("Always")).tag(FileExtensions.always)
                        Text(UIL("Never, as in Windows")).tag(FileExtensions.never)
                    }
                    Note(UIL("Never: \u{201C}Report.pdf\u{201D} shows as \u{201C}Report\u{201D}."))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Picker(UIL("Folders first in windows"), selection: model.binding({ DisplaySettings.foldersFirst },
                                                                                { DisplaySettings.foldersFirst = $0 })) {
                        Text(UIL("As Finder")).tag(FoldersFirst.asFinder)
                        Text(UIL("Always, as in Windows")).tag(FoldersFirst.always)
                        Text(UIL("Never")).tag(FoldersFirst.never)
                    }
                    Note(UIL("Aliases to folders count as folders."))
                }
                Toggle(UIL("Names on two lines, cut in the middle, as Finder"),
                       isOn: model.binding({ DisplaySettings.namesOnTwoLines },
                                           { DisplaySettings.namesOnTwoLines = $0 }))
                Toggle(UIL("Alias arrow in a white disc, as macOS 27"),
                       isOn: model.binding({ DisplaySettings.aliasArrowInDisc },
                                           { DisplaySettings.aliasArrowInDisc = $0 }))
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(UIL("Show cloud status badges"),
                           isOn: model.binding({ DisplaySettings.showsSyncBadges },
                                               { DisplaySettings.showsSyncBadges = $0 }))
                    Picker(UIL("Show it"), selection: model.binding({ DisplaySettings.syncBadgeStyle },
                                                              { DisplaySettings.syncBadgeStyle = $0 })) {
                        Text(UIL("On the icon, as in Windows")).tag(DisplaySettings.SyncBadgeStyle.onIcon)
                        Text(UIL("After the name, as in Finder")).tag(DisplaySettings.SyncBadgeStyle.afterName)
                    }
                    .disabled(!DisplaySettings.showsSyncBadges)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(UIL("Show hidden files"),
                           isOn: model.binding({ DisplaySettings.showsHiddenFiles },
                                               { DisplaySettings.showsHiddenFiles = $0 }))
                    Note(UIL("Also Cmd+Shift+period."))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(UIL("Show hidden folders in address bar completion"),
                           isOn: model.binding({ DisplaySettings.addressBarCompletionShowsHiddenFolders },
                                               { DisplaySettings.addressBarCompletionShowsHiddenFolders = $0 }))
                    Note(UIL("They come last."))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Picker(UIL("Rename and open"), selection: model.binding({ DisplaySettings.returnKeyRenames },
                                                                       { DisplaySettings.returnKeyRenames = $0 })) {
                        Text(UIL("Mac shortcuts")).tag(true)
                        Text(UIL("Windows shortcuts")).tag(false)
                    }
                    Note(UIL(DisplaySettings.returnKeyRenames
                         ? "F2 or Return renames; Cmd+Down or a double-click opens."
                         : "F2 renames; Return, Cmd+Down or a double-click opens."))
                }
            }
            Section(UIL("Windows")) {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(UIL("Reopen windows from last time"),
                           isOn: model.binding({ WindowSettings.reopensWindows }, { WindowSettings.reopensWindows = $0 }))
                    Note(UIL("At launch, and after a restart or a crash: each window where it was, its tabs, folders, "
                         + "Side by Side and preview pane. Windows you close don\u{2019}t come back."))
                }
            }
            Section(UIL("Tabs")) {
                Toggle(UIL("Use tabs"), isOn: model.binding({ WindowSettings.usesTabs }, { WindowSettings.usesTabs = $0 }))
                VStack(alignment: .leading, spacing: 4) {
                    Picker(UIL("Open folders from the desktop and other apps"),
                           selection: model.binding({ WindowSettings.opensFoldersInNewTab },
                                                    { WindowSettings.opensFoldersInNewTab = $0 })) {
                        Text(UIL("In a new tab")).tag(true)
                        Text(UIL("In a new window")).tag(false)
                    }
                    Note(UIL(WindowSettings.usesTabs
                         ? "New tabs join the window in front. File \u{203a} New Explorer Window always opens a window."
                         : "Without tabs, every folder opens in a window of its own."))
                }
                .disabled(!WindowSettings.usesTabs)
            }
            Section(UIL("Sidebar")) {
                Picker(UIL("Show"), selection: model.binding({ WindowSettings.leftSidebar },
                                                         { WindowSettings.leftSidebar = $0 })) {
                    Text(UIL("Icons and names")).tag(WindowSettings.SidebarStyle.iconsAndNames)
                    Text(UIL("Icons only")).tag(WindowSettings.SidebarStyle.icons)
                    Text(UIL("Hidden")).tag(WindowSettings.SidebarStyle.hidden)
                }
                Note(UIL("The sidebar button hides or shows it; right-click the sidebar to choose icons only. "
                     + "Side by Side, the right folder\u{2019}s sidebar has its own button and its own setting."))
                VStack(alignment: .leading, spacing: 6) {
                    Text(UIL("Show in the sidebar"))
                    LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading),
                                        GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 4) {
                        ForEach(SidebarPlace.allCases, id: \.self) { place in
                            Toggle(UIL(place.title), isOn: model.binding({ WindowSettings.sidebarPlaces.contains(place) }, {
                                var places = WindowSettings.sidebarPlaces
                                places.set(place, shown: $0)
                                WindowSettings.sidebarPlaces = places
                            }))
                            .toggleStyle(.checkbox)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(UIL("Favorites"))
                    let pinned = QuickAccessStore.shared.folders
                    if pinned.isEmpty {
                        Note(UIL("Add folders from their right-click menu, or drop them among the Favorites in the sidebar."))
                    }
                    ForEach(pinned, id: \.self) { url in
                        HStack(spacing: 6) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
                                .frame(width: 16, height: 16)
                            Text(FileManager.default.displayName(atPath: url.path))
                            Spacer()
                            Button {
                                QuickAccessStore.shared.unpin(url)
                            } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help(UIL("Remove from Favorites"))
                        }
                    }
                }
            }
            Section(UIL("Side by Side")) {
                VStack(alignment: .leading, spacing: 4) {
                    Picker(UIL("Show the two folders"),
                           selection: model.binding({ WindowSettings.sideBySideInOneWindow },
                                                    { WindowSettings.sideBySideInOneWindow = $0 })) {
                        Text(UIL("In the same window")).tag(true)
                        Text(UIL("In two windows")).tag(false)
                    }
                    Note(UIL(WindowSettings.sideBySideInOneWindow
                         ? "The Side by Side button splits the window in two; the second folder starts on the "
                           + "next tab\u{2019}s folder, or the same one. F5 copies and F6 moves the selected items to the "
                           + "other side; the arrows button swaps the sides. Click the button again to close it."
                         : "The Side by Side button opens a second window, each on half of the screen. F5 copies "
                           + "and F6 moves the selected items to the other side; the arrows button swaps the "
                           + "sides. Click the button again to close the second window."))
                }
            }
        }
        .formStyle(.grouped)
        // At least as wide as the toolbar it shows, so the mock is never cut.
        .frame(height: Self.height)
    }
}
