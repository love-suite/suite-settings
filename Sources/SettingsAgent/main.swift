import AppKit
import ApplicationServices
import BarSettings
import NativeBanner
import os
import SuiteCore

/// Suite Settings Agent: Suite Settings's background helper, started at login, with no window of its own.
/// On macOS's settings panes where a suite app stands in for macOS (System Settings › Desktop & Dock), it
/// covers the settings that app takes over: a dark, hatched cover with a button opening Suite Settings,
/// which opens Suite Settings on the right tab; the native controls stay usable. It reads the other apps'
/// windows through the Accessibility permission, granted once to this agent. It does nothing until macOS
/// tells it something changed (an app, a window, a pane, a scroll): no timer runs while it waits.
@MainActor
final class AgentDelegate: NSObject, NSApplicationDelegate {
    private var target: PaneWindow?
    private var reader: PaneReader?
    private var readerKeys: Set<String> = []
    private var covers: [PaneCover] = []
    private var coverOverlays: [CoverOverlay] = []
    /// Where the covers were, cut to the visible scroll area: guarded while they step aside.
    private var coveredAreas: [CGRect] = []
    private var appObservers: [pid_t: AXObserver] = [:]
    private var windowObserver: AXObserver?
    private var settle: DispatchWorkItem?
    fileprivate var grabbing = false
    /// Counts the window's moves and scrolls: a late measure is dropped when another came since.
    fileprivate var moves = 0
    /// How many times the pane was read again for a part still missing, since the last move.
    fileprivate var retries = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Asked at each launch until granted: the request also puts the agent in System Settings ›
        // Privacy & Security › Accessibility, where the user turns it on.
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { (NSApp.delegate as? AgentDelegate)?.discover() }
            }
        }
        // Bar's settings changed in Suite Settings (turned on or off): its cover comes or goes.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("local.suite.bar.applySettings"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { (NSApp.delegate as? AgentDelegate)?.discover() }
        }
        // macOS announces changes to the Accessibility list: the permission granted, the covers come.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.accessibility.api"), object: nil, queue: .main) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated { (NSApp.delegate as? AgentDelegate)?.discover() }
            }
        }
        // The covers step aside as soon as the window is grabbed by its title bar or scrolled, before it
        // even moves.
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .scrollWheel]) { event in
            let location = NSEvent.mouseLocation
            let type = event.type
            MainActor.assumeIsolated { (NSApp.delegate as? AgentDelegate)?.pointer(type, at: location) }
        }
        discover()
    }

    /// A press in the window's title bar hides the covers until the button is released; a scroll over the
    /// window hides them until it stops.
    fileprivate func pointer(_ type: NSEvent.EventType, at location: NSPoint) {
        guard let target, let box = PaneDump.frame(target.element) else { return }
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let window = NSRect(x: box.minX, y: mainHeight - box.maxY, width: box.width, height: box.height)
        switch type {
        case .leftMouseDown:
            let titleBar = NSRect(x: window.minX, y: window.maxY - 52, width: window.width, height: 52)
            guard titleBar.contains(location) else { return }
            grabbing = true
            settle?.cancel()
            coverOverlays.forEach { $0.hide() }
            // A window dragged by its title bar: the Window Server keeps the button's release, no app hears
            // it. The button is looked at until it is up.
            Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { timer in
                guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
                timer.invalidate()
                MainActor.assumeIsolated {
                    guard let agent = NSApp.delegate as? AgentDelegate, agent.grabbing else { return }
                    agent.grabbing = false
                    agent.windowMoved()
                }
            }
        case .leftMouseUp:
            guard grabbing else { return }
            grabbing = false
            windowMoved()
        case .scrollWheel:
            if window.contains(location) { windowMoved() }
        default:
            break
        }
    }

    private let log = Logger(subsystem: "local.suite.settings.agent", category: "banner")
    private var lastState = ""

    /// What the agent sees, logged when it changes (and kept as `LastSeen` in its defaults).
    private func note(_ state: String) {
        guard state != lastState else { return }
        lastState = state
        log.notice("\(state, privacy: .public)")
        UserDefaults.standard.set(state, forKey: "LastSeen")
    }

    // MARK: Finding the pane

    private var pendingDiscover: DispatchWorkItem?

    /// What the host apps report comes in bursts: looked at once the burst is over.
    fileprivate func discoverSoon() {
        pendingDiscover?.cancel()
        let work = DispatchWorkItem { MainActor.assumeIsolated { (NSApp.delegate as? AgentDelegate)?.discover() } }
        pendingDiscover = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    fileprivate func discover() {
        guard AXIsProcessTrusted() else {
            note("no Accessibility permission")
            return clear()
        }
        watchHostApps()
        guard let window = PaneWindow.find() else {
            // Accessibility lists only the current Space's windows: a pane open on another Space keeps its
            // covers there, ready when the user comes back.
            if let target, target.exists() { return note("pane on another Space") }
            note("no pane open")
            return clear()
        }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        if running.contains(PaneMarks.barID) { BarSettings.reloadFromDefaults() }
        covers = PaneMarks.covers(for: window.pane, running: running)
        let keys = Set(covers.flatMap(\.anchors))
        let sameWindow = target.map { CFEqual($0.element, window.element) } ?? false
        if !sameWindow || keys != readerKeys || !keys.isSubset(of: reader?.foundKeys ?? []) {
            reader = PaneReader(window: window.element, keys: keys, titled: window.pane.titledControls)
            readerKeys = keys
            target = window
            watchWindow()
        }
        target = window
        note("pane \(window.pane.rawValue): \(reader?.foundKeys.count ?? 0) of \(keys.count) settings found")
        measure()
        // The pane may still be loading its settings: read again shortly until they are all there. A pane
        // whose settings aren't found is recorded once, to see what it holds.
        if !keys.isSubset(of: reader?.foundKeys ?? []) {
            PaneDump.write(window.element, pane: window.pane.rawValue)
            retries = 0
            reread()
        }
    }

    private func clear() {
        coverOverlays.forEach { $0.hide() }
        ClickGuard.release()
        coveredAreas = []
        covers = []
        target = nil
        reader = nil
        readerKeys = []
        stopWatchingWindow()
    }

    // MARK: Marks

    /// Reads where each field is now and puts its mark there.
    /// After a scroll: System Settings makes new elements for the sections it scrolled out of sight, so the
    /// ones kept would give no frame and their part would go uncovered. The pane is read again, then measured.
    fileprivate func reread(_ trigger: String = "settle") {
        guard let target else { return }
        reader = PaneReader(window: target.element, keys: readerKeys, titled: target.pane.titledControls)
        watchWindow()
        measure()
        // A section a cover needs may not be back yet (System Settings gives its controls late): read again
        // shortly, a few times, until every part is found or the window moves.
        let missing = Set(covers.flatMap(\.anchors)).subtracting(reader?.foundKeys ?? [])
        guard !missing.isEmpty, retries < 40 else { return }
        retries += 1
        let move = moves
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            MainActor.assumeIsolated {
                guard let agent = NSApp.delegate as? AgentDelegate, agent.moves == move, !agent.grabbing else { return }
                agent.reread("retry \(agent.retries)")
            }
        }
    }


    fileprivate func measure() {
        guard let reader, let target else { return }
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        func screen(_ box: CGRect) -> NSRect {
            NSRect(x: box.minX, y: mainHeight - box.maxY, width: box.width, height: box.height)
        }
        let floating = NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid

        // The covers, over their sections as they are now.
        coveredAreas = []
        var buttons: [CGRect] = []
        var visibleCovers: [CGRect] = []
        func windowServer(_ rect: NSRect) -> CGRect {
            CGRect(x: rect.minX, y: mainHeight - rect.maxY, width: rect.width, height: rect.height)
        }
        // One cover window per part: a cover spanning several fields has one in each.
        let parts = covers.flatMap { cover in reader.parts(of: cover).map { (cover, $0.frame, $0.visible) } }
        while coverOverlays.count < parts.count { coverOverlays.append(CoverOverlay()) }
        for (index, overlay) in coverOverlays.enumerated() {
            guard index < parts.count else { overlay.hide(); continue }
            let (cover, frame, visible) = parts[index]
            let part = (frame: frame, visible: visible)
            var box = part.frame
            if let visible = part.visible { box = box.intersection(visible) }
            guard !box.isNull, box.height >= 20 else { overlay.hide(); continue }
            let button = overlay.show(cover, at: screen(box), above: target.windowID, floating: floating)
            buttons.append(windowServer(button))
            // Clicks are swallowed over the part, and while it steps aside anywhere in the visible scroll
            // area, where it may scroll to.
            coveredAreas.append(part.visible ?? box)
            visibleCovers.append(box)
        }
        coveredAreas.isEmpty ? ClickGuard.release() : ClickGuard.block(visibleCovers, except: buttons, on: target.pid)
    }

    /// The window moves, resizes or scrolls: the covers, which can't move with it exactly, step aside and
    /// come back once it stops.
    fileprivate func windowMoved() {
        coverOverlays.forEach { $0.hide() }
        if let target { ClickGuard.block(coveredAreas, on: target.pid) }
        settle?.cancel()
        moves += 1
        retries = 0
        guard !grabbing else { return }
        let move = moves
        let work = DispatchWorkItem { MainActor.assumeIsolated { (NSApp.delegate as? AgentDelegate)?.reread() } }
        settle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
        // Accessibility gives the last frames a moment after the scroll's inertia ends: what was measured
        // then is measured again, unless the window moved since.
        for delay in [0.5, 1.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MainActor.assumeIsolated {
                    guard let agent = NSApp.delegate as? AgentDelegate, agent.moves == move, !agent.grabbing else { return }
                    agent.reread()
                }
            }
        }
    }

    // MARK: What macOS tells

    /// The host apps' windows opening, closing, changing pane (or tab) or focus: each host app is watched.
    /// Watched at last: what it shows now is looked at, since nothing was reported until then.
    fileprivate func watchHostAppsAndLook() {
        let before = appObservers.count
        watchHostApps()
        if appObservers.count > before { discover() }
    }

    private func watchHostApps() {
        let hosts = NativePane.allCases.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0.hostBundleID) }
        let pids = Set(hosts.map(\.processIdentifier))
        for pid in appObservers.keys where !pids.contains(pid) {
            if let observer = appObservers.removeValue(forKey: pid) {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
            }
        }
        for host in hosts where appObservers[host.processIdentifier] == nil {
            let callback: AXObserverCallback = { _, _, _, _ in
                MainActor.assumeIsolated { (NSApp.delegate as? AgentDelegate)?.discoverSoon() }
            }
            var created: AXObserver?
            guard AXObserverCreate(host.processIdentifier, callback, &created) == .success, let created else { continue }
            let application = AXUIElementCreateApplication(host.processIdentifier)
            // The focused element too: a click on another pane in System Settings' sidebar is told at once,
            // before the window's title follows.
            let results = [kAXFocusedWindowChangedNotification, kAXWindowCreatedNotification, kAXTitleChangedNotification,
                           kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification,
                           kAXWindowDeminiaturizedNotification, kAXFocusedUIElementChangedNotification].map {
                AXObserverAddNotification(created, application, $0 as CFString, nil)
            }
            // An app just launched can't be watched yet (it says it cannot complete): asked again a moment
            // later, through the same channel, until it can.
            guard results.allSatisfy({ $0 == .success || $0 == .notificationAlreadyRegistered }) else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    MainActor.assumeIsolated { (NSApp.delegate as? AgentDelegate)?.watchHostAppsAndLook() }
                }
                continue
            }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
            appObservers[host.processIdentifier] = created
        }
    }

    /// The pane's window moving or resizing and its scroll bars' value.
    private func watchWindow() {
        stopWatchingWindow()
        guard let target else { return }
        let callback: AXObserverCallback = { _, _, _, _ in
            MainActor.assumeIsolated { (NSApp.delegate as? AgentDelegate)?.windowMoved() }
        }
        var created: AXObserver?
        guard AXObserverCreate(target.pid, callback, &created) == .success, let created else { return }
        for name in [kAXMovedNotification, kAXResizedNotification] {
            AXObserverAddNotification(created, target.element, name as CFString, nil)
        }
        for bar in reader?.scrollBars ?? [] {
            AXObserverAddNotification(created, bar, kAXValueChangedNotification as CFString, nil)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        windowObserver = created
    }

    private func stopWatchingWindow() {
        if let windowObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(windowObserver), .defaultMode)
        }
        windowObserver = nil
    }
}

