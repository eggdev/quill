import AppKit

/// Floating capsule that stays on screen while quill records: the feather over
/// three live level bars (mic, combined, system), so it's obvious at a glance
/// that both sides of the call are being captured. In ask mode it doubles as
/// the "record this meeting?" prompt. Clicking opens a small menu; dragging
/// moves it, and the position is remembered.
///
/// The panel never takes focus from the meeting app, follows the user across
/// Spaces and full-screen calls, and is excluded from screen capture so it
/// doesn't show up when sharing a screen.
@MainActor
final class RecordingIndicator {
    enum State: Equatable {
        case hidden
        case recording(warning: Bool)
        case prompt
    }

    /// Live per-track levels, polled while recording.
    var levelSource: (() -> [TrackKind: Float])?
    /// Builds the menu shown on click.
    var menuProvider: ((State) -> NSMenu)?

    private let panel: NSPanel
    private let view = IndicatorView(frame: NSRect(origin: .zero, size: IndicatorView.size))
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
        panel.contentView = view

        view.onClick = { [weak self] in self?.showMenu() }
        view.onMoved = { [weak self] in self?.saveOrigin() }
    }

    func update(_ newState: State) {
        guard newState != state else { return }
        state = newState
        switch newState {
        case .hidden:
            stopMeter()
            panel.orderOut(nil)
            return
        case .recording(let warning):
            view.mode = .recording(warning: warning)
            startMeter()
        case .prompt:
            view.mode = .prompt
            stopMeter()
            view.levels = (0, 0)
        }
        if !panel.isVisible {
            panel.setFrameOrigin(restoredOrigin())
            panel.orderFrontRegardless()
        }
        view.needsDisplay = true
    }

    // MARK: -

    private func showMenu() {
        guard let menu = menuProvider?(state) else { return }
        // Open beside the capsule, toward the middle of the screen.
        let onRight = panel.frame.midX > (panel.screen?.visibleFrame.midX ?? 0)
        let x = onRight ? -menu.size.width - 6 : IndicatorView.size.width + 6
        // The view is flipped: y = 0 aligns the menu's top with the capsule's.
        menu.popUp(positioning: nil, at: NSPoint(x: x, y: 0), in: view)
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
    }

    private func pollLevels() {
        let raw = levelSource?() ?? [:]
        view.levels = (
            Self.smooth(view.levels.mic, toward: Self.normalized(raw[.mic] ?? 0)),
            Self.smooth(view.levels.system, toward: Self.normalized(raw[.system] ?? 0))
        )
        view.needsDisplay = true
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

    /// The saved position if it is still on a connected screen, else the
    /// right edge of the main screen, vertically centered.
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

/// Draws the capsule and handles click-vs-drag.
private final class IndicatorView: NSView {
    enum Mode: Equatable {
        case recording(warning: Bool)
        case prompt
    }

    static let size = NSSize(width: 36, height: 72)

    var mode = Mode.recording(warning: false)
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
        switch mode {
        case .prompt:
            // A record dot: "click to record this meeting".
            let dot = NSRect(x: bounds.midX - 5, y: centerY - 5, width: 10, height: 10)
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: dot).fill()
        case .recording(let warning):
            let color = warning ? NSColor.systemOrange : NSColor.systemGreen
            color.setFill()
            // Left is you, right is them, the taller center bar is whoever
            // is louder.
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
