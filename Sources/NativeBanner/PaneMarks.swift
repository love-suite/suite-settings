import BarSettings
import Foundation

/// A part of a native pane a suite app takes over: covered, its native controls blocked, with one button
/// opening the app's settings in Suite Settings.
public struct PaneCover: Equatable, Sendable {
    /// What a cover spans: the sections (rounded groups) holding its controls, each control's own field
    /// (when a section also holds settings the suite leaves to macOS), or the controls alone (when their
    /// field holds one too).
    public enum Extent: Equatable, Sendable { case sections, fields, controls }

    /// The controls taken over: their Accessibility identifier in the pane (`auto-hide-dock`), or
    /// `slider.N` for the pane's Nth slider, which have none.
    public var anchors: [String]
    public var extent: Extent
    public var title: String
    public var tab: String

    public init(anchors: [String], extent: Extent = .sections, title: String, tab: String) {
        self.anchors = anchors
        self.extent = extent
        self.title = title
        self.tab = tab
    }
}

/// What macOS has now that decides whether to cover: with Stage Manager on, nothing is covered.
public struct NativeValues: Equatable, Sendable {
    public var stageManager = false

    public init() {}

    public static func read() -> NativeValues {
        var values = NativeValues()
        CFPreferencesAppSynchronize("com.apple.WindowManager" as CFString)
        values.stageManager = (CFPreferencesCopyAppValue("GloballyEnabled" as CFString,
                                                         "com.apple.WindowManager" as CFString) as? NSNumber)?.boolValue ?? false
        return values
    }
}

public enum PaneMarks {
    public static let desktopID = "local.suite.desktop"
    public static let barID = "local.suite.bar"
    public static let clipboardID = "local.suite.clipboard"

    /// The parts of a pane to cover, for the suite apps running: the settings a suite app takes over, which
    /// do nothing (or undo what it does) when changed there.
    public static func covers(for pane: NativePane, running: Set<String>, bar: BarSettings = .current,
                              native: NativeValues = .read()) -> [PaneCover] {
        guard !native.stageManager else { return [] }
        switch pane {
        case .desktopAndDock:
            var covers: [PaneCover] = []
            // While Bar shows, everything about the Dock is Bar's (changing the native settings would undo
            // its hiding of the system Dock): the Dock's sections.
            if running.contains(barID) && bar.isShown {
                covers.append(PaneCover(anchors: ["slider.0", "position", "auto-hide-dock"],
                                        title: BL("Open Bar settings"), tab: "Bar"))
            }
            // Bureau shows the desktop's items itself and never hides the windows when the wallpaper is
            // clicked: those two settings (Stage Manager's beside them stay macOS's).
            if running.contains(desktopID) {
                // "Show items: On Desktop" shares its field with "In Stage Manager", left to macOS: the
                // checkbox alone.
                covers.append(PaneCover(anchors: ["show-items-on-desktop"], extent: .controls,
                                        title: BL("Open Bureau settings"), tab: "Desktop"))
                covers.append(PaneCover(anchors: ["click-wallpaper-to-reveal-desktop"], extent: .fields,
                                        title: BL("Open Bureau settings"), tab: "Desktop"))
            }
            return covers
        case .spotlight:
            // Clipboard's history in place of Spotlight's, which it turns off while it runs.
            guard running.contains(clipboardID) else { return [] }
            return [PaneCover(anchors: ["clipboard-results"], title: BL("Open Clipboard settings"), tab: "Clipboard")]
        }
    }
}
