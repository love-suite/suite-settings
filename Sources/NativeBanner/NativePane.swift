import Foundation

/// A pane of macOS's own settings where a suite app stands in for macOS: the banner shows over it.
public enum NativePane: String, CaseIterable, Sendable {
    /// System Settings › Desktop & Dock: Bureau for the desktop, Bar for the Dock.
    case desktopAndDock
    /// System Settings › Spotlight: Clipboard for the clipboard history.
    case spotlight

    /// The app whose window shows the pane.
    public var hostBundleID: String {
        switch self {
        case .desktopAndDock, .spotlight: "com.apple.systempreferences"
        }
    }

    /// The pane's settings extension: its name, in every language macOS has, is the window's title.
    private var extensionPath: String? {
        switch self {
        case .desktopAndDock: "/System/Library/ExtensionKit/Extensions/DesktopSettings.appex"
        case .spotlight: "/System/Library/ExtensionKit/Extensions/SpotlightPreferenceExtension.appex"
        }
    }

    /// The window titles that mean this pane, whatever the Mac's language: the pane's name in every
    /// language, read from macOS's own extension, plus its English name should that change place.
    public var titles: Set<String> { Self.titleCache[self] ?? [] }

    nonisolated(unsafe) private static let titleCache: [NativePane: Set<String>] = {
        var all: [NativePane: Set<String>] = [:]
        for pane in NativePane.allCases {
            let names = pane.extensionPath.map { Self.names(in: URL(fileURLWithPath: $0)) } ?? []
            all[pane] = names.union(pane.fallbackTitles)
        }
        return all
    }()

    private var fallbackTitles: Set<String> {
        switch self {
        case .desktopAndDock: ["Desktop & Dock"]
        case .spotlight: ["Spotlight"]
        }
    }

    /// `CFBundleDisplayName` in each language of an extension's `InfoPlist.loctable`.
    static func names(in bundle: URL) -> Set<String> {
        let table = bundle.appendingPathComponent("Contents/Resources/InfoPlist.loctable")
        guard let data = try? Data(contentsOf: table),
              let languages = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return [] }
        return Set(languages.values.compactMap { ($0 as? [String: Any])?["CFBundleDisplayName"] as? String })
    }

    /// Controls with no identifier of their own, keyed by their title in every language the host app has.
    public var titledControls: [String: Set<String>] { Self.titledCache[self] ?? [:] }

    nonisolated(unsafe) private static let titledCache: [NativePane: [String: Set<String>]] = [
        .spotlight: ["clipboard-results": strings("Results from Clipboard",
                                                   in: "/System/Library/ExtensionKit/Extensions/SpotlightPreferenceExtension.appex")],
    ]

    /// A string of a settings extension's `Localizable.loctable`, in every language (the English key too).
    static func strings(_ key: String, in bundle: String) -> Set<String> {
        let table = URL(fileURLWithPath: bundle).appendingPathComponent("Contents/Resources/Localizable.loctable")
        guard let data = try? Data(contentsOf: table),
              let languages = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return [key] }
        return Set(languages.values.compactMap { ($0 as? [String: Any])?[key] as? String }).union([key])
    }

    /// The pane a window of `bundleID` titled `title` shows, if any.
    public static func pane(hostBundleID bundleID: String?, windowTitle title: String?) -> NativePane? {
        guard let bundleID, let title else { return nil }
        return allCases.first { $0.hostBundleID == bundleID && $0.titles.contains(title) }
    }
}
