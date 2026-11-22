import AppKit
import BindingsCore
import Carbon
import SuiteCore
import SwiftUI

// Settings › Bindings: the rules of Bindings, the keyboard shortcuts app, read and written through
// BindingsCore (the rules file, Bindings' settings); Bindings is told with `BindingsMessage` (SuiteCore).
// The tab shows only when Bindings is installed (`BindingsApp.appURL`).

/// What each key types in the current keyboard layout, to name keys as the keyboard shows them.
enum BindingsKeyboard {
    /// With ⌘ held, as menus read keys: on AZERTY the "&" key is ⌘1.
    static func character(_ keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> String? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var deadKeys: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDisplay), UInt32(cmdKey >> 8) & 0xFF,
                                        UInt32(LMGetKbdType()),
                                        OptionBits(1 << kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count,
                                        &length, &chars)
            guard status == noErr, length > 0 else { return nil }
            let string = String(utf16CodeUnits: chars, count: length)
            return string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : string
        }
    }

    static func name(_ chord: KeyChord) -> String {
        chord.displayName(character: character)
    }
}

enum BindingsApps {
    static func name(_ bundleID: String) -> String {
        if let name = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName {
            return name
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    static func names(_ ids: [String]) -> String {
        ListFormatter.localizedString(byJoining: ids.map(name))
    }

    /// Running apps with a Dock icon, the likely ones to pick.
    static func running(excluding ids: [String]) -> [(id: String, name: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in app.bundleIdentifier.map { ($0, app.localizedName ?? $0) } }
            .filter { !ids.contains($0.0) }
            .sorted { $0.1.localizedStandardCompare($1.1) == .orderedAscending }
    }

    static func choose() -> [String] {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = UIL("Choose")
        guard panel.runModal() == .OK else { return [] }
        return panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
    }
}

// MARK: Model

/// The Bindings tab's state: the rules file, Bindings' settings and what it reports about itself.
final class BindingsSettingsModel: ObservableObject {
    let settings = BindingsSettings.forManager()
    let store: BindingsStore
    @Published private(set) var rules: [BindingRule] = []
    /// The rules file can't be read: nothing is written over it until it is fixed.
    @Published private(set) var loadError: String?
    @Published var saveError: String?
    @Published private(set) var shortcutNames: [String] = []
    private var observers: [NSObjectProtocol] = []

    init(store: BindingsStore = BindingsStore()) {
        self.store = store
        reload()
        observers.append(BindingsMessage.statusDidChange.observe { [weak self] _ in
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

    func reload() {
        do {
            rules = try store.load()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    var conflicts: BindingConflicts {
        let hotKeys = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys")
        return BindingConflicts(rules: rules, known: KnownShortcuts.system(symbolicHotKeys: hotKeys) + KnownShortcuts.apps,
                                character: BindingsKeyboard.character)
    }

    func rules(at level: BindingLevel) -> [BindingRule] {
        rules.filter { $0.scope.level == level }
    }

    private func save(_ newRules: [BindingRule]) {
        guard loadError == nil else { return }
        do {
            try store.save(newRules)
            rules = newRules
            saveError = nil
            BindingsMessage.rulesDidChange.post()
        } catch {
            saveError = error.localizedDescription
        }
    }

    func put(_ rule: BindingRule) {
        var newRules = rules
        if let index = newRules.firstIndex(where: { $0.id == rule.id }) {
            newRules[index] = rule
        } else {
            newRules.append(rule)
        }
        save(newRules)
    }

    func remove(_ rule: BindingRule) {
        save(rules.filter { $0.id != rule.id })
    }

    /// Turns an app's menu shortcut on or off in that app (a rule at the app level).
    func setMenuShortcut(_ item: MenuShortcut, in app: String, active: Bool) {
        save(MenuShortcutEditor.setActive(active, item: item, app: app, rules: rules))
    }

    /// Gives an app's menu item another shortcut in that app, or back its own (nil).
    func rebindMenuShortcut(_ item: MenuShortcut, in app: String, to chord: KeyChord?) {
        save(MenuShortcutEditor.rebind(item, app: app, to: chord, rules: rules))
    }

    func setEnabled(_ rule: BindingRule, _ on: Bool) {
        var changed = rule
        changed.isEnabled = on
        put(changed)
    }

    /// Up or down among the rules of its level, which decides which of two clashing rules wins.
    func move(_ rule: BindingRule, by offset: Int) {
        let sameLevel = rules(at: rule.scope.level)
        guard let position = sameLevel.firstIndex(of: rule), sameLevel.indices.contains(position + offset),
              let from = rules.firstIndex(of: rule),
              let to = rules.firstIndex(of: sameLevel[position + offset]) else { return }
        var newRules = rules
        newRules.swapAt(from, to)
        save(newRules)
    }

    var isEnabled: Binding<Bool> {
        Binding(get: { self.settings.isEnabled }, set: { on in
            self.objectWillChange.send()
            self.settings.isEnabled = on
            on ? BindingsApp.launch() : BindingsMessage.settingsDidChange.post()
        })
    }

    /// Shown in the folder viewer, which is Explorer while Explorer is in use.
    func revealRulesFile() {
        if !FileManager.default.fileExists(atPath: store.fileURL.path) { try? store.save(rules) }
        NSWorkspace.shared.activateFileViewerSelecting([store.fileURL])
    }

    /// The user's shortcuts from the Shortcuts app, for the "Run a shortcut" menu.
    func loadShortcutNames() {
        guard shortcutNames.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            process.arguments = ["list"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let names = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
                .filter { !$0.isEmpty }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            DispatchQueue.main.async { self?.shortcutNames = names }
        }
    }
}

// MARK: Describing rules

enum BindingsText {
    static func title(_ rule: BindingRule) -> String {
        rule.name.isEmpty ? action(rule.action) : rule.name
    }

    static func action(_ action: BindingAction) -> String {
        switch action {
        case .remap(let chord): return String(format: UIL("Press %@"), BindingsKeyboard.name(chord))
        case .openApp(let id): return String(format: UIL("Open %@"), BindingsApps.name(id))
        case .openFolder(let path):
            return String(format: UIL("Open \u{201C}%@\u{201D} in Explorer"), (path as NSString).lastPathComponent)
        case .runShortcut(let name): return String(format: UIL("Run the \u{201C}%@\u{201D} shortcut"), name)
        case .shellCommand(let command):
            // Its first line; the row cuts it short where it doesn't fit.
            let line = command.split(separator: "\n").first.map(String.init) ?? command
            return String(format: UIL("Run \u{201C}%@\u{201D}"), line)
        case .menuItem(let path): return String(format: UIL("Choose %@"), BindingAction.menuText(path))
        case .disable: return UIL("Do nothing")
        }
    }

    static func scope(_ scope: BindingScope) -> String {
        switch scope.level {
        case .everywhere:
            return scope.excludedApps.isEmpty
                ? UIL("Everywhere")
                : String(format: UIL("Everywhere except in %@"), BindingsApps.names(scope.excludedApps))
        case .apps:
            return String(format: UIL("In %@"), BindingsApps.names(scope.apps))
        case .context:
            var parts: [String] = []
            switch scope.explorer {
            case .desktop?: parts.append(UIL("on Explorer's desktop"))
            case .folderWindow?: parts.append(UIL("in Explorer windows"))
            case .otherWindow?: parts.append(UIL("in Explorer's other windows"))
            case nil:
                if !scope.apps.isEmpty { parts.append(String(format: UIL("in %@"), BindingsApps.names(scope.apps))) }
            }
            switch scope.focus {
            case .textField?: parts.append(UIL("while typing in a text field"))
            case .notTextField?: parts.append(UIL("when not typing"))
            case nil: break
            }
            if let title = scope.windowTitle, !title.trimmingCharacters(in: .whitespaces).isEmpty {
                parts.append(String(format: UIL("in windows titled \u{201C}%@\u{201D}"),
                                    title.trimmingCharacters(in: .whitespaces)))
            }
            let text = parts.joined(separator: ", ")
            return text.prefix(1).uppercased() + text.dropFirst()
        }
    }

    static func issue(_ issue: BindingIssue) -> String {
        switch issue {
        case .clash(let other):
            return String(format: UIL("\u{201C}%@\u{201D} uses the same shortcut where both apply: only the one "
                                      + "higher in the list runs."), title(other))
        case .overrides(let other):
            return String(format: UIL("Takes the place of \u{201C}%@\u{201D} (%@) here."), title(other),
                          scope(other.scope).lowercased())
        case .overriddenBy(let other):
            return String(format: UIL("\u{201C}%@\u{201D} takes its place %@."), title(other),
                          scope(other.scope).lowercased())
        case .system(let name):
            return String(format: UIL("macOS uses this shortcut for \u{201C}%@\u{201D}. Change one of the two "
                                      + "(System Settings \u{203A} Keyboard \u{203A} Keyboard Shortcuts) or this "
                                      + "one may never come."), name)
        case .appShortcut(let name, let everywhere):
            return everywhere
                ? String(format: UIL("Most apps use this shortcut for %@: this rule takes it from all of them."), name)
                : String(format: UIL("Takes the place of the app's own %@ shortcut, if it has one."), name)
        case .clipboardHold:
            return UIL("Holding \u{2318}V opens Clipboard's history: where this rule applies, \u{2318}V is this "
                       + "rule's instead.")
        case .typing:
            return UIL("This key types text: it would no longer type in text fields. Add \u{2318}, \u{2303} or fn, "
                       + "or choose \u{201C}When not typing\u{201D} in a context.")
        }
    }

    static func problem(_ problem: BindingProblem) -> String {
        switch problem {
        case .noShortcut: return UIL("Record a shortcut.")
        case .noApps: return UIL("Add at least one app.")
        case .noCondition: return UIL("Choose at least one condition.")
        case .emptyAction: return UIL("Say what it does.")
        case .remapsToItself: return UIL("Choose another shortcut to press.")
        }
    }

    /// While a chord is being recorded: the modifiers held so far, or an invitation to press one.
    static func recording(_ held: Modifiers, prompt: String) -> String {
        held.isEmpty ? prompt : held.symbols
    }
}

// MARK: The tab

struct BindingsSettingsView: View {
    @ObservedObject var model: BindingsSettingsModel
    @State private var editing: RuleDraft?
    static let height: CGFloat = 540

    var body: some View {
        Form {
            Section {
                Toggle(isOn: model.isEnabled) {
                    Text(UIL("Use my own keyboard shortcuts"))
                    Text(UIL("Bindings runs your shortcuts in every app, in some apps, or in a context: while typing, "
                             + "on Explorer's desktop, in a window. It can press other keys, open apps and folders, "
                             + "run shortcuts and commands, or choose menu items."))
                }
            }
            if model.settings.isEnabled {
                access
                if let error = model.loadError {
                    Section {
                        Label {
                            Text(String(format: UIL("The rules file can't be read: %@ Fix it, or move it away, then "
                                                    + "click Reload."), error))
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                        HStack {
                            Button(UIL("Show Rules File")) { model.revealRulesFile() }
                            Button(UIL("Reload")) { model.reload() }
                        }
                    }
                } else {
                    ForEach(BindingLevel.allCases, id: \.self) { level in
                        levelSection(level)
                    }
                    Section {
                        HStack {
                            Button(UIL("Add Shortcut")) { editing = RuleDraft() }
                            Button(UIL("Browse Shortcuts")) { ShortcutsWindow.show(model: model) }
                                .help(UIL("The shortcuts of your apps' menus and of macOS, to turn off or change"))
                            Spacer()
                            Button(UIL("Show Rules File")) { model.revealRulesFile() }
                                .help(UIL("bindings.json, which can be edited by hand as Karabiner's file can"))
                        }
                        if let error = model.saveError {
                            Note(String(format: UIL("The rules could not be saved: %@"), error))
                        }
                    } footer: {
                        Note(UIL("Where several rules use the same shortcut, the most specific wins: a context over "
                                 + "an app, an app over everywhere."))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: model.settings.isEnabled ? Self.height : nil)
        .onAppear { model.reload() }
        .sheet(item: $editing) { draft in
            RuleEditor(model: model, draft: draft) { editing = nil }
        }
    }

    private var access: some View {
        Section {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: model.settings.canListen ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(model.settings.canListen ? .green : .orange)
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.settings.canListen
                         ? UIL("Bindings sees the keys you press, and lets through those no rule uses.")
                         : UIL("Bindings needs Accessibility access to see the keys you press. Until then, no shortcut "
                               + "of yours works and every key does what it always did."))
                        .fixedSize(horizontal: false, vertical: true)
                    if !model.settings.canListen {
                        Button(UIL("Open Accessibility Settings")) { BindingsApp.requestAccessibility() }
                    }
                }
            }
        }
    }

    private func header(_ level: BindingLevel) -> String {
        switch level {
        case .everywhere: return UIL("Everywhere")
        case .apps: return UIL("In Apps")
        case .context: return UIL("In a Context")
        }
    }

    @ViewBuilder
    private func levelSection(_ level: BindingLevel) -> some View {
        let rules = model.rules(at: level)
        Section {
            if rules.isEmpty {
                Note(emptyText(level))
            }
            ForEach(rules) { rule in
                RuleRow(rule: rule, issues: rule.isEnabled ? model.conflicts.issues(for: rule) : [],
                        isFirst: rule == rules.first, isLast: rule == rules.last, model: model) {
                    editing = RuleDraft(rule)
                }
            }
        } header: {
            Text(header(level))
        }
    }

    private func emptyText(_ level: BindingLevel) -> String {
        switch level {
        case .everywhere: return UIL("No shortcut in every app yet.")
        case .apps: return UIL("No shortcut for given apps yet.")
        case .context: return UIL("No shortcut for a context yet: while typing, on the desktop, in a window.")
        }
    }
}

private struct RuleRow: View {
    let rule: BindingRule
    let issues: [BindingIssue]
    let isFirst: Bool
    let isLast: Bool
    @ObservedObject var model: BindingsSettingsModel
    let edit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Toggle("", isOn: Binding(get: { rule.isEnabled }, set: { model.setEnabled(rule, $0) }))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .help(rule.isEnabled ? UIL("Turn this shortcut off") : UIL("Turn this shortcut on"))
                ChordBadge(chord: rule.trigger)
                VStack(alignment: .leading, spacing: 2) {
                    Text(BindingsText.title(rule)).lineLimit(1)
                    Text(subtitle)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                .opacity(rule.isEnabled ? 1 : 0.5)
                Spacer()
                if let problem = rule.problem {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
                        .help(BindingsText.problem(problem) + " " + UIL("This rule does nothing until then."))
                }
                Menu {
                    Button(UIL("Edit"), action: edit)
                    Button(UIL("Move Up")) { model.move(rule, by: -1) }.disabled(isFirst)
                    Button(UIL("Move Down")) { model.move(rule, by: 1) }.disabled(isLast)
                    Divider()
                    Button(UIL("Remove")) { model.remove(rule) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: edit)
            IssueList(issues: issues)
        }
    }

    private var subtitle: String {
        let scope = BindingsText.scope(rule.scope)
        guard let replaced = rule.replacedChord else { return scope }
        return String(format: UIL("%@, instead of %@"), scope, BindingsKeyboard.name(replaced))
    }
}

struct IssueList: View {
    let issues: [BindingIssue]

    var body: some View {
        ForEach(issues, id: \.self) { issue in
            Label {
                Text(BindingsText.issue(issue)).font(.callout).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: issue.isWarning ? "exclamationmark.triangle.fill" : "info.circle")
                    .foregroundStyle(issue.isWarning ? .orange : .secondary)
            }
            .foregroundStyle(issue.isWarning ? .primary : .secondary)
        }
    }
}

private struct ChordBadge: View {
    let chord: KeyChord

    var body: some View {
        Text(BindingsKeyboard.name(chord))
            .font(.system(.body, design: .rounded).monospaced())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .frame(minWidth: 56)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.15)))
    }
}

private struct Note: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: Recording a chord

/// Records the next chord pressed while Suite Settings is in front. Bindings is paused meanwhile, so a
/// chord a rule already uses reaches Settings rather than running the rule. Escape alone stops recording.
final class ChordRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var heldModifiers: Modifiers = []
    private var monitor: Any?
    private var onRecord: ((KeyChord) -> Void)?

    func start(_ onRecord: @escaping (KeyChord) -> Void) {
        stop()
        self.onRecord = onRecord
        isRecording = true
        heldModifiers = []
        BindingsMessage.setPaused.post([BindingsMessage.pausedKey: true])
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            let modifiers = Self.modifiers(of: event.modifierFlags)
            if event.type == .flagsChanged {
                heldModifiers = modifiers
                return event
            }
            if event.keyCode == KeyCode.escape && modifiers.isEmpty {
                stop()
                return nil
            }
            let record = self.onRecord
            stop()
            record?(KeyChord(keyCode: event.keyCode, modifiers: modifiers))
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        onRecord = nil
        if isRecording {
            isRecording = false
            BindingsMessage.setPaused.post([BindingsMessage.pausedKey: false])
        }
    }

    deinit { stop() }

    static func modifiers(of flags: NSEvent.ModifierFlags) -> Modifiers {
        var modifiers: Modifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.function) { modifiers.insert(.function) }
        return modifiers
    }
}

private struct ChordField: View {
    let label: String
    @Binding var chord: KeyChord?
    @StateObject private var recorder = ChordRecorder()

    var body: some View {
        LabeledContent(label) {
            Button {
                recorder.isRecording ? recorder.stop() : recorder.start { chord = $0 }
            } label: {
                Text(text).frame(minWidth: 130)
            }
            .help(UIL("Click, then press the shortcut. Escape stops."))
        }
        .onDisappear { recorder.stop() }
    }

    private var text: String {
        if recorder.isRecording {
            return BindingsText.recording(recorder.heldModifiers, prompt: UIL("Press a shortcut"))
        }
        return chord.map(BindingsKeyboard.name) ?? UIL("Record Shortcut")
    }
}

// MARK: Editing a rule

/// A rule being edited: every field of every level and action, so switching back and forth keeps
/// what was typed.
struct RuleDraft: Identifiable {
    var id = UUID()
    var name = ""
    var trigger: KeyChord?
    var isEnabled = true
    var level: BindingLevel = .everywhere
    var apps: [String] = []
    var excludedApps: [String] = []
    var focus: FocusCondition?
    var explorer: ExplorerContext?
    var windowTitle = ""
    var kind: BindingAction.Kind = .remap
    var remapTarget: KeyChord?
    var appID = ""
    var folderPath = ""
    var shortcutName = ""
    var command = ""
    var menuText = ""

    init() {}

    init(_ rule: BindingRule) {
        id = rule.id
        name = rule.name
        trigger = rule.trigger
        isEnabled = rule.isEnabled
        level = rule.scope.level
        apps = rule.scope.apps
        excludedApps = rule.scope.excludedApps
        focus = rule.scope.focus
        explorer = rule.scope.explorer
        windowTitle = rule.scope.windowTitle ?? ""
        kind = rule.action.kind
        switch rule.action {
        case .remap(let chord): remapTarget = chord
        case .openApp(let id): appID = id
        case .openFolder(let path): folderPath = path
        case .runShortcut(let name): shortcutName = name
        case .shellCommand(let text): command = text
        case .menuItem(let path): menuText = BindingAction.menuText(path)
        case .disable: break
        }
    }

    var action: BindingAction {
        switch kind {
        case .remap: return .remap(remapTarget ?? trigger ?? KeyChord(keyCode: 0))
        case .openApp: return .openApp(bundleID: appID)
        case .openFolder: return .openFolder(path: folderPath.trimmingCharacters(in: .whitespaces))
        case .runShortcut: return .runShortcut(name: shortcutName.trimmingCharacters(in: .whitespaces))
        case .shellCommand: return .shellCommand(command)
        case .menuItem: return .menuItem(BindingAction.menuPath(from: menuText))
        case .disable: return .disable
        }
    }

    var scope: BindingScope {
        switch level {
        case .everywhere: return BindingScope(level: .everywhere, excludedApps: excludedApps)
        case .apps: return .apps(apps)
        case .context:
            return .context(apps: explorer == nil ? apps : [], focus: focus, explorer: explorer,
                            windowTitle: windowTitle.trimmingCharacters(in: .whitespaces).isEmpty ? nil : windowTitle)
        }
    }

    /// Nil until a shortcut is recorded.
    var rule: BindingRule? {
        trigger.map {
            BindingRule(id: id, name: name.trimmingCharacters(in: .whitespaces), trigger: $0, action: action,
                        scope: scope, isEnabled: isEnabled)
        }
    }
}

struct RuleEditor: View {
    @ObservedObject var model: BindingsSettingsModel
    @State var draft: RuleDraft
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    ChordField(label: UIL("Shortcut"), chord: $draft.trigger)
                    TextField(UIL("Name"), text: $draft.name, prompt: Text(UIL("Optional")))
                }
                whereSection
                actionSection
                issuesSection
            }
            .formStyle(.grouped)
            HStack {
                if let problem = problem {
                    Text(BindingsText.problem(problem)).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button(UIL("Cancel"), role: .cancel, action: close).keyboardShortcut(.cancelAction)
                Button(UIL("Save")) {
                    if let rule = draft.rule { model.put(rule) }
                    close()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(problem != nil)
            }
            .padding()
        }
        .frame(width: 500, height: 600)
    }