/// The window of a native pane the agent covers, wherever it is: in front or not.
struct PaneWindow {
    let pane: NativePane
    let pid: pid_t
    let element: AXUIElement
    /// The Window Server's number for it, to stack the covers just above it.
    let windowID: CGWindowID?

    /// The first pane open in a running host app, in a window that isn't minimized.
    /// The panes open in running host apps, in windows that aren't minimized: the one of the app in front
    /// if it shows one, otherwise the first.
    static func find() -> PaneWindow? {
        var found: [PaneWindow] = []
        for pane in NativePane.allCases {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: pane.hostBundleID) {
                let application = AXUIElementCreateApplication(app.processIdentifier)
                var value: CFTypeRef?
                let result = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value)
                guard result == .success, let windows = value as? [AXUIElement] else { continue }
                for window in windows {
                    guard let title = PaneDump.string(window, kAXTitleAttribute), pane.titles.contains(title),
                          PaneDump.string(window, kAXMinimizedAttribute) != "1",
                          let frame = PaneDump.frame(window) else { continue }
                    found.append(PaneWindow(pane: pane, pid: app.processIdentifier, element: window,
                                            windowID: Self.windowID(pid: app.processIdentifier, frame: frame)))
                    break
                }
            }
        }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        return found.first { $0.pid == front } ?? found.first
    }

    /// The window of `pid` at `frame` (Accessibility's coordinates are the Window Server's).
    private static func windowID(pid: pid_t, frame: CGRect) -> CGWindowID? {
        let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.first { info in
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { return false }
            return abs(rect.minX - frame.minX) < 2 && abs(rect.minY - frame.minY) < 2
                && abs(rect.width - frame.width) < 2
        }.flatMap { $0[kCGWindowNumber as String] as? CGWindowID }
    }

    /// Whether the window is still open, on whatever Space.
    func exists() -> Bool {
        guard let windowID else { return false }
        let list = CGWindowListCreateDescriptionFromArray([NSNumber(value: windowID)] as CFArray) as? [[String: Any]]
        return !(list ?? []).isEmpty
    }
}

// One copy only: the login item and a copy started by Suite Settings would otherwise both draw.
let me = ProcessInfo.processInfo.processIdentifier
if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
    .contains(where: { $0.processIdentifier != me }) {
    exit(0)
}
// NSApplication holds its delegate weakly: this one is kept for the whole run (a local constant would be
// released as soon as it was handed over, in a release build).
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AgentDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
