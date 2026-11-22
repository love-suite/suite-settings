import AppKit
import BindingsCore
import SuiteCore
import SwiftUI

/// The shortcuts that exist: every app's menu shortcuts, as Bindings read them, which can be
/// turned off or given another chord in that app; and macOS' own, which only System Settings can
/// change. Opened from Settings › Bindings.
enum ShortcutsWindow {
    private static var controller: NSWindowController?

    static func show(model: BindingsSettingsModel) {
        if controller == nil {
            let host = NSHostingController(rootView: ShortcutsBrowser(model: model, catalog: ShortcutCatalogModel()))
            let window = NSWindow(contentViewController: host)
            window.title = UIL("Shortcuts")
            window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            window.setContentSize(NSSize(width: 820, height: 580))
            window.contentMinSize = NSSize(width: 640, height: 400)
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("BindingsShortcuts")
            window.center()
            controller = NSWindowController(window: window)
        }
        NSApp.activate(ignoringOtherApps: true)
        controller?.showWindow(nil)
    }
}

/// The apps' menus Bindings has read (`MenuCatalog`), and the readings under way.
final class ShortcutCatalogModel: ObservableObject {
    let catalog: MenuCatalog
    @Published private(set) var apps: [AppMenus] = []
    @Published private(set) var reading: Set<String> = []
    @Published private(set) var failed: Set<String> = []
    private var observers: [NSObjectProtocol] = []

    init(catalog: MenuCatalog = MenuCatalog()) {
        self.catalog = catalog
        reload()
        observers.append(BindingsMessage.menusDidChange.observe { [weak self] note in
            guard let self, let id = note.userInfo?[BindingsMessage.bundleIDKey] as? String else { return }
            reading.remove(id)
            if note.userInfo?[BindingsMessage.failedKey] as? Bool == true { failed.insert(id) } else { failed.remove(id) }
            reload()
        })
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.objectWillChange.send()
            })
        }
    }

    func reload() {
        apps = catalog.all()
    }

    func menus(_ bundleID: String) -> AppMenus? {
        apps.first { $0.bundleID == bundleID }
    }

    static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// Asks Bindings to read a running app's menus, starting Bindings first if needed.
    func read(_ bundleID: String) {
        reading.insert(bundleID)
        failed.remove(bundleID)
        let ask = { BindingsMessage.scanMenus.post([BindingsMessage.bundleIDKey: bundleID]) }
        if BindingsApp.isRunning {
            ask()
        } else {
            BindingsApp.launch()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: ask)
        }
        // No answer (Bindings off or stuck): stop waiting.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, reading.contains(bundleID) else { return }
            reading.remove(bundleID)
            failed.insert(bundleID)
        }
    }

    /// Running apps whose menus haven't been read yet.
    var unreadApps: [(id: String, name: String)] {
        BindingsApps.running(excluding: apps.map(\.bundleID) + [BindingsSettings.bundleID])
    }
}

struct ShortcutsBrowser: View {
    static let system = "#system"

    @ObservedObject var model: BindingsSettingsModel
    @ObservedObject var catalog: ShortcutCatalogModel
    @State private var selection: String?
    @State private var search = ""
    @State private var showsItemsWithoutShortcut = false

    init(model: BindingsSettingsModel, catalog: ShortcutCatalogModel, selection: String = ShortcutsBrowser.system,
         showsItemsWithoutShortcut: Bool = false) {
        self.model = model
        self.catalog = catalog
        _selection = State(initialValue: selection)
        _showsItemsWithoutShortcut = State(initialValue: showsItemsWithoutShortcut)
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
        } detail: {
            VStack(spacing: 0) {
                if !model.settings.canListen {
                    accessBanner
                }
                if let error = model.loadError {
                    Text(String(format: UIL("The rules file can't be read: %@ Fix it in Settings \u{203A} Bindings first."), error))
                        .foregroundStyle(.orange).padding()
                }
                if selection == Self.system {
                    SystemShortcutsView(search: search)
                } else if let id = selection {
                    AppShortcutsView(model: model, catalog: catalog, bundleID: id, search: search,
                                     showsItemsWithoutShortcut: $showsItemsWithoutShortcut)
                }
            }
            .searchable(text: $search, placement: .toolbar, prompt: Text(UIL("Search shortcuts")))
        }
        .onAppear {
            model.reload()
            catalog.reload()
        }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Section(UIL("macOS")) {
                Label(UIL("System Shortcuts"), systemImage: "command").tag(Self.system)
            }
            Section(UIL("Apps")) {
                ForEach(catalog.apps, id: \.bundleID) { app in
                    Label {
                        Text(app.name)
                    } icon: {
                        AppIconView(bundleID: app.bundleID)
                    }
                    .tag(app.bundleID)
                }
                if catalog.apps.isEmpty {
                    Text(UIL("Apps appear here as you use them.")).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Menu {
                    ForEach(catalog.unreadApps, id: \.id) { app in
                        Button(app.name) {
                            catalog.read(app.id)
                            selection = app.id
                        }
                    }
                } label: {
                    Label(UIL("Add App"), systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(UIL("Read the menus of a running app"))
                Spacer()
            }
            .padding(10)
        }
    }

    private var accessBanner: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(UIL("Bindings needs Accessibility access to read the apps' menus and to change their shortcuts."))
                .lineLimit(2)
            Spacer()
            Button(UIL("Open Accessibility Settings")) { BindingsApp.requestAccessibility() }
        }
        .padding(12)
        .background(.orange.opacity(0.1))
    }
}

