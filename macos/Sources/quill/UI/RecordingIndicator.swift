import AppKit

/// Floating capsule that stays on screen while quill records: the feather over
/// three live level bars (mic, combined, system), so it's obvious at a glance
/// that both sides of the call are being captured. Clicking opens a small
/// menu; dragging moves it, and the position is remembered.
///
/// In ask mode the same panel becomes a labeled prompt beside where the
/// capsule sits — "Record “Weekly sync”?" with a ✕ to skip — so an offer is
/// never mistaken for a recording.
///
/// The panel never takes focus from the meeting app, follows the user across
/// Spaces and full-screen calls, and is excluded from screen capture so it
/// doesn't show up when sharing a screen.
@MainActor
final class RecordingIndicator {
    enum State: Equatable {
        case hidden
        case recording(warning: Bool)
        /// Ask mode: offer to record the meeting or call called `title`.
        case prompt(title: String)
    }

    /// Live per-track levels, polled while recording.
    var levelSource: (() -> [TrackKind: Float])?
    /// Builds the menu shown when the recording capsule is clicked.
    var menuProvider: (() -> NSMenu)?
    /// The prompt was clicked: record it.
    var onRecord: (() -> Void)?
    /// The prompt's ✕ was clicked: skip it.
    var onSkip: (() -> Void)?

    private let panel: NSPanel
    private let pill = IndicatorView(frame: NSRect(origin: .zero, size: IndicatorView.size))
    private let prompt = PromptView(frame: .zero)
    private var state = State.hidden
    private var meterTimer: Timer?

    private static let originKey = "indicator.origin"

    init() {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: IndicatorView.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.sharingType = .none
        panel.contentView = pill

        pill.onClick = { [weak self] in self?.showMenu() }
        pill.onMoved = { [weak self] in self?.saveOrigin() }
        prompt.onRecord = { [weak self] in self?.onRecord?() }
        prompt.onSkip = { [weak self] in self?.onSkip?() }
    }

    func update(_ newState: State) {
        guard newState != state else { return }
        state = newState
        switch newState {
        case .hidden:
            stopMeter()
            panel.orderOut(nil)
        case .recording(let warning):
            pill.warning = warning
            pill.needsDisplay = true
            show(pill, frame: NSRect(origin: restoredOrigin(), size: IndicatorView.size))
            startMeter()
        case .prompt(let title):
            stopMeter()
            prompt.title = title
            prompt.needsDisplay = true
            show(prompt, frame: promptFrame(size: prompt.fittingSize))
        }
    }

    // MARK: -

    private func show(_ view: NSView, frame: NSRect) {
        if panel.contentView !== view { panel.contentView = view }
        panel.setFrame(frame, display: true)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    /// Beside the capsule's spot, growing toward the middle of the screen,
    /// kept fully on screen.
    private func promptFrame(size: NSSize) -> NSRect {
        let anchor = NSRect(origin: restoredOrigin(), size: IndicatorView.size)
        let screen =
            NSScreen.screens.first { $0.visibleFrame.intersects(anchor) }?.visibleFrame
            ?? (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        let onRight = anchor.midX > screen.midX
        var origin = NSPoint(
            x: onRight ? anchor.maxX - size.width : anchor.minX,
            y: anchor.midY - size.height / 2
        )
        origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)
        origin.y = min(max(origin.y, screen.minY + 8), screen.maxY - size.height - 8)
        return NSRect(origin: origin, size: size)
    }

    private func showMenu() {
        guard let menu = menuProvider?() else { return }
        // Open beside the capsule, toward the middle of the screen.
        let onRight = panel.frame.midX > (panel.screen?.visibleFrame.midX ?? 0)
        let x = onRight ? -menu.size.width - 6 : IndicatorView.size.width + 6
        // The view is flipped: y = 0 aligns the menu's top with the capsule's.
        menu.popUp(positioning: nil, at: NSPoint(x: x, y: 0), in: pill)
    }

    private func startMeter() {
        guard meterTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollLevels() }
        }
        // .common keeps the bars moving while the click menu is open.
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    private func stopMeter() {
        meterTimer?.invalidate()
        meterTimer = nil
        pill.levels = (0, 0)
    }

    private func pollLevels() {
        let raw = levelSource?() ?? [:]
        pill.levels = (
            Self.smooth(pill.levels.mic, toward: Self.normalized(raw[.mic] ?? 0)),
            Self.smooth(pill.levels.system, toward: Self.normalized(raw[.system] ?? 0))
        )
        pill.needsDisplay = true
    }

    /// Map RMS to 0...1 on a dB scale: -55 dBFS (room tone) reads empty,
    /// -10 dBFS reads full.
    private static func normalized(_ rms: Float) -> CGFloat {
        let db = 20 * log10(max(rms, 1e-6))
        return CGFloat(min(max((db + 55) / 45, 0), 1))
    }

    /// Fast attack, slow release, like a VU meter.
    private static func smooth(_ current: CGFloat, toward target: CGFloat) -> CGFloat {
        target > current ? current + (target - current) * 0.6 : current + (target - current) * 0.15
    }

    private func saveOrigin() {
        UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: Self.originKey)
    }

    /// The capsule's saved position if it is still on a connected screen,
    /// else the right edge of the main screen, vertically centered.
    private func restoredOrigin() -> NSPoint {
        let size = IndicatorView.size
        if let saved = UserDefaults.standard.string(forKey: Self.originKey) {
            let origin = NSPointFromString(saved)
            let frame = NSRect(origin: origin, size: size)
            if NSScreen.screens.contains(where: { $0.visibleFrame.contains(frame) }) {
                return origin
            }
        }
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        return NSPoint(x: visible.maxX - size.width - 12, y: visible.midY - size.height / 2)
    }
}

