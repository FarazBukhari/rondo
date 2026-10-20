import AppKit
import ApplicationServices
import os
import QuartzCore
import RondoKit

/// Borderless, non-activating, clear floating panel (`.popUpMenu` level) that shows a `WheelView`
/// centered on the cursor and clamped to the screen's visible frame. Fades/scales in (≤120 ms).
///
/// - `.drag`: the wheel is a drop target for the in-flight file drag. If Accessibility is granted
///   (`AXIsProcessTrusted()`, never prompted here) a global key monitor adds ←/→/↑/↓/Enter/Esc.
///   When the drag ends anywhere but a slice, the wheel cancels (self-detected via mouse-button
///   polling; `dragEnded(at:)` lets the app report it sooner).
/// - `.click`: the panel takes key focus without activating the app; hover + click, keyboard,
///   click outside / Esc cancels.
@MainActor
public final class WheelPanel: NSObject, NSWindowDelegate {
    public typealias Mode = WheelView.Mode

    /// Supplies slices for `present(inputs:at:kind:mode:)`. Replace when the registry refreshes.
    public var itemProvider: WheelItemProvider
    public var geometry: WheelGeometry
    /// Allow global arrow/Enter/Esc during drags when Accessibility is already granted.
    public var keyboardDuringDrag = true

    /// Slice chosen: the item (with its payload) and the files to act on.
    public var onSelect: ((WheelItem, [URL]) -> Void)?
    /// User cancelled (Esc, hub, click outside, drag ended off the wheel). Not called by `dismiss()`.
    public var onCancel: (() -> Void)?

    public private(set) var mode: Mode?
    public private(set) var kind: WheelKind?
    public private(set) var inputs: [URL] = []
    public var isVisible: Bool { mode != nil }

    private let log = Logger(subsystem: "com.farazbukhari.rondo", category: "wheel")
    private let panel: WheelWindow
    private let container: NSView
    private let backdrop: NSVisualEffectView
    private let wheel: WheelView
    private var generation = 0
    private var applied = false
    private var keyMonitor: Any?
    private var clickMonitor: Any?
    private var dragWatch: Timer?
    private var buttonUpSince: TimeInterval?

