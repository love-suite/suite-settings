import AppKit
import ApplicationServices
import NativeBanner

/// The sections of a native pane that hold marked settings, found once when the pane opens and kept:
/// each section (the rounded group), its controls (with their keys: Accessibility identifier, or
/// `slider.N` for the pane's Nth slider), its texts, and the scroll area that clips it. Measuring reads
/// only their frames.
@MainActor
final class PaneReader {
    private struct Section {
        let element: AXUIElement
        let clip: AXUIElement?
        /// A window laid out without groups (Finder's Settings): its controls and texts together make the
        /// section, its frame theirs with a margin.
        var isWindow = false
        var controls: [(key: String?, element: AXUIElement, isSlider: Bool)] = []
        var texts: [AXUIElement] = []
    }

    private var sections: [Section] = []
    /// The scroll bars of the pane's scroll areas: their value changes as the pane scrolls.
    private(set) var scrollBars: [AXUIElement] = []
    private(set) var foundKeys: Set<String> = []

    private static let controlRoles: Set<String> = [
        kAXCheckBoxRole, kAXPopUpButtonRole, kAXSliderRole, kAXButtonRole, kAXRadioButtonRole,
        kAXTextFieldRole, kAXMenuButtonRole, kAXComboBoxRole,
    ].map { $0 as String }.reduce(into: []) { $0.insert($1) }

    /// `titled`: keys of controls that have no identifier of their own, by their title in every language.
    init(window: AXUIElement, keys: Set<String>, titled: [String: Set<String>] = [:]) {
        var sliders = 0
        var all: [Section] = []
        walk(window, parentRole: "", clip: nil, section: nil, depth: 0) { element, role, clip, section in
            if role == kAXScrollBarRole as String { scrollBars.append(element) }
            if role == kAXToolbarRole as String { return }
            let owner = section ?? window
            var index = all.firstIndex { CFEqual($0.element, owner) }
            if index == nil {
                all.append(Section(element: owner, clip: clip, isWindow: section == nil))
                index = all.count - 1
            }
            if role == kAXStaticTextRole as String { all[index!].texts.append(element) }
            guard Self.controlRoles.contains(role) else { return }
            var key = PaneDump.string(element, "AXIdentifier")
            // Its identifier, title or description, in the Mac's language (Spotlight's settings are
            // identified by their label).
            for attribute in ["AXIdentifier", kAXTitleAttribute, kAXDescriptionAttribute] {
                if let title = PaneDump.string(element, attribute),
                   let named = titled.first(where: { $0.value.contains(title) })?.key {
                    key = named
                }
            }
            if role == kAXSliderRole as String, key == nil || key?.isEmpty == true {
                key = "slider.\(sliders)"
                sliders += 1
            }
            let marked = key.map { keys.contains($0) } ?? false
            all[index!].controls.append((marked ? key : nil, element, role == kAXSliderRole as String))
            if marked, let key { foundKeys.insert(key) }
        }
        sections = all.filter { $0.controls.contains { $0.key != nil } }
    }

    /// `section`: the group directly inside a scroll area that an element belongs to.
    private func walk(_ element: AXUIElement, parentRole: String, clip: AXUIElement?, section: AXUIElement?,
                      depth: Int, visit: (AXUIElement, String, AXUIElement?, AXUIElement?) -> Void) {
        guard depth < 40 else { return }
        let role = PaneDump.string(element, kAXRoleAttribute) ?? ""
        var section = section
        if section == nil, parentRole == kAXScrollAreaRole as String, role == kAXGroupRole as String { section = element }
        visit(element, role, clip, section)
        // Neither the toolbar nor lists (System Settings' sidebar, a hundred rows) hold settings: not walked,
        // which makes reading the pane several times faster.
        if role == kAXToolbarRole as String || role == kAXOutlineRole as String || role == kAXTableRole as String
            || role == kAXListRole as String { return }
        let inner = role == kAXScrollAreaRole as String ? element : clip
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
              let list = children as? [AXUIElement] else { return }
        for child in list {
            walk(child, parentRole: role, clip: inner, section: section, depth: depth + 1, visit: visit)
        }
    }

    /// Each marked field as it is now, in Accessibility's coordinates, with the visible part of its scroll
    /// area (the mark is cut to it).
    func fields() -> [String: (field: RowLayout.Field, visible: CGRect?)] {
        var result: [String: (RowLayout.Field, CGRect?)] = [:]
        for section in sections {
            guard var frame = PaneDump.frame(section.element) else { continue }
            if section.isWindow {
                // The controls' area, with the texts among them (not the window's title above them).
                let controls = section.controls.compactMap { PaneDump.frame($0.element) }
                    .filter { $0.width > 0 && frame.contains($0) }
                guard let first = controls.first else { continue }
                let area = controls.dropFirst().reduce(first) { $0.union($1) }
                let texts = section.texts.compactMap { PaneDump.frame($0) }
                    .filter { $0.width > 0 && $0.minY >= area.minY - 30 && $0.maxY <= area.maxY + 30 }
                frame = texts.reduce(area) { $0.union($1) }.insetBy(dx: -12, dy: -8)
            }
            let controls = section.controls.compactMap { control -> RowLayout.Control? in
                guard let box = PaneDump.frame(control.element), box.width > 0 else { return nil }
                return RowLayout.Control(key: control.key, frame: box, isSlider: control.isSlider)
            }
            let texts = section.texts.compactMap { PaneDump.frame($0) }.filter { $0.width > 0 && frame.contains($0) }
            let visible = section.clip.flatMap { PaneDump.frame($0) }
            for (key, field) in RowLayout.fields(section: frame, controls: controls, texts: texts) {
                result[key] = (field, visible)
            }
        }
        return result
    }

    /// The parts a cover spans: one made of the sections holding its controls, or one per control's field.
    func parts(of cover: PaneCover) -> [(frame: CGRect, visible: CGRect?)] {
        switch cover.extent {
        case .sections:
            return self.cover(cover.anchors).map { [$0] } ?? []
        case .fields:
            let fields = fields()
            return cover.anchors.compactMap { fields[$0].map { ($0.field.frame, $0.visible) } }
        case .controls:
            let fields = fields()
            return cover.anchors.compactMap { fields[$0].map { ($0.field.control.insetBy(dx: -6, dy: -5), $0.visible) } }
        }
    }

    /// The part made of the sections holding these controls, in Accessibility's coordinates, and the visible
    /// part of its scroll area.
    func cover(_ anchors: [String]) -> (frame: CGRect, visible: CGRect?)? {
        let held = sections.filter { section in section.controls.contains { $0.key.map(anchors.contains) ?? false } }
        let frames = held.compactMap { PaneDump.frame($0.element) }
        guard let first = frames.first else { return nil }
        return (frames.dropFirst().reduce(first) { $0.union($1) }, held.first?.clip.flatMap { PaneDump.frame($0) })
    }

    /// The scroll bars' positions: they change as the pane scrolls.
    func scrollValues() -> [Double] {
        scrollBars.map { Double(PaneDump.string($0, kAXValueAttribute) ?? "") ?? -1 }
    }
}
