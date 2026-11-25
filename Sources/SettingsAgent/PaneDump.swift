import AppKit
import ApplicationServices

/// A record of a pane's elements (role, label, value, frame), written once per launch to
/// ~/Library/Logs/Suite Settings Agent/<pane>.txt: what the banner is matched against when macOS changes
/// its settings' layout.
enum PaneDump {
    nonisolated(unsafe) private static var done: Set<String> = []

    /// Once per content: a window that changes tab without changing title (Finder's Settings) gets one
    /// record per tab, told apart by the controls it shows.
    static func write(_ window: AXUIElement, pane: String) {
        var lines: [String] = []
        walk(window, depth: 0, into: &lines)
        let controls = lines.filter { $0.contains("AXCheckBox") || $0.contains("AXPopUpButton") || $0.contains("AXSlider") }
            .map { $0.replacingOccurrences(of: #"value="[^"]*""#, with: "", options: .regularExpression)
                     .replacingOccurrences(of: #"frame=\S+"#, with: "", options: .regularExpression) }
        let name = pane + (controls.isEmpty ? "" : " " + String(format: "%08x", UInt32(truncatingIfNeeded: controls.joined().hashValue)))
        let content = pane + "|" + controls.joined(separator: "|")
        guard !done.contains(content) else { return }
        done.insert(content)
        let pane = name
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Suite Settings Agent")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? lines.joined(separator: "\n").write(to: folder.appendingPathComponent(pane + ".txt"), atomically: true, encoding: .utf8)
    }

    private static func walk(_ element: AXUIElement, depth: Int, into lines: inout [String]) {
        guard depth < 40, lines.count < 5000 else { return }
        let role = string(element, kAXRoleAttribute) ?? "?"
        var parts = [String(repeating: "  ", count: depth) + role]
        for (name, attribute) in [("id", "AXIdentifier"), ("title", kAXTitleAttribute), ("desc", kAXDescriptionAttribute),
                                  ("value", kAXValueAttribute), ("help", kAXHelpAttribute)] {
            if let text = string(element, attribute), !text.isEmpty { parts.append("\(name)=\"\(text)\"") }
        }
        if let frame = frame(element) { parts.append("frame=\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width))x\(Int(frame.height))") }
        lines.append(parts.joined(separator: " "))
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
              let list = children as? [AXUIElement] else { return }
        for child in list { walk(child, depth: depth + 1, into: &lines) }
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value else { return nil }
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    /// In Accessibility's coordinates (from the top of the main screen).
    static func frame(_ element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size else { return nil }
        var point = CGPoint.zero, extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &point)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return CGRect(origin: point, size: extent)
    }
}