// MARK: An app's menu shortcuts

private struct AppShortcutsView: View {
    @ObservedObject var model: BindingsSettingsModel
    @ObservedObject var catalog: ShortcutCatalogModel
    let bundleID: String
    let search: String
    @Binding var showsItemsWithoutShortcut: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let menus = catalog.menus(bundleID) {
                let sections = filtered(menus)
                if sections.isEmpty {
                    placeholder(search.isEmpty ? UIL("No menu item with a shortcut.")
                                : String(format: UIL("No shortcut matches \u{201C}%@\u{201D}."), search))
                } else {
                    List {
                        ForEach(sections, id: \.name) { section in
                            Section(section.name) {
                                ForEach(section.items) { item in
                                    MenuShortcutRow(model: model, item: item, bundleID: bundleID)
                                }
                            }
                        }
                    }
                }
            } else if catalog.reading.contains(bundleID) {
                placeholder(UIL("Reading the menus"))
            } else {
                placeholder(catalog.failed.contains(bundleID)
                            ? UIL("The menus couldn't be read. Is Bindings allowed in Accessibility settings?")
                            : UIL("The menus haven't been read yet."))
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            AppIconView(bundleID: bundleID, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(catalog.menus(bundleID)?.name ?? BindingsApps.name(bundleID)).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(UIL("Items without a shortcut"), isOn: $showsItemsWithoutShortcut)
                .toggleStyle(.checkbox)
                .help(UIL("Also list menu items that have no shortcut, to give them one"))
            if catalog.reading.contains(bundleID) {
                ProgressView().controlSize(.small)
            } else if ShortcutCatalogModel.isRunning(bundleID) {
                Button(UIL("Read Again")) { catalog.read(bundleID) }
                    .help(UIL("Read the app's menus again, after an update or a change of language"))
            }
        }
        .padding(12)
    }

    private var subtitle: String {
        guard let menus = catalog.menus(bundleID) else { return "" }
        let date = RelativeDateTimeFormatter().localizedString(for: menus.date, relativeTo: Date())
        let changed = model.rules.filter { MenuShortcutEditor.override(of: $0, app: bundleID, in: menus) }.count
        var text = String(format: UIL("Menus read %@"), date)
        if changed > 0 { text += " \u{00B7} " + String(format: UIL("%d changed"), changed) }
        if !ShortcutCatalogModel.isRunning(bundleID) { text += " \u{00B7} " + UIL("open it to read them again") }
        return text
    }