    private var problem: BindingProblem? {
        draft.rule.map { $0.problem } ?? .noShortcut
    }

    private var whereSection: some View {
        Section(UIL("Where")) {
            Picker(UIL("Applies"), selection: $draft.level) {
                Text(UIL("Everywhere")).tag(BindingLevel.everywhere)
                Text(UIL("In Apps")).tag(BindingLevel.apps)
                Text(UIL("In a Context")).tag(BindingLevel.context)
            }
            .pickerStyle(.segmented)
            switch draft.level {
            case .everywhere:
                AppList(title: UIL("Except in"), ids: $draft.excludedApps)
            case .apps:
                AppList(title: UIL("In"), ids: $draft.apps)
            case .context:
                Picker(UIL("In Explorer"), selection: $draft.explorer) {
                    Text(UIL("Any")).tag(ExplorerContext?.none)
                    Text(UIL("On the desktop")).tag(ExplorerContext?.some(.desktop))
                    Text(UIL("In a folder window")).tag(ExplorerContext?.some(.folderWindow))
                    Text(UIL("In another window")).tag(ExplorerContext?.some(.otherWindow))
                }
                Picker(UIL("Keyboard focus"), selection: $draft.focus) {
                    Text(UIL("Any")).tag(FocusCondition?.none)
                    Text(UIL("While typing in a text field")).tag(FocusCondition?.some(.textField))
                    Text(UIL("When not typing")).tag(FocusCondition?.some(.notTextField))
                }
                TextField(UIL("Window title contains"), text: $draft.windowTitle, prompt: Text(UIL("Any window")))
                if draft.explorer == nil {
                    AppList(title: UIL("Only in"), ids: $draft.apps)
                }
            }
        }
    }

