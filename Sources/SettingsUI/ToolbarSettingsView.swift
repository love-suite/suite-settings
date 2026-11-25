import AppKit
import ExplorerSettings
import SuiteCore
import SwiftUI
import SuiteFilesCore

typealias HoverInfo = (title: String, detail: String, rect: CGRect, above: Bool)

/// Settings › Toolbar: the window's toolbar at its real size for a window width set by a slider
/// (your Explorer window's at first), laid out as the real toolbar is at that width (the search field
/// folds, then buttons go into »); the settings window grows with it. Buttons, More (+) among them,
/// are dragged to reorder them, into the + menu, or out of the bar to hide them; a caret shows where they
/// will land. What can't move shows the not-allowed cursor. Names and what each button does show at once
/// under the mouse.
struct ToolbarSettingsView: View {
    @ObservedObject var model: SettingsModel
    @Binding var windowWidth: CGFloat
    /// The toolbar as it looks in a folder, or in the Trash, whose commands are its own.
    @State private var inTrash = false
    @State private var drag: MockDrag?
    @State private var hover: HoverInfo?
    @State private var frames = MockFrames()

    static let space = "ToolbarSettings"
    static let margin: CGFloat = 20

    private var layout: ToolbarLayout { WindowSettings.toolbarLayout }

    /// The frontmost Explorer window's width, or the one new windows open at.
    static var explorerWindowWidth: CGFloat {
        // The front window Explorer keeps in its session (Settings is an app of its own).
        (ExplorerSession.load().windows.first?.rect.width ?? WindowSettings.newWindowWidth).rounded()
    }

    /// The widest a window can be here.
    static var maxWindowWidth: CGFloat { (NSScreen.main?.visibleFrame.width ?? 1600).rounded() }

    /// The tab's width for a window width: the toolbar (the window less its sidebar), margins added.
    static func tabWidth(windowWidth: CGFloat) -> CGFloat {
        MockToolbar.toolbarWidth(windowWidth: windowWidth) + margin * 2
    }

