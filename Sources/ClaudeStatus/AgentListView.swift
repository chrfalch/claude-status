import AppKit
import ClaudeStatusCore

struct AgentRow {
    let title: String
    let summary: String?
    let color: NSColor
    let runningSubagents: Int
    let shellCommands: Int
    let host: NSRunningApplication?
    let open: (@MainActor () -> Void)?
}

final class AgentListView: NSView {
    static let width: CGFloat = 360
    private static let maxVisibleRows = 10
    static let inset: CGFloat = 14
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
        var chips: [CountChip] = []
        if row.shellCommands > 0 {
            chips.append(CountChip(count: row.shellCommands, symbol: "terminal",
                                   toolTip: row.shellCommands == 1 ? "1 shell command running" : "\(row.shellCommands) shell commands running"))
        }
        if row.runningSubagents > 0 {
            chips.append(CountChip(count: row.runningSubagents, symbol: nil,
                                   toolTip: row.runningSubagents == 1 ? "1 sub-agent running" : "\(row.runningSubagents) sub-agents running"))
        }
        let iconsWidth = (row.host == nil ? 0 : iconSize + 6) + chips.reduce(0) { $0 + $1.frame.width + 6 }
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

        var right = row.host == nil ? width - inset : width - inset - iconSize - 6
        for chip in chips.reversed() {
            chip.setFrameOrigin(NSPoint(x: right - chip.frame.width, y: title.frame.midY - chip.frame.height / 2))
            parent.addSubview(chip)
            right -= chip.frame.width + 6
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

final class UsageView: FlippedView {
    private static let nameWidth: CGFloat = 52
    private static let detailWidth: CGFloat = 130
    private static let barHeight: CGFloat = 6
    private static let rowHeight: CGFloat = 18
    private static let daysHeight: CGFloat = 11

    init(gauges: [Usage.Gauge], weekDays: [Usage.Day]?) {
        var y: CGFloat = 6
        var subviews: [NSView] = []
        let barX = AgentListView.inset + Self.nameWidth
        let barWidth = AgentListView.width - AgentListView.inset - Self.detailWidth - 8 - barX
        for gauge in gauges {
            let days = gauge.name == "Week" ? weekDays : nil
            let name = Self.label(gauge.name, color: .secondaryLabelColor, alignment: .left)
            name.frame = NSRect(x: AgentListView.inset, y: y, width: Self.nameWidth, height: Self.rowHeight)
            let detail = Self.label(gauge.detail, color: .secondaryLabelColor, alignment: .right)
            detail.frame = NSRect(x: AgentListView.width - AgentListView.inset - Self.detailWidth, y: y, width: Self.detailWidth, height: Self.rowHeight)
            let bar = UsageBar(gauge: gauge, days: days)
            bar.frame = NSRect(x: barX, y: y + (Self.rowHeight - Self.barHeight) / 2 - 2, width: barWidth, height: Self.barHeight + 4)
            subviews += [name, detail, bar]
            y += Self.rowHeight
            if let days {
                let segment = barWidth / CGFloat(days.count)
                for (index, day) in days.enumerated() {
                    let letter = Self.label(day.symbol, color: day.isWeekend ? .secondaryLabelColor : .tertiaryLabelColor, alignment: .center, size: 9)
                    letter.frame = NSRect(x: barX + CGFloat(index) * segment, y: y - 3, width: segment, height: Self.daysHeight)
                    subviews.append(letter)
                }
                y += Self.daysHeight - 2
            }
        }
        super.init(frame: NSRect(x: 0, y: 0, width: AgentListView.width, height: y + 6))
        subviews.forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static func label(_ text: String, color: NSColor, alignment: NSTextAlignment, size: CGFloat = NSFont.smallSystemFontSize) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .monospacedDigitSystemFont(ofSize: size, weight: .medium)
        label.textColor = color
        label.alignment = alignment
        label.lineBreakMode = .byTruncatingTail
        return label
    }
}

/// A usage bar with a marker for the time passed; split into day segments when days are given.
private final class UsageBar: NSView {
    private let gauge: Usage.Gauge
    private let days: [Usage.Day]?

    init(gauge: Usage.Gauge, days: [Usage.Day]?) {
        self.gauge = gauge
        self.days = days
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        let track = bounds.insetBy(dx: 0, dy: 2)
        let segments = days.map { days in
            let gap: CGFloat = 2
            let width = (track.width - gap * CGFloat(days.count - 1)) / CGFloat(days.count)
            return days.enumerated().map { index, day in
                (NSRect(x: track.minX + CGFloat(index) * (width + gap), y: track.minY, width: width, height: track.height), day.isWeekend)
            }
        } ?? [(track, false)]
        let fillColor: NSColor = switch gauge.used ?? 0 {
        case 0.9...: .systemRed
        case 0.75...: .systemOrange
        default: .controlAccentColor
        }
        let fillEnd = track.minX + track.width * (gauge.used ?? 0)
        for (rect, isWeekend) in segments {
            let radius = rect.height / 2
            let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            (isWeekend ? NSColor.systemPurple.withAlphaComponent(0.22) : NSColor.labelColor.withAlphaComponent(0.12)).setFill()
            shape.fill()
            guard fillEnd > rect.minX else { continue }
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            fillColor.setFill()
            NSRect(x: rect.minX, y: rect.minY, width: min(rect.width, fillEnd - rect.minX), height: rect.height).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        if let elapsed = gauge.elapsed {
            let x = round(track.minX + track.width * elapsed)
            NSColor.labelColor.withAlphaComponent(0.8).setFill()
            NSBezierPath(roundedRect: NSRect(x: x - 1, y: bounds.minY, width: 2, height: bounds.height), xRadius: 1, yRadius: 1).fill()
        }
    }
}

class FlippedView: NSView {
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

private final class CountChip: NSView {
    private let text: NSAttributedString
    private let symbol: NSImage?
    private static let symbolSize: CGFloat = 10

    init(count: Int, symbol: String?, toolTip: String) {
        text = NSAttributedString(string: "\(count)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize - 1, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        self.symbol = symbol
            .flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }?
            .withSymbolConfiguration(.init(pointSize: Self.symbolSize, weight: .semibold).applying(.init(hierarchicalColor: .secondaryLabelColor)))
        let height: CGFloat = 16
        let content = ceil(text.size().width) + (self.symbol == nil ? 0 : Self.symbolSize + 3)
        super.init(frame: NSRect(x: 0, y: 0, width: max(height, content + 10), height: height))
        self.toolTip = toolTip
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.1).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        let size = text.size()
        var x = (bounds.width - size.width - (symbol == nil ? 0 : Self.symbolSize + 3)) / 2
        if let symbol {
            let height = Self.symbolSize * symbol.size.height / max(symbol.size.width, 1)
            symbol.draw(in: NSRect(x: x, y: (bounds.height - height) / 2, width: Self.symbolSize, height: height))
            x += Self.symbolSize + 3
        }
        text.draw(at: NSPoint(x: x, y: (bounds.height - size.height) / 2))
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

    /// The menu bar icon: a light pill holding the agent emoji and the dot image, which may be a pulse frame.
    static func pill(_ dot: NSImage, emoji: String = "🤖") -> NSImage {
        let text = NSAttributedString(string: emoji, attributes: [.font: NSFont.systemFont(ofSize: 12)])
        let textSize = text.size()
        let height = dot.size.height
        let pillHeight: CGFloat = 18
        let padding: CGFloat = 6
        let dotDiameter: CGFloat = 10
        let width = padding + ceil(textSize.width) + 4 + dotDiameter + padding
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            NSColor.labelColor.withAlphaComponent(0.15).setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: (height - pillHeight) / 2, width: width, height: pillHeight),
                         xRadius: pillHeight / 2, yRadius: pillHeight / 2).fill()
            text.draw(at: NSPoint(x: padding, y: (height - textSize.height) / 2))
            let dotCenterX = width - padding - dotDiameter / 2
            dot.draw(in: NSRect(x: dotCenterX - dot.size.width / 2, y: 0, width: dot.size.width, height: height))
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
