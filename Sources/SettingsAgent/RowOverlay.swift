import AppKit
import NativeBanner
import SuiteCore

/// What the covers' windows share: borderless panels on the window's Space, left out of Mission Control,
/// and their place among the windows.
@MainActor
enum RowOverlay {
    /// A panel that can be the key window without making the agent the app in front, as Spotlight's:
    /// only the key window's cursor rectangles show, so ours becomes key while the pointer is over it.
    final class PointerPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    static func panel(_ view: NSView, clickable: Bool) -> NSPanel {
        let type: NSPanel.Type = clickable ? PointerPanel.self : NSPanel.self
        let panel = type.init(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered,
                              defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = !clickable
        // Clicks go through to the native controls, except on our buttons and controls.
        panel.ignoresMouseEvents = !clickable
        // On the Space it was shown on, the window's own (nothing to show or hide when Spaces change), and
        // left out of Mission Control by macOS itself, as a transient window.
        panel.collectionBehavior = [.transient, .fullScreenAuxiliary, .ignoresCycle]
        panel.animationBehavior = .none
        panel.contentView = view
        return panel
    }

    static func place(_ panel: NSPanel, at frame: NSRect, above windowID: CGWindowID?, floating: Bool) {
        panel.level = floating ? .floating : .normal
        let changed = panel.frame != frame || !panel.isVisible
        if panel.frame != frame {
            panel.setFrame(frame, display: false)
            panel.contentView.map { panel.invalidateCursorRects(for: $0) }
        }
        if floating {
            panel.orderFrontRegardless()
        } else if let windowID {
            panel.order(.above, relativeTo: Int(windowID))
        } else if !panel.isVisible {
            panel.orderFrontRegardless()
        }
        // Drawn whole, now, at its new size: cut by the scroll area then whole again, or shown again after
        // a scroll, it kept pieces of its earlier drawing until the pointer passed over it.
        if changed {
            panel.contentView?.needsDisplay = true
            panel.display()
        }
    }
}

/// The pointing hand over our buttons and controls, though the agent is never the app in front: cursor
/// rectangles only work for the active app, so the cursor is set as the pointer enters and moves.
@MainActor
class PointingView: NSView {
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways,
                                                               .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        window?.makeKey()
        NSCursor.pointingHand.set()
    }
    override func mouseMoved(with event: NSEvent) { NSCursor.pointingHand.set() }
    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
        window?.resignKey()
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The cover over a part of a native pane a suite app takes over: a dark, grey-hatched overlay with a grey
/// border, and a white button in its middle, red under the pointer, opening the app's settings. The overlay
/// lets the scroll wheel through to the pane (clicks on it are swallowed by `ClickGuard`, as the native
/// controls under it must not change); only the button takes the pointer.
@MainActor
final class CoverOverlay {
    private let panel: NSPanel
    private let buttonPanel: NSPanel
    private let view = CoverView()
    private let button = CoverButton()

    init() {
        panel = RowOverlay.panel(view, clickable: false)
        buttonPanel = RowOverlay.panel(button, clickable: true)
    }

    /// Returns the button's frame, in AppKit's screen coordinates (empty without a button).
    @discardableResult
    func show(_ cover: PaneCover, at frame: NSRect, above windowID: CGWindowID?, floating: Bool) -> NSRect {
        button.cover = cover
        let size = button.size
        let buttonFrame = NSRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2,
                                 width: size.width, height: size.height)
        // No button where it wouldn't fit with room around it: the cover alone.
        let fits = frame.height >= size.height + 8 && frame.width >= size.width + 24
        if !fits { buttonPanel.orderOut(nil) }
        let parts: [(NSPanel, NSRect)] = fits ? [(panel, frame), (buttonPanel, buttonFrame)] : [(panel, frame)]
        for (part, rect) in floating ? parts : parts.reversed() {
            RowOverlay.place(part, at: rect, above: windowID, floating: floating)
        }
        return fits ? buttonFrame : .zero
    }

    func hide() {
        panel.orderOut(nil)
        buttonPanel.orderOut(nil)
    }
}

@MainActor
private final class CoverView: NSView {
    // Layers, not drawing: macOS resizes them with the window, so the cover cut by the scroll area then
    // whole again never keeps the picture of its earlier size.
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        guard let layer else { return }
        layer.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        layer.cornerRadius = 10
        layer.masksToBounds = true
        layer.borderWidth = 1.5
        layer.borderColor = NSColor.systemGray.cgColor
        // Grey hatching at 45 degrees: a tile repeated over the whole cover.
        let hatch = CALayer()
        hatch.backgroundColor = NSColor(patternImage: Self.tile).cgColor
        hatch.frame = layer.bounds
        hatch.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer.addSublayer(hatch)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// One step of the hatching: a diagonal across a square, which joins itself from tile to tile.
    private static let tile: NSImage = {
        let side: CGFloat = 10
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let line = NSBezierPath()
            line.move(to: NSPoint(x: -1, y: -1))
            line.line(to: NSPoint(x: side + 1, y: side + 1))
            line.lineWidth = 1
            NSColor.systemGray.withAlphaComponent(0.35).setStroke()
            line.stroke()
            return true
        }
    }()
}

/// The cover's button: white, red under the pointer, with the pointing hand.
@MainActor
private final class CoverButton: PointingView {
    var cover: PaneCover? {
        didSet { if cover != oldValue { needsDisplay = true } }
    }
    private var hovering = false {
        didSet { if hovering != oldValue { needsDisplay = true } }
    }

    private static let font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)

    var size: NSSize {
        let text = ((cover?.title ?? "") as NSString).size(withAttributes: [.font: Self.font])
        return NSSize(width: ceil(text.width) + 32, height: 30)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let cover else { return }
        (hovering ? NSColor.systemRed : NSColor.white).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        let text = NSAttributedString(string: cover.title, attributes: [
            .font: Self.font, .foregroundColor: hovering ? NSColor.white : NSColor.black])
        let size = text.size()
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        hovering = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hovering = false
    }

    override func mouseUp(with event: NSEvent) {
        guard let cover, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        SuiteSettingsApp.show(tab: cover.tab)
    }
}