    var body: some View {
        let labels = WindowSettings.showsToolbarLabels
        let mock = MockToolbar.compute(layout: layout, inTrash: inTrash, labels: labels, width: windowWidth)
        let width = Self.tabWidth(windowWidth: windowWidth)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                Picker("Preview", selection: $inTrash) {
                    Text(UIL("In a folder")).tag(false)
                    Text(UIL("In the Trash")).tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Toggle(UIL("Show button labels"), isOn: model.binding({ WindowSettings.showsToolbarLabels },
                                                                 { WindowSettings.showsToolbarLabels = $0 }))
                    .fixedSize()
                Spacer()
                Button(UIL("Restore Default")) { restore(from: nil, what: UIL("the toolbar\u{2019}s first buttons")) }
                    .help(UIL("Every button in the toolbar, in the usual order, icons only."))
                    .fixedSize()
                let profile = CurrentProfile.load()
                Button(UIL("Restore Profile Default")) {
                    if let profile { restore(from: profile.settings, what: String(format: UIL("the toolbar of \u{201C}%@\u{201D}"), profile.name)) }
                }
                .disabled(profile == nil)
                .help(profile.map { String(format: UIL("The toolbar as the profile \u{201C}%@\u{201D} holds it."), $0.name) }
                      ?? UIL("No profile is loaded: create or load one in the Profile tab."))
                .fixedSize()
            }
            HStack(spacing: 10) {
                Text(UIL("Window width"))
                Slider(value: Binding(get: { windowWidth }, set: { windowWidth = ($0 / 10).rounded() * 10 }),
                       in: 600...max(Self.maxWindowWidth, 700))
                Text("\(Int(windowWidth)) points").monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 80, alignment: .leading)
                Button(UIL("Restore Default Width")) { windowWidth = WindowSettings.newWindowWidth }
                    .disabled(Int(windowWidth) == Int(WindowSettings.newWindowWidth))
                    .help(String(format: UIL("Back to the width new Explorer windows open at: %d points."), Int(WindowSettings.newWindowWidth)))
                    .fixedSize()
                Button(UIL("Open New Windows at This Width")) {
                    model.objectWillChange.send()
                    WindowSettings.newWindowWidth = windowWidth
                }
                .disabled(Int(windowWidth) == Int(WindowSettings.newWindowWidth))
                .help(String(format: UIL("New Explorer windows open %d points wide now."), Int(WindowSettings.newWindowWidth)))
                .fixedSize()
            }
            Text(UIL("Drag buttons to reorder them, into More, or out of the bar to hide them."))
                .font(.callout)
                .foregroundStyle(.secondary)
            ToolbarStrip(mock: mock, labels: labels, dragging: drag?.command, cursors: drag == nil,
                         hover: $hover, onDrag: dragged, onDrop: dropped)
            // Room for the menus, which open under + and ».
            Color.clear.frame(height: CGFloat(max(mock.menu.count, mock.overflowed.count, 1)) * 22 + 20)
            HiddenBar(commands: layout.hidden, inTrash: inTrash, dragging: drag?.command, cursors: drag == nil,
                      hover: $hover, onDrag: dragged, onDrop: dropped)
        }
        .padding(Self.margin)
        .frame(width: width, alignment: .topLeading)
        .overlay(alignment: .topLeading) { overlays(mock: mock, width: width) }
        // After the overlay, so the menus drawn there report where they are too.
        .onPreferenceChange(MockFramesKey.self) { frames = $0 }
        .coordinateSpace(name: Self.space)
    }

    @ViewBuilder
    private func overlays(mock: MockToolbar, width: CGFloat) -> some View {
        // Menus stay inside the tab, as macOS keeps them on screen.
        let menuX = { (x: CGFloat) in min(x - 5, width - Self.margin - 240) }
        ZStack(alignment: .topLeading) {
            Color.clear.allowsHitTesting(false)
            if let more = frames.more, mock.visible.contains(.more) {
                MenuMock(commands: mock.menu, emptyText: UIL("Drop commands here"), dragging: drag?.command,
                         cursors: drag == nil, zone: .menu, hover: $hover, onDrag: dragged, onDrop: dropped)
                    .offset(x: menuX(more.minX), y: more.maxY + 4)
            }
            if let chevron = frames.chevron, !mock.overflowed.isEmpty {
                MenuMock(commands: mock.overflowed.filter { $0 != .more }, emptyText: "", dragging: drag?.command,
                         cursors: drag == nil, zone: nil, hover: $hover, onDrag: dragged, onDrop: dropped)
                    .offset(x: menuX(chevron.minX), y: chevron.maxY + 4)
            }
            Group {
                if let drag, let caret = target(for: drag).caret {
                    Rectangle().fill(Color.accentColor)
                        .frame(width: caret.width, height: caret.height)
                        .offset(x: caret.minX, y: caret.minY)
                }
                if let drag, drag.moved {
                    DragPreview(command: drag.command)
                        .position(x: drag.location.x - drag.grab.x, y: drag.location.y - drag.grab.y)
                }
                if let hover, drag == nil {
                    HoverTip(title: hover.title, detail: hover.detail)
                        .offset(x: min(max(0, hover.rect.midX - 120), width - 250),
                                y: hover.above ? hover.rect.minY - 60 : hover.rect.maxY + 6)
                }
            }
            .allowsHitTesting(false)
        }
    }

    // MARK: Restoring

    /// The toolbar's settings: its buttons and where they are, and their labels.
    static let toolbarKeys = ["ToolbarLayout", "ShowToolbarLabels"]

    /// After asking: the toolbar as `values` holds it (a profile's), or as it first was.
    private func restore(from values: [String: Any]?, what: String) {
        let alert = NSAlert()
        alert.messageText = String(format: UIL("Restore %@?"), what)
        alert.informativeText = UIL("The buttons, their order, More\u{2019}s menu, the hidden ones and the labels go back as they were there.")
        alert.addButton(withTitle: UIL("Restore"))
        alert.addButton(withTitle: UIL("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        model.objectWillChange.send()
        SettingsProfile.restore(Self.toolbarKeys, in: SuiteDefaults.explorer, from: values)
        NotificationCenter.default.post(name: WindowSettings.didChange, object: nil)
        ExplorerLink.settingsChanged()
    }

    // MARK: Dragging

    private func dragged(_ command: ToolbarCommand, _ value: DragGesture.Value) {
        hover = nil
        if drag == nil {
            // Where in the button it was taken, so the ghost stays under the pointer as it was grabbed.
            let rect = frames.items.first { $0.command == command }?.rect
            let grab = rect.map { CGPoint(x: value.startLocation.x - $0.midX, y: value.startLocation.y - $0.midY) } ?? .zero
            drag = MockDrag(command: command, location: value.location, grab: grab)
            NSCursor.closedHand.push()
        } else {
            drag?.location = value.location
        }
        // The hand closes as soon as the button is pressed; it moves past a few points.
        if !(drag?.moved ?? true), hypot(value.translation.width, value.translation.height) > 3 { drag?.moved = true }
        guard let drag, drag.moved else { return NSCursor.closedHand.set() }
        let target = target(for: drag)
        (target.forbidden ? NSCursor.operationNotAllowed
            : target.placement == nil ? NSCursor.disappearingItem : NSCursor.closedHand).set()
    }

    private func dropped(_ command: ToolbarCommand, _ value: DragGesture.Value) {
        guard var current = drag else { return }
        current.location = value.location
        let target = target(for: current)
        drag = nil
        NSCursor.pop()
        // A click without a move changes nothing.
        guard current.moved, !target.forbidden else { return NSCursor.openHand.set() }
        var changed = WindowSettings.toolbarLayout
        changed.move(command, to: target.placement ?? .hidden, before: target.before)
        guard changed != WindowSettings.toolbarLayout else { return }
        model.objectWillChange.send()
        WindowSettings.toolbarLayout = changed
    }

    struct DropTarget {
        var placement: ExplorerSettings.ToolbarPlacement?
        var before: ToolbarCommand?
        var caret: CGRect?
        var forbidden = false
    }

    /// Where a drop puts the button, and the caret that shows it. Outside the bar, the menu and the hidden
    /// bar: hidden (`placement` nil, the poof cursor). + can't go into its own menu.
    private func target(for drag: MockDrag) -> DropTarget {
        let location = drag.location
        let dragged = drag.command
        if dragged != .more, let more = frames.more, more.insetBy(dx: -2, dy: -2).contains(location) {
            return DropTarget(placement: .menu, caret: CGRect(x: more.minX, y: more.maxY + 2, width: more.width, height: 2))
        }
        if let menu = frames.zones[.menu], menu.insetBy(dx: -4, dy: -4).contains(location) {
            guard dragged != .more else { return DropTarget(forbidden: true) }
            let items = frames.items.filter { $0.zone == .menu && $0.command != dragged }.sorted { $0.rect.minY < $1.rect.minY }
            if let next = items.first(where: { $0.rect.midY > location.y }) {
                return DropTarget(placement: .menu, before: next.command,
                                  caret: CGRect(x: next.rect.minX, y: next.rect.minY - 1, width: next.rect.width, height: 2))
            }
            let y = items.last.map { $0.rect.maxY } ?? menu.minY + 5
            return DropTarget(placement: .menu, caret: CGRect(x: menu.minX + 6, y: y, width: menu.width - 12, height: 2))
        }
        if let bar = frames.zones[.toolbar], bar.contains(location) {
            // Past the last button that shows: before the first one in », so it lands at the end of the row.
            let shown = Set(frames.items.filter { $0.zone == .toolbar }.map(\.command))
            let firstOverflowed = layout.commands(.toolbar, inTrash: inTrash, sideBySide: true)
                .first { $0 != dragged && !shown.contains($0) }
            return horizontal(.toolbar, .toolbar, at: location, dragged: dragged, end: firstOverflowed)
        }
        if let hidden = frames.zones[.hidden], hidden.insetBy(dx: -4, dy: -4).contains(location) {
            return horizontal(.hidden, .hidden, at: location, dragged: dragged, end: nil)
        }
        return DropTarget()
    }

    private func horizontal(_ zone: MockZone, _ placement: ExplorerSettings.ToolbarPlacement, at location: CGPoint,
                            dragged: ToolbarCommand, end: ToolbarCommand?) -> DropTarget {
        let items = frames.items.filter { $0.zone == zone && $0.command != dragged }.sorted { $0.rect.minX < $1.rect.minX }
        if let next = items.first(where: { $0.rect.midX > location.x }) {
            return DropTarget(placement: placement, before: next.command,
                              caret: CGRect(x: next.rect.minX - 4, y: next.rect.minY, width: 2, height: next.rect.height))
        }
        let zoneRect = frames.zones[zone] ?? .zero
        guard let last = items.last else {
            return DropTarget(placement: placement, before: end,
                              caret: CGRect(x: zoneRect.minX + 70, y: zoneRect.midY - 12, width: 2, height: 24))
        }
        return DropTarget(placement: placement, before: end,
                          caret: CGRect(x: last.rect.maxX + 2, y: last.rect.minY, width: 2, height: last.rect.height))
    }
}

struct MockDrag {
    var command: ToolbarCommand
    var location: CGPoint
    /// Past a few points from where it was pressed: a drag, not a click.
    var moved = false
    /// From the button's centre to where it was taken.
    var grab: CGPoint
}

// MARK: - The mock's layout, as the window's toolbar lays itself out

/// What the window's toolbar shows at a width: the folder tree's button after the sidebar (or the traffic
/// lights), the commands that fit (+ among them), » for the others, and the search box, which fills what is
/// left and, below about 150 points, folds into a magnifying glass before any button goes into », as macOS
/// does (measured on a real window).
struct MockToolbar {
    var leading: CGFloat
    var visible: [ToolbarCommand]
    var overflowed: [ToolbarCommand]
    var menu: [ToolbarCommand]
    var searchWidth: CGFloat
    var fullHeightSidebar: Bool

    static let sidebarWidth: CGFloat = 220, toggle: CGFloat = 32, gap: CGFloat = 8, trailing: CGFloat = 10

    var toolbarWidth: CGFloat { MockToolbar.toolbarWidth(windowWidth: windowWidth) }
    var windowWidth: CGFloat = 0

    /// Where the toolbar starts: past the full-height sidebar, or past the traffic lights.
    static var leading: CGFloat {
        let shown = WindowSettings.leftSidebar == .hidden ? WindowSettings.shownStyle(left: true) : WindowSettings.leftSidebar
        return shown == .iconsAndNames && WindowSettings.leftSidebar != .hidden ? sidebarWidth : 78
    }

    /// The toolbar's own width in a window: the window less what comes before the toolbar.
    static func toolbarWidth(windowWidth: CGFloat) -> CGFloat { windowWidth - leading }
    static let overflowWidth: CGFloat = 32

    static func chipWidth(_ command: ToolbarCommand, labels: Bool) -> CGFloat {
        if command == .fileExtensions { return 44 }
        return labels ? 34 + textWidth(shortTitle(command)) : 32
    }

    static func textWidth(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width)
    }

    static func shortTitle(_ command: ToolbarCommand) -> String {
        switch command {
        case .trash: return "Trash"
        case .swapSides: return "Swap"
        case .more: return "More"
        default: return command.title
        }
    }

    static func compute(layout: ToolbarLayout, inTrash: Bool, labels: Bool, width: CGFloat) -> MockToolbar {
        let leading = Self.leading
        let fullHeight = leading == sidebarWidth
        let commands = layout.commands(.toolbar, inTrash: inTrash, sideBySide: true)
        let widths = commands.map { chipWidth($0, labels: labels) }
        let full = widths.reduce(0) { $0 + $1 + ToolbarOverflow.buttonSpacing }
        let fixed = leading + toggle + gap * 2 + trailing
        let left = width - fixed - full
        let search: CGFloat = left >= 150 ? left : 33
        let room = width - fixed - search
        let count = full <= room ? commands.count
            : ToolbarOverflow.visibleCount(widths: widths, spacing: ToolbarOverflow.buttonSpacing, trailing: overflowWidth,
                                           available: room)
        return MockToolbar(leading: leading, visible: Array(commands.prefix(count)),
                           overflowed: Array(commands.dropFirst(count)),
                           menu: layout.commands(.menu, inTrash: inTrash, sideBySide: true), searchWidth: search,
                           fullHeightSidebar: fullHeight, windowWidth: width)
    }
}