    public init(itemProvider: WheelItemProvider, geometry: WheelGeometry = WheelGeometry()) {
        self.itemProvider = itemProvider
        self.geometry = geometry
        let model = WheelModel(items: [], kind: .convert, geometry: geometry)
        let side = model.diameter
        panel = WheelWindow(
            contentRect: NSRect(x: 0, y: 0, width: side, height: side),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        container = NSView(frame: NSRect(x: 0, y: 0, width: side, height: side))
        backdrop = NSVisualEffectView(frame: container.bounds)
        wheel = WheelView(model: model)
        super.init()

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.animationBehavior = .none
        panel.delegate = self

        container.wantsLayer = true
        backdrop.material = .hudWindow
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.autoresizingMask = [.width, .height]
        container.addSubview(backdrop)
        container.addSubview(wheel)
        panel.contentView = container

        wheel.onActivate = { [weak self] item, urls in self?.select(item, urls: urls) }
        wheel.onCancel = { [weak self] in self?.cancel() }
    }

    // MARK: - Public API

    /// Shows the wheel for `inputs` with items from `itemProvider`, centered on `point` (screen coords).
    /// Calling again while visible switches the kind in place (e.g. another modifier during the drag).
    public func present(inputs: [URL], at point: CGPoint, kind: WheelKind, mode: Mode) {
        present(items: itemProvider.items(for: inputs, wheel: kind), inputs: inputs, at: point, kind: kind, mode: mode)
    }

    /// Same as above with explicit items.
    public func present(items: [WheelItem], inputs: [URL], at point: CGPoint, kind: WheelKind, mode: Mode) {
        let wasVisible = isVisible
        if wasVisible, kind == self.kind, mode == self.mode, inputs == self.inputs, !applied { return }
        generation += 1
        applied = false
        self.mode = mode
        self.kind = kind
        self.inputs = inputs

        let model = WheelModel(items: items, kind: kind, geometry: geometry)
        // Switching kind mid-drag: keep the wheel where it is if the cursor is still over it.
        let center = (wasVisible && panel.frame.contains(point)) ? CGPoint(x: panel.frame.midX, y: panel.frame.midY) : point
        layout(model: model, centeredOn: center)
        wheel.mode = mode
        wheel.inputs = inputs
        wheel.highlight(nil)

        installMonitors(for: mode)
        if mode == .click {
            panel.allowsKey = true
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(wheel)
        } else {
            panel.allowsKey = false
        }
        if !wasVisible { animateIn() } else { panel.alphaValue = 1; panel.orderFrontRegardless() }
        log.notice("wheel \(kind.rawValue, privacy: .public) (\(String(describing: mode), privacy: .public)) with \(items.count, privacy: .public) item(s) for \(inputs.count, privacy: .public) file(s)")
    }

    /// Hides the wheel without calling `onCancel`.
    public func dismiss() {
        guard isVisible else { return }
        generation += 1
        mode = nil
        kind = nil
        applied = false
        removeMonitors()
        panel.allowsKey = false
        let gen = generation
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.08
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == gen else { return }
                self.panel.orderOut(nil)
            }
        })
    }

    /// Report that the file drag ended (e.g. from `DragMonitor.onDragEnded`). Off-wheel → cancel;
    /// on a slice → wait briefly for the drop to arrive. Optional: the panel also detects this itself.
    public func dragEnded(at point: CGPoint) {
        guard mode == .drag else { return }
        if applied {
            dismiss()
            return
        }
        let local = wheel.convert(panel.convertPoint(fromScreen: point), from: nil)
        guard case .slice = wheel.hit(atViewPoint: local) else {
            cancel()
            return
        }
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.generation == gen, self.mode == .drag else { return }
            self.cancel()   // drop never arrived
        }
    }

    /// True if the screen point is over the visible wheel window.
    public func contains(_ screenPoint: CGPoint) -> Bool {
        isVisible && panel.frame.contains(screenPoint)
    }

    // MARK: - Selection / cancel

    private func select(_ item: WheelItem, urls: [URL]) {
        guard isVisible, !applied else { return }
        let files = urls.isEmpty ? inputs : urls
        if mode == .drag, NSEvent.pressedMouseButtons & 1 != 0 {
            // Keyboard Enter while the drag is still in flight: keep a "queued" wheel under the cursor
            // until the mouse comes up, so the drop doesn't land on whatever is behind it.
            applied = true
            wheel.showApplied()
            onSelect?(item, files)
            return
        }
        dismiss()
        onSelect?(item, files)
    }

    private func cancel() {
        guard isVisible else { return }
        log.notice("wheel cancelled")
        dismiss()
        onCancel?()
    }

    // MARK: - Layout + animation

    private func layout(model: WheelModel, centeredOn point: CGPoint) {
        let side = model.diameter
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: point.x - side, y: point.y - side, width: side * 2, height: side * 2)
        let frame = WheelPlacement.frame(centeredOn: point, side: side, within: visible)
        panel.setFrame(frame, display: false)
        container.frame = NSRect(x: 0, y: 0, width: side, height: side)
        wheel.setModel(model)
        wheel.frame = container.bounds
        backdrop.frame = container.bounds
        backdrop.maskImage = Self.discMask(side: side, radius: model.outerRadius)
        container.needsDisplay = true
        panel.invalidateShadow()
    }

    private static func discMask(side: CGFloat, radius: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.midX - radius, y: rect.midY - radius, width: radius * 2, height: radius * 2)).fill()
            return true
        }
    }

    private func animateIn() {
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !reduceMotion, let layer = container.layer {
            let b = container.bounds
            var t = CATransform3DMakeTranslation(b.midX, b.midY, 0)
            t = CATransform3DScale(t, 0.86, 0.86, 1)
            t = CATransform3DTranslate(t, -b.midX, -b.midY, 0)
            let scale = CABasicAnimation(keyPath: "transform")
            scale.fromValue = NSValue(caTransform3D: t)
            scale.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            scale.duration = 0.11
            scale.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(scale, forKey: "rondo.scaleIn")
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.1
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    // MARK: - Monitors

    private func installMonitors(for mode: Mode) {
        removeMonitors()
        switch mode {
        case .drag:
            if keyboardDuringDrag, AXIsProcessTrusted() {
                // Global key events require Accessibility; never prompt from here (Settings owns that).
                keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    MainActor.assumeIsolated {
                        guard let self, self.mode == .drag, let key = WheelKey(keyCode: event.keyCode) else { return }
                        self.wheel.handleKey(key)
                    }
                }
            }
            buttonUpSince = nil
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.watchDrag() }
            }
            RunLoop.main.add(timer, forMode: .common)
            dragWatch = timer
        case .click:
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.mode == .click, !self.contains(NSEvent.mouseLocation) else { return }
                    self.cancel()
                }
            }
        }
    }

    private func removeMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        keyMonitor = nil
        clickMonitor = nil
        dragWatch?.invalidate()
        dragWatch = nil
    }

    /// Safety net: the drag is over once the left button has been up briefly.
    private func watchDrag() {
        guard mode == .drag else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if NSEvent.pressedMouseButtons & 1 != 0 {
            buttonUpSince = nil
            return
        }
        guard let since = buttonUpSince else {
            buttonUpSince = now
            return
        }
        if now - since > 0.15 {
            dragWatch?.invalidate()
            dragWatch = nil
            dragEnded(at: NSEvent.mouseLocation)
        }
    }

    // MARK: - NSWindowDelegate

    public func windowDidResignKey(_ notification: Notification) {
        if mode == .click { cancel() }
    }
}

/// Non-activating panel that may take key focus (click mode) without activating Rondo.
final class WheelWindow: NSPanel {
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}