    private func filtered(_ menus: AppMenus) -> [(name: String, items: [MenuShortcut])] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return menus.menus.compactMap { section in
            let items = section.items.filter { item in
                let changed = MenuShortcutEditor.override(of: item, in: bundleID, rules: model.rules) != .none
                guard item.chord != nil || showsItemsWithoutShortcut || changed else { return false }
                guard !query.isEmpty else { return true }
                return item.path.joined(separator: " ").localizedCaseInsensitiveContains(query)
                    || (item.chord.map(BindingsKeyboard.name)?.localizedCaseInsensitiveContains(query) ?? false)
            }
            return items.isEmpty ? nil : (section.name, items)
        }
    }

    private func placeholder(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

private extension MenuShortcutEditor {
    /// Whether a rule is one of the changes made to this app's menus.
    static func override(of rule: BindingRule, app: String, in menus: AppMenus) -> Bool {
        menus.items.contains { override(of: $0, in: app, rules: [rule]) != .none }
    }
}

private struct MenuShortcutRow: View {
    @ObservedObject var model: BindingsSettingsModel
    let item: MenuShortcut
    let bundleID: String

    var body: some View {
        let state = MenuShortcutEditor.override(of: item, in: bundleID, rules: model.rules)
        HStack(spacing: 10) {
            if item.chord != nil {
                Toggle("", isOn: Binding(get: { state.isActive },
                                         set: { model.setMenuShortcut(item, in: bundleID, active: $0) }))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .help(state.isActive ? UIL("Turn this shortcut off in this app") : UIL("Turn this shortcut back on"))
            } else {
                Color.clear.frame(width: 14, height: 1)
            }
            Text(item.title)
                .foregroundStyle(item.chord == nil && state == .none ? .secondary : .primary)
                .lineLimit(1)
            Spacer()
            warnings(state)
            chords(state)
            if state != .none {
                Button { model.rebindMenuShortcut(item, in: bundleID, to: nil) } label: {
                    Image(systemName: "arrow.uturn.backward.circle")
                }
                .buttonStyle(.borderless)
                .help(item.chord.map { String(format: UIL("Back to %@"), BindingsKeyboard.name($0)) } ?? UIL("Remove the shortcut"))
            }
        }
        .opacity(state.isActive ? 1 : 0.55)
    }

    @ViewBuilder
    private func chords(_ state: ShortcutOverride) -> some View {
        switch state {
        case .rebound(_, let chord):
            if let own = item.chord {
                Text(BindingsKeyboard.name(own)).strikethrough().foregroundStyle(.secondary)
            }
            recorder(chord)
        case .added(_, let chord):
            recorder(chord)
        case .disabled, .none:
            recorder(item.chord)
        }
    }

    private func recorder(_ chord: KeyChord?) -> some View {
        ChordButton(chord: chord, placeholder: UIL("Add Shortcut")) { model.rebindMenuShortcut(item, in: bundleID, to: $0) }
    }

    @ViewBuilder
    private func warnings(_ state: ShortcutOverride) -> some View {
        if let rule = state.rule, state.isActive {
            let issues = model.conflicts.issues(for: rule).filter(\.isWarning)
            if !issues.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .help(issues.map(BindingsText.issue).joined(separator: "\n"))
            }
        }
    }
}

/// A chord shown as a button: a click records a new one.
struct ChordButton: View {
    let chord: KeyChord?
    let placeholder: String
    let onRecord: (KeyChord) -> Void
    @StateObject private var recorder = ChordRecorder()

    var body: some View {
        Button {
            recorder.isRecording ? recorder.stop() : recorder.start(onRecord)
        } label: {
            Text(text)
                .font(chord == nil && !recorder.isRecording ? .callout : .system(.body, design: .rounded))
                .frame(minWidth: 90)
        }
        .help(UIL("Click, then press the new shortcut. Escape stops."))
        .onDisappear { recorder.stop() }
    }

    private var text: String {
        if recorder.isRecording {
            return BindingsText.recording(recorder.heldModifiers, prompt: UIL("Press"))
        }
        return chord.map(BindingsKeyboard.name) ?? placeholder
    }
}

// MARK: macOS' shortcuts

private struct SystemShortcutsView: View {
    let search: String

    private var shortcuts: [KnownShortcut] {
        let hotKeys = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys")
        let query = search.trimmingCharacters(in: .whitespaces)
        return KnownShortcuts.system(symbolicHotKeys: hotKeys)
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || name($0).localizedCaseInsensitiveContains(query) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "command").font(.title2).frame(width: 32)
                VStack(alignment: .leading, spacing: 4) {
                    Text(UIL("System Shortcuts")).font(.headline)
                    Text(UIL("macOS handles these before apps and Bindings see them, so they are turned off or "
                             + "changed in System Settings. A rule of yours on one of them is flagged."))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
                Spacer()
                Button(UIL("Open Keyboard Shortcuts")) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                }
            }
            .padding(12)
            Divider()
            List(shortcuts, id: \.self) { shortcut in
                HStack {
                    Text(shortcut.name)
                    Spacer()
                    Text(name(shortcut)).font(.system(.body, design: .rounded)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func name(_ shortcut: KnownShortcut) -> String {
        switch shortcut.key {
        case .code(let code): return BindingsKeyboard.name(KeyChord(keyCode: code, modifiers: shortcut.modifiers))
        case .character(let character): return shortcut.modifiers.symbols + character.uppercased()
        }
    }
}

struct AppIconView: View {
    let bundleID: String
    var size: CGFloat = 18

    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: size, height: size)
        } else {
            Image(systemName: "app.dashed").frame(width: size, height: size)
        }
    }
}