// MARK: - Where things are, for dragging

enum MockZone: Hashable { case toolbar, menu, hidden }

struct MockItemFrame: Equatable {
    var command: ToolbarCommand
    var zone: MockZone
    var rect: CGRect
}

struct MockFrames: Equatable {
    var items: [MockItemFrame] = []
    var zones: [MockZone: CGRect] = [:]
    var more: CGRect?
    var chevron: CGRect?
}

struct MockFramesKey: PreferenceKey {
    static var defaultValue = MockFrames()
    static func reduce(value: inout MockFrames, nextValue: () -> MockFrames) {
        let next = nextValue()
        value.items += next.items
        value.zones.merge(next.zones) { $1 }
        value.more = next.more ?? value.more
        value.chevron = next.chevron ?? value.chevron
    }
}

private extension View {
    func reportItem(_ command: ToolbarCommand, _ zone: MockZone?) -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: MockFramesKey.self, value: MockFrames(items: zone.map { [
                MockItemFrame(command: command, zone: $0, rect: proxy.frame(in: .named(ToolbarSettingsView.space)))] } ?? []))
        })
    }

    func reportZone(_ zone: MockZone) -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: MockFramesKey.self, value: MockFrames(
                zones: [zone: proxy.frame(in: .named(ToolbarSettingsView.space))]))
        })
    }

    func report(more: Bool) -> some View {
        background(GeometryReader { proxy in
            let rect = proxy.frame(in: .named(ToolbarSettingsView.space))
            Color.clear.preference(key: MockFramesKey.self,
                                   value: more ? MockFrames(more: rect) : MockFrames(chevron: rect))
        })
    }

    /// Dragged with the open and closed hand; its name and what it does at once under the mouse.
    func movable(_ command: ToolbarCommand, cursors: Bool, above: Bool = false, hover: Binding<HoverInfo?>,
                 onDrag: @escaping (ToolbarCommand, DragGesture.Value) -> Void,
                 onDrop: @escaping (ToolbarCommand, DragGesture.Value) -> Void) -> some View {
        overlay(GeometryReader { proxy in
                Color.clear
                    .contentShape(Rectangle())
                    .cursor(.openHand, enabled: cursors)
                    .onHover { inside in
                        if inside {
                            hover.wrappedValue = (command.title, command.help,
                                                  proxy.frame(in: .named(ToolbarSettingsView.space)), above)
                        } else if hover.wrappedValue?.title == command.title {
                            hover.wrappedValue = nil
                        }
                    }
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(ToolbarSettingsView.space))
                        .onChanged { onDrag(command, $0) }
                        .onEnded { onDrop(command, $0) })
            })
    }

    /// Can't be moved: the not-allowed cursor; its name and what it does at once under the mouse.
    func fixed(title: String, detail: String, cursors: Bool, hover: Binding<HoverInfo?>) -> some View {
        overlay(GeometryReader { proxy in
                Color.clear
                    .contentShape(Rectangle())
                    .cursor(.operationNotAllowed, enabled: cursors)
                    .onHover { inside in
                        if inside {
                            hover.wrappedValue = (title, detail, proxy.frame(in: .named(ToolbarSettingsView.space)), false)
                        } else if hover.wrappedValue?.title == title {
                            hover.wrappedValue = nil
                        }
                    }
            })
    }

    /// The cursor, set again at every move of the mouse over the view (once set, SwiftUI and AppKit put the
    /// arrow back as soon as anything redraws), the arrow when it leaves.
    func cursor(_ cursor: NSCursor, enabled: Bool) -> some View {
        onContinuousHover { phase in
            guard enabled else { return }
            switch phase {
            case .active: cursor.set()
            case .ended: NSCursor.arrow.set()
            }
        }
    }

    func mockButton(pressed: Bool = false) -> some View {
        background(RoundedRectangle(cornerRadius: 6)
            .fill(pressed ? Color.accentColor.opacity(0.3) : Color(nsColor: .controlColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }
}

// MARK: - The window

/// The window's toolbar alone, at its real size: the folder tree's button, the commands, », the search box.
private struct ToolbarStrip: View {
    let mock: MockToolbar
    let labels: Bool
    let dragging: ToolbarCommand?
    let cursors: Bool
    @Binding var hover: HoverInfo?
    let onDrag: (ToolbarCommand, DragGesture.Value) -> Void
    let onDrop: (ToolbarCommand, DragGesture.Value) -> Void

    var body: some View {
        toolbar
            .frame(width: mock.toolbarWidth)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor)))
    }

    private var toolbar: some View {
        HStack(spacing: MockToolbar.gap) {
            Image(systemName: "sidebar.left")
                .frame(width: 30, height: 24)
                .mockButton()
                .fixed(title: UIL("Sidebar"), detail: UIL("Shows or hides the sidebar. It stays first."),
                       cursors: cursors, hover: $hover)
            HStack(spacing: ToolbarOverflow.buttonSpacing) {
                ForEach(mock.visible, id: \.self) { command in
                    chip(command)
                }
                if !mock.overflowed.isEmpty {
                    Image(systemName: "chevron.right.2")
                        .frame(width: 30, height: 24)
                        .mockButton(pressed: true)
                        .report(more: false)
                        .fixed(title: UIL("More Buttons"), detail: UIL("The buttons the window is too narrow for."),
                               cursors: cursors, hover: $hover)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                if mock.searchWidth > 60 {
                    Text("Search")
                    Spacer()
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .frame(width: mock.searchWidth, height: 24)
            .mockButton()
            .fixed(title: UIL("Search"), detail: UIL("Searches as you type. It stays at the end."), cursors: cursors, hover: $hover)
        }
        .padding(.leading, MockToolbar.gap)
        .padding(.trailing, MockToolbar.trailing)
        .frame(height: 52)
        .reportZone(.toolbar)
    }

    @ViewBuilder
    private func chip(_ command: ToolbarCommand) -> some View {
        let label = labels && command != .fileExtensions ? MockToolbar.shortTitle(command) : nil
        if command == .more {
            // Shown in the window only while its menu has commands.
            Chip(command: command, label: label, pressed: true)
                .opacity(command == dragging ? 0.3 : mock.menu.isEmpty ? 0.5 : 1)
                .report(more: true)
                .reportItem(command, .toolbar)
                .movable(command, cursors: cursors, hover: $hover, onDrag: onDrag, onDrop: onDrop)
        } else {
            Chip(command: command, label: label)
                .opacity(command == dragging ? 0.3 : 1)
                .reportItem(command, .toolbar)
                .movable(command, cursors: cursors, hover: $hover, onDrag: onDrag, onDrop: onDrop)
        }
    }
}

/// A toolbar button: its icon, and its name when labels show.
private struct Chip: View {
    let command: ToolbarCommand
    let label: String?
    var pressed = false

    var body: some View {
        HStack(spacing: 4) {
            CommandIcon(command: command)
            if let label { Text(label).font(.system(size: 11)).lineLimit(1).fixedSize() }
        }
        .padding(.horizontal, 7)
        .frame(minWidth: 30, minHeight: 24)
        .mockButton(pressed: pressed)
    }
}

/// A command's icon as the toolbar draws it (".ext" is text there).
private struct CommandIcon: View {
    let command: ToolbarCommand

    var body: some View {
        if command == .fileExtensions {
            Text(".ext").font(.system(size: 11, weight: .medium, design: .monospaced)).lineLimit(1).fixedSize()
        } else {
            Image(systemName: command.symbol)
        }
    }
}

// MARK: - Menus, as macOS draws them

private struct MenuMock: View {
    let commands: [ToolbarCommand]
    let emptyText: String
    let dragging: ToolbarCommand?
    let cursors: Bool
    /// `.menu` for the + menu, which takes drops; nil for », which only lists what doesn't fit.
    let zone: MockZone?
    @Binding var hover: HoverInfo?
    let onDrag: (ToolbarCommand, DragGesture.Value) -> Void
    let onDrop: (ToolbarCommand, DragGesture.Value) -> Void

    var body: some View {
        let menu = VStack(alignment: .leading, spacing: 0) {
            ForEach(commands, id: \.self) { command in
                row(command)
                    .reportItem(command, zone)
                    .movable(command, cursors: cursors, hover: $hover, onDrag: onDrag, onDrop: onDrop)
            }
            if commands.isEmpty {
                Text(emptyText)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(height: 22)
                    .padding(.horizontal, 12)
            }
        }
        .padding(5)
        .frame(minWidth: 200, alignment: .leading)
        .fixedSize()
        .background(MenuMaterial().clipShape(RoundedRectangle(cornerRadius: 9)))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 5)
        if let zone { menu.reportZone(zone) } else { menu }
    }

    private func row(_ command: ToolbarCommand) -> some View {
        HStack(spacing: 0) {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .semibold))
                .opacity(isOn(command) ? 1 : 0)
                .frame(width: 18)
            Image(systemName: command.symbol)
                .frame(width: 18)
                .padding(.trailing, 6)
            Text(command.title)
            Spacer(minLength: 24)
        }
        .font(.system(size: 13))
        .frame(height: 22)
        .padding(.horizontal, 4)
        .opacity(command == dragging ? 0.3 : 1)
    }

    /// What the menu would show checked now; the preview pane and Side by Side belong to each window.
    private func isOn(_ command: ToolbarCommand) -> Bool {
        switch command {
        case .hiddenFiles: return DisplaySettings.showsHiddenFiles
        case .fileExtensions: return DisplaySettings.showsFileExtensions
        default: return false
        }
    }
}

