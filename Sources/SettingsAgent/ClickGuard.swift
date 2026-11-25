import AppKit
import CoreGraphics

/// The native controls under a cover must not be changed, though the cover lets the scroll wheel through
/// (and steps aside while the pane scrolls, with its inertia): clicks there are swallowed, through an event
/// tap (Accessibility, which the agent has), except on the cover's button. Nothing else is touched; off
/// while no cover is shown.
enum ClickGuard {
    /// The areas, in the Window Server's coordinates (top-left origin), where clicks are swallowed.
    nonisolated(unsafe) private static var blocked: [CGRect] = []
    nonisolated(unsafe) private static var allowed: [CGRect] = []
    /// The app whose window the areas lie on: only where that window is the one on top are clicks swallowed.
    nonisolated(unsafe) private static var host: pid_t = 0
    nonisolated(unsafe) private static var tap: CFMachPort?

    /// `allowed`: the buttons inside the areas, which keep their clicks.
    static func block(_ rects: [CGRect], except allowed: [CGRect] = [], on host: pid_t) {
        self.host = host
        blocked = rects
        self.allowed = allowed
        if tap == nil { install() }
        if let tap { CGEvent.tapEnable(tap: tap, enable: !rects.isEmpty) }
    }

    static func release() {
        blocked = []
        allowed = []
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
    }

    private static func install() {
        // Presses only: a release is never swallowed. The release that ends a window drag may fall where a
        // guarded area was before the window moved, and without it the window would stay stuck to the
        // pointer.
        let mask = [CGEventType.leftMouseDown, .rightMouseDown]
            .reduce(CGEventMask(0)) { $0 | (1 << CGEventMask($1.rawValue)) }
        let callback: CGEventTapCallBack = { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = ClickGuard.tap, !ClickGuard.blocked.isEmpty { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            let point = event.location
            let inside = ClickGuard.blocked.contains { $0.contains(point) }
            let onButton = ClickGuard.allowed.contains { $0.contains(point) }
            let swallowed = inside && !onButton && ClickGuard.hostIsOnTop(at: point)
            return swallowed ? nil : Unmanaged.passUnretained(event)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: callback, userInfo: nil) else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
        tap = port
    }

    /// Whether, at this point, the first window from the front is the host's: a window of another app in
    /// front of it keeps its clicks. The agent's own windows aside, and macOS's own see-through sheets over
    /// the whole screen (the Dock's, WindowManager's, the Window Server's), which are in front of everything.
    private static func hostIsOnTop(at point: CGPoint) -> Bool {
        let me = ProcessInfo.processInfo.processIdentifier
        let system = Set(["com.apple.dock", "com.apple.WindowManager"].flatMap {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0).map(\.processIdentifier)
        })
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        for info in windows {
            guard let owner = info[kCGWindowOwnerPID as String] as? pid_t, owner != me, !system.contains(owner),
                  (info[kCGWindowOwnerName as String] as? String) != "Window Server",
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = (info[kCGWindowBounds as String] as? NSDictionary)
                      .flatMap({ CGRect(dictionaryRepresentation: $0) }),
                  bounds.contains(point) else { continue }
            return owner == host
        }
        return false
    }
}
