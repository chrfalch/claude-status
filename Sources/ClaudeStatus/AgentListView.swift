import AppKit
import ClaudeStatusCore

struct AgentRow {
    let title: String
    let summary: String?
    let color: NSColor
    let runningSubagents: Int
    let host: NSRunningApplication?
    let open: (@MainActor () -> Void)?
}

final class AgentListView: NSView {
    private static let width: CGFloat = 360
    private static let maxVisibleRows = 10
    private static let inset: CGFloat = 14
    private static let dotSize: CGFloat = 10
    private static let textX: CGFloat = inset + dotSize + 8
    private static let verticalPadding: CGFloat = 6

    init(rows: [AgentRow]) {
        let document = FlippedView()
        var y: CGFloat = 0
        var visibleHeight: CGFloat = 0
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let separator = SeparatorView(frame: NSRect(x: Self.textX, y: y, width: Self.width - Self.textX - Self.inset, height: 1))
                document.addSubview(separator)
                y += 1
            }
            let rowView = RowView(host: row.host, open: row.open)
            let height = Self.layout(row, in: rowView)
            rowView.frame = NSRect(x: 0, y: y, width: Self.width, height: height)
            document.addSubview(rowView)
            y += height
            if index < Self.maxVisibleRows { visibleHeight = y }
        }
        document.frame = NSRect(x: 0, y: 0, width: Self.width, height: y)

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: Self.width, height: visibleHeight))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = rows.count > Self.maxVisibleRows
        scroll.autohidesScrollers = true
        scroll.documentView = document
        super.init(frame: scroll.frame)
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static func layout(_ row: AgentRow, in parent: NSView) -> CGFloat {
        let top: CGFloat = 0
        let textWidth = width - textX - inset
        let iconSize: CGFloat = 16
        let chip = row.runningSubagents > 0 ? SubagentChip(count: row.runningSubagents) : nil
        let iconsWidth = (row.host == nil ? 0 : iconSize + 6) + (chip.map { $0.frame.width + 6 } ?? 0)
        let titleWidth = textWidth - iconsWidth
        let title = label(row.title, font: .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold), color: .labelColor, lines: 1)
        let titleHeight = title.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: titleWidth, height: 1000)).height
        title.frame = NSRect(x: textX, y: top + verticalPadding, width: titleWidth, height: titleHeight)
        parent.addSubview(title)

        let dot = NSImageView(image: StatusDot.image(row.color))
        dot.frame = NSRect(x: inset, y: title.frame.midY - dotSize / 2, width: dotSize, height: dotSize)
        parent.addSubview(dot)

        if let host = row.host, let image = host.icon {
            let icon = NSImageView(image: image)
            icon.imageScaling = .scaleProportionallyUpOrDown
            icon.toolTip = host.localizedName
            icon.frame = NSRect(x: width - inset - iconSize, y: title.frame.midY - iconSize / 2, width: iconSize, height: iconSize)
            parent.addSubview(icon)
        }

        if let chip {
            let right = row.host == nil ? width - inset : width - inset - iconSize - 6
            chip.setFrameOrigin(NSPoint(x: right - chip.frame.width, y: title.frame.midY - chip.frame.height / 2))
            parent.addSubview(chip)
        }

        var bottom = title.frame.maxY
        if let summary = row.summary, !summary.isEmpty {
            let field = label(summary, font: .systemFont(ofSize: NSFont.smallSystemFontSize), color: .secondaryLabelColor, lines: 2)
            let height = field.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: textWidth, height: 1000)).height
            field.frame = NSRect(x: textX, y: bottom + 2, width: textWidth, height: height)
            parent.addSubview(field)
            bottom = field.frame.maxY
        }
        return bottom + verticalPadding - top
    }

    private static func label(_ text: String, font: NSFont, color: NSColor, lines: Int) -> NSTextField {
        let field = lines == 1 ? NSTextField(labelWithString: text) : NSTextField(wrappingLabelWithString: text)
        field.font = font
        field.textColor = color
        field.maximumNumberOfLines = lines
        field.lineBreakMode = .byTruncatingTail
        field.cell?.truncatesLastVisibleLine = true
        return field
    }
}

private class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class RowView: FlippedView {
    private let open: (@MainActor () -> Void)?
    private var hovered = false { didSet { needsDisplay = true } }

    init(host: NSRunningApplication?, open: (@MainActor () -> Void)?) {
        self.open = open
        super.init(frame: .zero)
        toolTip = host.flatMap { $0.localizedName.map { "Open in \($0)" } }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    // Labels and the icon would otherwise take the click.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func mouseEntered(with event: NSEvent) { hovered = open != nil }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func draw(_ dirtyRect: NSRect) {
        guard hovered else { return }
        NSColor.labelColor.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 5, yRadius: 5).fill()
    }

    // Menu item views do not get mouseDown reliably; mouseUp is what AppKit delivers.
    override func mouseUp(with event: NSEvent) {
        guard let open else { return }
        enclosingMenuItem?.menu?.cancelTracking()
        open()
    }
}

private final class SubagentChip: NSView {
    private let text: NSAttributedString

    init(count: Int) {
        text = NSAttributedString(string: "\(count)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize - 1, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        let height: CGFloat = 16
        super.init(frame: NSRect(x: 0, y: 0, width: max(height, ceil(text.size().width) + 10), height: height))
        toolTip = count == 1 ? "1 sub-agent running" : "\(count) sub-agents running"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.1).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
}

private final class SeparatorView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.withAlphaComponent(0.15).setFill()
        bounds.fill()
    }
}

enum StatusDot {
    static func image(_ color: NSColor, canvas: CGFloat = 10, diameter: CGFloat = 10) -> NSImage {
        let image = NSImage(size: NSSize(width: canvas, height: canvas), flipped: false) { _ in
            color.set()
            let offset = (canvas - diameter) / 2
            NSBezierPath(ovalIn: NSRect(x: offset, y: offset, width: diameter, height: diameter)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    /// One frame of a state change: the dot fades to the new color while two rings of it grow outward and fade.
    static func pulse(from old: NSColor, to new: NSColor, progress: Double, canvas: CGFloat, diameter: CGFloat = 10) -> NSImage {
        let image = NSImage(size: NSSize(width: canvas, height: canvas), flipped: false) { _ in
            let center = NSPoint(x: canvas / 2, y: canvas / 2)
            let softness: CGFloat = 2.5
            let maxRadius = canvas / 2 - softness
            for delay in [0.0, 0.35] {
                let ring = (progress - delay) / 0.65
                guard ring > 0, ring < 1 else { continue }
                let eased = 1 - pow(1 - ring, 2)
                let radius = diameter / 2 + (maxRadius - diameter / 2) * eased
                let outer = radius + softness
                // A radial gradient that peaks at the ring radius draws a blurred ring.
                let peak = new.withAlphaComponent(0.55 * (1 - ring))
                let clear = new.withAlphaComponent(0)
                let gradient = NSGradient(colors: [clear, clear, peak, clear],
                                          atLocations: [0, max(0, (radius - softness) / outer), radius / outer, 1],
                                          colorSpace: .sRGB)
                gradient?.draw(fromCenter: center, radius: 0, toCenter: center, radius: outer, options: [])
            }
            let fade = min(1, progress / 0.45)
            (old.blended(withFraction: fade, of: new) ?? new).setFill()
            // A small swell makes the color change noticeable even when the rings are faint.
            let swell = 1 + 0.12 * sin(.pi * min(1, progress / 0.5))
            let size = diameter * swell
            NSBezierPath(ovalIn: NSRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}
