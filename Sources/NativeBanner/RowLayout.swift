import CoreGraphics

/// Where the marks go on a native pane, from the frames Accessibility gives (top-left origin, y downwards).
/// A pane is made of sections (the rounded groups); a section of lines, each with its controls and the
/// texts that go with them (title, caption, heading). A cover can span a single field.
public enum RowLayout {
    public struct Control: Equatable, Sendable {
        public var key: String?
        public var frame: CGRect
        public var isSlider: Bool

        public init(key: String?, frame: CGRect, isSlider: Bool = false) {
            self.key = key
            self.frame = frame
            self.isSlider = isSlider
        }
    }

    public struct Field: Equatable, Sendable {
        /// The whole field: from the section's edges, or halfway to the next field's.
        public var frame: CGRect
        public var control: CGRect
        /// The texts of its line (title, caption).
        public var texts: [CGRect]
        public var isSlider: Bool
    }

    /// The fields of a section, by control key (controls without a key, or not marked, still share the
    /// room).
    public static func fields(section: CGRect, controls: [Control], texts: [CGRect]) -> [String: Field] {
        // Controls on the same line (overlapping vertically), lines from the top.
        var lines: [[Control]] = []
        for control in controls.sorted(by: { $0.frame.minY < $1.frame.minY }) {
            if let index = lines.firstIndex(where: { line in line.contains { overlapsVertically($0.frame, control.frame) } }) {
                lines[index].append(control)
            } else {
                lines.append([control])
            }
        }
        guard !lines.isEmpty else { return [:] }
        // A text belongs to the line it is level with (a title beside its control); otherwise to the
        // nearer line, above (a caption under its control) or below (a heading over it), below when even.
        var lineTexts = Array(repeating: [CGRect](), count: lines.count)
        let spans = lines.map { line in
            (top: line.map(\.frame.minY).min()!, bottom: line.map(\.frame.maxY).max()!)
        }
        for text in texts {
            if let level = spans.firstIndex(where: { $0.top < text.maxY - 2 && text.minY < $0.bottom - 2 }) {
                lineTexts[level].append(text)
                continue
            }
            let above = spans.lastIndex { $0.bottom <= text.minY + 2 }
            let below = spans.firstIndex { $0.top >= text.maxY - 2 }
            switch (above, below) {
            case let (above?, below?):
                let gapAbove = text.minY - spans[above].bottom, gapBelow = spans[below].top - text.maxY
                lineTexts[gapBelow <= gapAbove ? below : above].append(text)
            case let (above?, nil): lineTexts[above].append(text)
            case let (nil, below?): lineTexts[below].append(text)
            case (nil, nil): lineTexts[0].append(text)
            }
        }
        let contents = lines.indices.map { index in
            (lines[index].map(\.frame) + lineTexts[index]).reduce(CGRect.null) { $0.union($1) }
        }
        var fields: [String: Field] = [:]
        for index in lines.indices {
            let top = index == 0 ? section.minY : (contents[index - 1].maxY + contents[index].minY) / 2
            let bottom = index == lines.count - 1 ? section.maxY : (contents[index].maxY + contents[index + 1].minY) / 2
            let row = lines[index].sorted { $0.frame.minX < $1.frame.minX }
            for (position, control) in row.enumerated() {
                guard let key = control.key else { continue }
                let left = position == 0 ? section.minX : (row[position - 1].frame.maxX + control.frame.minX) / 2
                let right = position == row.count - 1 ? section.maxX : (control.frame.maxX + row[position + 1].frame.minX) / 2
                let frame = CGRect(x: left, y: top, width: right - left, height: bottom - top)
                fields[key] = Field(frame: frame, control: control.frame,
                                    texts: lineTexts[index].filter { $0.intersects(frame) },
                                    isSlider: control.isSlider)
            }
        }
        return fields
    }

    private static func overlapsVertically(_ a: CGRect, _ b: CGRect) -> Bool {
        a.minY < b.maxY - 2 && b.minY < a.maxY - 2
    }
}
