import AppKit
import ClipboardSettings
import SuiteCore

/// Clipboard, seen from Suite Settings: whether it is installed (its tab shows only then), and
/// starting it when it is turned on.
extension ExplorerLink {
    public static var clipboardAppURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: ClipboardSettings.bundleID)
    }

    public static func launchClipboard() {
        guard let url = clipboardAppURL,
              NSRunningApplication.runningApplications(withBundleIdentifier: ClipboardSettings.bundleID).isEmpty
        else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }
}