    private var actionSection: some View {
        Section(UIL("Does")) {
            Picker(UIL("Action"), selection: $draft.kind) {
                Text(UIL("Press another shortcut")).tag(BindingAction.Kind.remap)
                Text(UIL("Open an app")).tag(BindingAction.Kind.openApp)
                Text(UIL("Open a folder in Explorer")).tag(BindingAction.Kind.openFolder)
                Text(UIL("Run a shortcut")).tag(BindingAction.Kind.runShortcut)
                Text(UIL("Run a shell command")).tag(BindingAction.Kind.shellCommand)
                Text(UIL("Choose a menu item")).tag(BindingAction.Kind.menuItem)
                Text(UIL("Nothing (turn the shortcut off)")).tag(BindingAction.Kind.disable)
            }
            actionDetail
        }
    }

    @ViewBuilder
    private var actionDetail: some View {
        switch draft.kind {
        case .remap:
            ChordField(label: UIL("Press instead"), chord: $draft.remapTarget)
            Note(UIL("Held down, it repeats as the other shortcut would."))
        case .openApp:
            LabeledContent(UIL("App")) {
                Menu(draft.appID.isEmpty ? UIL("Choose") : BindingsApps.name(draft.appID)) {
                    ForEach(BindingsApps.running(excluding: []), id: \.id) { app in
                        Button(app.name) { draft.appID = app.id }
                    }
                    Divider()
                    Button(UIL("Other App")) { if let id = BindingsApps.choose().first { draft.appID = id } }
                }
                .fixedSize()
            }
            Note(UIL("Opens it, or brings it to the front when it is open."))
        case .openFolder:
            HStack {
                TextField(UIL("Folder"), text: $draft.folderPath, prompt: Text(verbatim: "~/Documents"))
                Button(UIL("Choose")) { chooseFolder() }
            }
        case .runShortcut:
            HStack {
                TextField(UIL("Shortcut"), text: $draft.shortcutName, prompt: Text(UIL("Its name in Shortcuts")))
                Menu("") {
                    ForEach(model.shortcutNames, id: \.self) { name in Button(name) { draft.shortcutName = name } }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(model.shortcutNames.isEmpty)
            }
            .onAppear { model.loadShortcutNames() }
        case .shellCommand:
            TextField(UIL("Command"), text: $draft.command, prompt: Text(verbatim: "open -a Safari"), axis: .vertical)
                .lineLimit(1...4)
                .font(.system(.body, design: .monospaced))
            Note(UIL("Runs in your login shell (zsh), from your home folder, without a window."))
        case .menuItem:
            TextField(UIL("Menu item"), text: $draft.menuText, prompt: Text(UIL("File \u{203A} New Window")))
            Note(UIL("The titles from the menu bar down, as the app in front shows them, separated by \u{203A} or >. "
                     + "It beeps when the app has no such item."))
        case .disable:
            Note(UIL("Where the rule applies, the shortcut does nothing and the app in front doesn't get it."))
        }
    }

    @ViewBuilder
    private var issuesSection: some View {
        if let rule = draft.rule, rule.problem == nil {
            let others = model.rules.filter { $0.id != rule.id } + [rule]
            let conflicts = model.conflicts
            let issues = BindingConflicts(rules: others, known: conflicts.known, character: conflicts.character)
                .issues(for: rule)
            if !issues.isEmpty {
                Section(UIL("Before you save")) {
                    IssueList(issues: issues)
                }
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = UIL("Choose")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        draft.folderPath = url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path
    }
}

private struct AppList: View {
    let title: String
    @Binding var ids: [String]

    var body: some View {
        LabeledContent(title) {
            VStack(alignment: .trailing, spacing: 4) {
                ForEach(ids, id: \.self) { id in
                    HStack {
                        AppIconView(bundleID: id)
                        Text(BindingsApps.name(id))
                        Button { ids.removeAll { $0 == id } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                Menu(UIL("Add App")) {
                    ForEach(BindingsApps.running(excluding: ids), id: \.id) { app in
                        Button(app.name) { ids.append(app.id) }
                    }
                    Divider()
                    Button(UIL("Other App")) { ids += BindingsApps.choose().filter { !ids.contains($0) } }
                }
                .fixedSize()
            }
        }
    }
}
