import Cocoa

private final class CandidateWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class CandidatePanel {
    var onSelect: ((Int) -> Void)?
    var onPage: ((Int) -> Void)?
    private let panel: CandidateWindow
    private let surface = NSVisualEffectView()
    private let heading = NSTextField(labelWithString: "")
    private let footer = NSTextField(labelWithString: "")
    private let previous = NSButton(title: "‹", target: nil, action: nil)
    private let next = NSButton(title: "›", target: nil, action: nil)
    private let badge = NSTextField(labelWithString: "")
    private var rows: [NSButton] = []
    private var flashGeneration = 0

    init() {
        panel = CandidateWindow(contentRect: .zero,
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.setAccessibilityLabel("Laya Chinese candidates")
        surface.material = .popover
        surface.blendingMode = .behindWindow
        surface.state = .active
        surface.wantsLayer = true
        surface.layer?.cornerRadius = 10
        surface.layer?.masksToBounds = true
        panel.contentView = surface
        heading.font = .systemFont(ofSize: 13, weight: .medium)
        heading.textColor = .secondaryLabelColor
        heading.lineBreakMode = .byTruncatingMiddle
        footer.font = .systemFont(ofSize: 10)
        footer.textColor = .secondaryLabelColor
        footer.lineBreakMode = .byTruncatingTail
        badge.font = .systemFont(ofSize: 17, weight: .medium)
        badge.alignment = .center
        badge.isHidden = true
        surface.addSubview(heading)
        surface.addSubview(footer)
        surface.addSubview(badge)
        for button in [previous, next] {
            button.isBordered = false
            button.font = .systemFont(ofSize: 19)
            button.target = self
            button.action = #selector(pageClicked(_:))
            surface.addSubview(button)
        }
        previous.tag = -1
        next.tag = 1
        previous.setAccessibilityLabel("Previous candidate page")
        next.setAccessibilityLabel("Next candidate page")
        for index in 0..<9 {
            let row = NSButton(title: "", target: self, action: #selector(candidateClicked(_:)))
            row.isBordered = false
            row.alignment = .left
            row.wantsLayer = true
            row.layer?.cornerRadius = 5
            row.cell?.lineBreakMode = .byTruncatingTail
            row.tag = index
            surface.addSubview(row)
            rows.append(row)
        }
    }

    func show(pinyin: String, candidates: [String], marked: Set<Int>, selected: Int, page: Int, pageCount: Int,
              status: String, caret: NSRect, windowLevel: Int, horizontal: Bool) {
        flashGeneration += 1
        badge.isHidden = true
        let titles = candidates.enumerated().map {
            title($1, number: $0 + 1, focused: $0 == selected, inset: !horizontal, marked: marked.contains($0))
        }
        let size: NSSize
        if horizontal {
            // One row like Apple's Pinyin; the pinyin itself is already shown inline.
            heading.isHidden = true
            footer.isHidden = !candidates.isEmpty
            footer.stringValue = "Laya · \(status)"
            var x: CGFloat = 6
            for (index, row) in rows.enumerated() {
                row.isHidden = index >= titles.count
                guard index < titles.count else { continue }
                let width = min(260, ceil(titles[index].size().width) + 16)
                row.frame = NSRect(x: x, y: 5, width: width, height: 30)
                x += width + 2
            }
            if candidates.isEmpty {
                footer.frame = NSRect(x: 14, y: 12, width: 200, height: 15)
                x = 220
            }
            previous.frame = NSRect(x: x + 2, y: 7, width: 22, height: 25)
            next.frame = NSRect(x: x + 24, y: 7, width: 22, height: 25)
            size = NSSize(width: x + 52, height: 40)
        } else {
            heading.isHidden = false
            footer.isHidden = false
            let textWidth = titles.map { ceil($0.size().width) }.max() ?? 220
            let width = min(620, max(290, textWidth + 30))
            let height = CGFloat(max(1, candidates.count)) * 31 + 68
            heading.frame = NSRect(x: 14, y: height - 29, width: width - 28, height: 18)
            heading.stringValue = pinyin
            footer.frame = NSRect(x: 14, y: 9, width: width - 88, height: 15)
            footer.stringValue = "Laya · \(status)  \(page + 1)/\(max(1, pageCount))"
            previous.frame = NSRect(x: width - 66, y: 4, width: 25, height: 25)
            next.frame = NSRect(x: width - 37, y: 4, width: 25, height: 25)
            for (index, row) in rows.enumerated() {
                row.isHidden = index >= titles.count
                guard index < titles.count else { continue }
                row.frame = NSRect(x: 7, y: height - 34 - CGFloat(index + 1) * 31, width: width - 14, height: 30)
            }
            size = NSSize(width: width, height: height)
        }
        previous.isHidden = false
        next.isHidden = false
        previous.isEnabled = page > 0
        next.isEnabled = page + 1 < pageCount
        for (index, row) in rows.enumerated() where index < titles.count {
            row.alignment = horizontal ? .center : .left
            row.layer?.backgroundColor = index == selected
                ? NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor : NSColor.clear.cgColor
            row.attributedTitle = titles[index]
            row.setAccessibilityLabel("\(index + 1), \(candidates[index])" + (marked.contains(index) ? ", ranked by Laya" : ""))
        }
        place(size, caret: caret, windowLevel: windowLevel)
    }

    // Brief input-mode indicator near the caret, e.g. after a Shift toggle.
    func flash(_ text: String, caret: NSRect, windowLevel: Int) {
        flashGeneration += 1
        let generation = flashGeneration
        for view in [heading, footer, previous, next] as [NSView] + rows { view.isHidden = true }
        badge.isHidden = false
        badge.stringValue = text
        badge.frame = NSRect(x: 0, y: 7, width: 40, height: 24)
        place(NSSize(width: 40, height: 36), caret: caret, windowLevel: windowLevel)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, self.flashGeneration == generation else { return }
            self.hide()
        }
    }

    private func title(_ text: String, number: Int, focused: Bool, inset: Bool, marked: Bool) -> NSAttributedString {
        let label = NSMutableAttributedString(string: inset ? "  \(number)  " : "\(number) ", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor
        ])
        label.append(NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 18, weight: focused ? .medium : .regular),
            .foregroundColor: NSColor.labelColor
        ]))
        if marked {
            // A small raised dot: Laya's context ranking moved this candidate up.
            label.append(NSAttributedString(string: "\u{2009}•", attributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .bold),
                .foregroundColor: NSColor.controlAccentColor,
                .baselineOffset: 8
            ]))
        }
        return label
    }

    private func place(_ size: NSSize, caret: NSRect, windowLevel: Int) {
        surface.frame = NSRect(origin: .zero, size: size)
        let point = caret == .zero ? NSEvent.mouseLocation : caret.origin
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        let bounds = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin = NSPoint(x: point.x, y: point.y - size.height - 6)
        if origin.y < bounds.minY { origin.y = caret.maxY + 6 }
        origin.x = max(bounds.minX + 4, min(origin.x, bounds.maxX - size.width - 4))
        origin.y = max(bounds.minY + 4, min(origin.y, bounds.maxY - size.height - 4))
        panel.level = NSWindow.Level(rawValue: max(NSWindow.Level.popUpMenu.rawValue, windowLevel + 1))
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        flashGeneration += 1
        panel.orderOut(nil)
    }

    @objc private func candidateClicked(_ sender: NSButton) { onSelect?(sender.tag) }
    @objc private func pageClicked(_ sender: NSButton) { onPage?(sender.tag) }
}
