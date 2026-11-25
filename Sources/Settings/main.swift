import AppKit
import ServiceManagement
import SettingsUI
import SuiteCore

/// Suite Settings: the settings of Explorer and its companion apps as an app of its own, with its own
/// icon in the Dock (Finder's, with the Settings gear in a corner). It writes Explorer's defaults and tells
/// Explorer, which applies them; it quits when its window closes.
final class SettingsDelegate: NSObject, NSApplicationDelegate {
    private var observer: NSObjectProtocol?

    /// Suite Settings keeps itself up to date from its own releases. It quits with its window, so it is
    /// replaced in place, never relaunched: the next time it opens, it is the new version.
    static let updater = SuiteUpdater(appName: "Suite Settings", isBusy: { false }, relaunch: {})

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.updater.start()
        AgentLoginItem.start()
        NSApp.applicationIconImage = Self.icon
        NSApp.mainMenu = Self.menu
        observer = DistributedNotificationCenter.default().addObserver(
            forName: ExplorerLink.showNotification, object: nil, queue: .main) { note in
            SettingsWindow.show(tab: note.userInfo?["tab"] as? String)
        }
        SettingsWindow.show(tab: Self.requestedTab)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        SettingsWindow.show()
        return false
    }

    /// `--tab Dock`: the tab Explorer asked for.
    private static var requestedTab: String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--tab"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    /// Finder's icon with System Settings' gear on its lower-right corner, drawn from this Mac's own icons.
    static var icon: NSImage {
        let finder = NSImage(contentsOfFile: "/System/Library/CoreServices/Finder.app/Contents/Resources/Finder.icns")
            ?? NSWorkspace.shared.icon(forFile: "/System/Library/CoreServices/Finder.app")
        let settingsURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences")
        let gear = settingsURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
        return NSImage(size: NSSize(width: 512, height: 512), flipped: false) { rect in
            finder.draw(in: rect)
            if let gear {
                gear.draw(in: NSRect(x: rect.width * 0.48, y: rect.height * 0.02,
                                     width: rect.width * 0.5, height: rect.height * 0.5))
            } else if let symbol = NSImage(systemSymbolName: "gearshape.fill", accessibilityDescription: nil) {
                symbol.draw(in: NSRect(x: rect.width * 0.55, y: rect.height * 0.05,
                                       width: rect.width * 0.4, height: rect.height * 0.4))
            }
            return true
        }
    }

    private static var menu: NSMenu {
        let main = NSMenu()
        func submenu(_ title: String) -> NSMenu {
            let menu = NSMenu(title: title)
            main.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = menu
            return menu
        }
        let app = submenu("Suite Settings")
        app.addItem(withTitle: "About Suite Settings",
                    action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Suite Settings", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Quit Suite Settings", action: #selector(NSApplication.terminate(_:)),
                    keyEquivalent: "q")
        let edit = submenu("Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let window = submenu("Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        NSApp.windowsMenu = window
        return main
    }
}

// Explorer's settings are Explorer's defaults: read and written here by their domain.
SuiteDefaults.useExplorerDomain()
let app = NSApplication.shared
let delegate = SettingsDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()

/// Suite Settings Agent, the login item inside this app that shows the banner over macOS's settings panes
/// where a suite app stands in for macOS: registered the first time Suite Settings opens (which starts it),
/// then started by macOS at each login. The user can turn it off in System Settings › General › Login Items.
enum AgentLoginItem {
    static func start() {
        let service = SMAppService.loginItem(identifier: "local.suite.settings.agent")
        guard service.status != .enabled else { return }
        do { try service.register() } catch { NSLog("Suite Settings Agent not registered: \(error)") }
    }
}