/// The material menus are drawn with.
private struct MenuMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .menu
        view.state = .active
        view.blendingMode = .withinWindow
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

// MARK: - Hidden buttons

/// The buttons taken out of the bar, as a bar of icons, from where they are dragged back.
private struct HiddenBar: View {
    let commands: [ToolbarCommand]
    let inTrash: Bool
    let dragging: ToolbarCommand?
    let cursors: Bool
    @Binding var hover: HoverInfo?
    let onDrag: (ToolbarCommand, DragGesture.Value) -> Void
    let onDrop: (ToolbarCommand, DragGesture.Value) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(UIL("Hidden")).font(.callout).foregroundStyle(.secondary)
            HStack(spacing: ToolbarOverflow.buttonSpacing) {
                ForEach(commands, id: \.self) { command in
                    Chip(command: command, label: nil, pressed: command == .more)
                        .opacity(command == dragging ? 0.3
                                 : command.applies(inTrash: inTrash, sideBySide: true) ? 1 : 0.6)
                        .reportItem(command, .hidden)
                        // Its name and help above it: under it, the window's edge would cut them.
                        .movable(command, cursors: cursors, above: true, hover: $hover, onDrag: onDrag, onDrop: onDrop)
                }
                if commands.isEmpty {
                    Text(UIL("Drag a button out of the bar to hide it"))
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .frame(height: 24)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(Color(nsColor: .separatorColor), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .reportZone(.hidden)
    }
}

// MARK: - While dragging, and under the mouse

private struct DragPreview: View {
    let command: ToolbarCommand

    var body: some View {
        Chip(command: command, label: nil, pressed: command == .more)
            .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
    }
}

private struct HoverTip: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 12, weight: .semibold))
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(width: 240, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
        .shadow(color: .black.opacity(0.2), radius: 5, y: 2)
    }
}