/// The ask-mode prompt: feather, a record dot, "Record “title”?", and a ✕.
/// Clicking anywhere but the ✕ records.
private final class PromptView: NSView {
    var title = ""
    var onRecord: (() -> Void)?
    var onSkip: (() -> Void)?

    private static let height: CGFloat = 40
    private static let maxTextWidth: CGFloat = 260
    private static let closeWidth: CGFloat = 34
    private let feather = MenuBarController.featherImage(size: NSSize(width: 16, height: 16))

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var text: NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return NSAttributedString(
            string: "Record “\(title)”?",
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor(white: 0.92, alpha: 1),
                .paragraphStyle: style,
            ]
        )
    }

    private var textWidth: CGFloat { min(ceil(text.size().width), Self.maxTextWidth) }

    /// feather · dot · text · ✕, with 14 pt end padding.
    override var fittingSize: NSSize {
        NSSize(width: 14 + 16 + 10 + 8 + 8 + textWidth + 6 + Self.closeWidth, height: Self.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds.insetBy(dx: 1, dy: 1)
        let radius = bounds.height / 2
        let capsule = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        NSColor(white: 0.12, alpha: 0.96).setFill()
        capsule.fill()
        NSColor(white: 0.32, alpha: 1).setStroke()
        capsule.lineWidth = 1.5
        capsule.stroke()

        var x: CGFloat = 14
        if let feather {
            feather.tinted(NSColor(white: 0.82, alpha: 1)).draw(
                in: NSRect(x: x, y: (self.bounds.height - 16) / 2, width: 16, height: 16),
                from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        x += 16 + 10
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: NSRect(x: x, y: self.bounds.midY - 4, width: 8, height: 8)).fill()
        x += 8 + 8

        let lineHeight = ceil(text.size().height)
        text.draw(
            with: NSRect(x: x, y: (self.bounds.height - lineHeight) / 2, width: textWidth, height: lineHeight),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
        )

        // ✕ in a faint circle.
        let close = NSRect(x: self.bounds.maxX - Self.closeWidth + 6, y: self.bounds.midY - 10, width: 20, height: 20)
        NSColor(white: 1, alpha: 0.1).setFill()
        NSBezierPath(ovalIn: close).fill()
        let cross = NSBezierPath()
        let inset = close.insetBy(dx: 6.5, dy: 6.5)
        cross.move(to: NSPoint(x: inset.minX, y: inset.minY))
        cross.line(to: NSPoint(x: inset.maxX, y: inset.maxY))
        cross.move(to: NSPoint(x: inset.maxX, y: inset.minY))
        cross.line(to: NSPoint(x: inset.minX, y: inset.maxY))
        cross.lineWidth = 1.5
        cross.lineCapStyle = .round
        NSColor(white: 0.75, alpha: 1).setStroke()
        cross.stroke()
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        if point.x >= bounds.maxX - Self.closeWidth {
            onSkip?()
        } else {
            onRecord?()
        }
    }
}

/// Draws the capsule and handles click-vs-drag.
private final class IndicatorView: NSView {
    static let size = NSSize(width: 36, height: 72)

    /// Orange bars while a track is recovering or lost.
    var warning = false
    var levels: (mic: CGFloat, system: CGFloat) = (0, 0)
    var onClick: (() -> Void)?
    var onMoved: (() -> Void)?

    private var dragStart: (mouse: NSPoint, origin: NSPoint)?
    private var dragged = false
    private let feather = MenuBarController.featherImage(size: NSSize(width: 18, height: 18))

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds.insetBy(dx: 1, dy: 1)
        let capsule = NSBezierPath(roundedRect: bounds, xRadius: bounds.width / 2, yRadius: bounds.width / 2)
        NSColor(white: 0.12, alpha: 0.96).setFill()
        capsule.fill()
        NSColor(white: 0.32, alpha: 1).setStroke()
        capsule.lineWidth = 1.5
        capsule.stroke()

        if let feather {
            let rect = NSRect(x: (bounds.width - 18) / 2 + 1, y: 12, width: 18, height: 18)
            feather.tinted(NSColor(white: 0.82, alpha: 1))
                .draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }

        let centerY = bounds.height * 0.72
        (warning ? NSColor.systemOrange : NSColor.systemGreen).setFill()
        // Left is you, right is them, the taller center bar is whoever is
        // louder.
        let heights = [levels.mic, max(levels.mic, levels.system), levels.system]
        let caps: [CGFloat] = [14, 22, 14]
        let barWidth: CGFloat = 4
        let gap: CGFloat = 4
        let minH: CGFloat = 6
        var x = bounds.midX - (barWidth * 3 + gap * 2) / 2
        for (i, level) in heights.enumerated() {
            let h = minH + (caps[i] - minH) * level
            let bar = NSRect(x: x, y: centerY - h / 2, width: barWidth, height: h)
            NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
            x += barWidth + gap
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        dragStart = (NSEvent.mouseLocation, window.frame.origin)
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let start = dragStart else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - start.mouse.x
        let dy = now.y - start.mouse.y
        if !dragged && hypot(dx, dy) < 3 { return }
        dragged = true
        window.setFrameOrigin(NSPoint(x: start.origin.x + dx, y: start.origin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil }
        if dragged {
            onMoved?()
        } else {
            onClick?()
        }
    }
}

extension NSImage {
    /// A copy filled with `color` wherever the original is opaque — custom
    /// views don't get the automatic tinting template images get in controls.
    func tinted(_ color: NSColor) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}

/// A menu item that runs a closure, so controllers that aren't NSObjects can
/// build menus without @objc targets.
@MainActor
final class ActionMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ title: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func fire() { handler() }
}
