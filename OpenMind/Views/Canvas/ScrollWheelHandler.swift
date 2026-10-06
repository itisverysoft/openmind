#if os(macOS)
import SwiftUI
import AppKit

/// Invisible helper that turns scroll-wheel events over the canvas into pan / zoom callbacks.
struct ScrollWheelHandler: NSViewRepresentable {
    /// Pan by this many screen points.
    var onPan: (CGSize) -> Void
    /// Multiply the zoom by `factor`, keeping the screen point `location` fixed.
    var onZoom: (_ factor: CGFloat, _ location: CGPoint) -> Void
    /// Flip this to reverse the wheel direction.
    var invertZoom = false

    func makeNSView(context: Context) -> ScrollTrackingView {
        let view = ScrollTrackingView()
        apply(to: view)
        return view
    }

    func updateNSView(_ view: ScrollTrackingView, context: Context) {
        apply(to: view)
    }

    static func dismantleNSView(_ view: ScrollTrackingView, coordinator: ()) {
        view.removeMonitor()
    }

    private func apply(to view: ScrollTrackingView) {
        view.onPan = onPan
        view.onZoom = onZoom
        view.invertZoom = invertZoom
    }
}

final class ScrollTrackingView: NSView {
    var onPan: (CGSize) -> Void = { _ in }
    var onZoom: (CGFloat, CGPoint) -> Void = { _, _ in }
    var invertZoom = false

    private var monitor: Any?

    // Top-left origin, like SwiftUI.
    override var isFlipped: Bool { true }

    // Never block clicks and drags meant for the canvas.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeMonitor()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// Returns nil when the event was used, or the event itself to let it pass on.
    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window === window else { return event }

        let location = convert(event.locationInWindow, from: nil)
        guard bounds.contains(location) else { return event }

        let isPrecise = event.hasPreciseScrollingDeltas        // trackpad / Magic Mouse
        let flags = event.modifierFlags
        // Command scroll-zooms. Option is reserved for temporary hand-tool
        // panning (hold Option and drag), so Option+scroll pans like normal.
        let zoomModifier = flags.contains(.command)

        if !isPrecise || zoomModifier {
            let dy = event.scrollingDeltaY * (invertZoom ? -1 : 1)
            guard dy != 0 else { return nil }
            // Wheel: a fixed 10% step per event. Trackpad with a modifier: smooth, proportional.
            let factor: CGFloat = isPrecise ? exp(dy * 0.01) : (dy > 0 ? 1.1 : 1 / 1.1)
            onZoom(factor, location)
        } else {
            onPan(CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY))
        }
        return nil
    }
}

/// Reports whether the Option key is currently held, for temporary
/// hand-tool panning (Illustrator-style: hold Option to pan the canvas).
/// The view itself is click-through; it only observes modifier flags.
struct OptionKeyMonitor: NSViewRepresentable {
    @Binding var isHeld: Bool

    func makeNSView(context: Context) -> OptionTrackingView {
        let view = OptionTrackingView()
        view.onChange = { isHeld = $0 }
        return view
    }

    func updateNSView(_ view: OptionTrackingView, context: Context) {
        view.onChange = { isHeld = $0 }
    }

    static func dismantleNSView(_ view: OptionTrackingView, coordinator: ()) {
        view.stop()
    }
}

final class OptionTrackingView: NSView {
    var onChange: (Bool) -> Void = { _ in }
    private var monitor: Any?
    private var lastValue: Bool?

    // Never block clicks and drags meant for the canvas.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        start()
    }

    func sync() {
        let held = NSEvent.modifierFlags.contains(.option)
        guard lastValue != held else { return }
        lastValue = held
        onChange(held)
    }

    private func start() {
        stop()
        guard window != nil else { return }
        sync()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.sync()
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// Reports whether Shift is held, for additive marquee selection and
/// Shift-click toggling. Click-through; only observes modifier flags.
struct ShiftKeyMonitor: NSViewRepresentable {
    @Binding var isHeld: Bool

    func makeNSView(context: Context) -> ShiftTrackingView {
        let view = ShiftTrackingView()
        view.onChange = { isHeld = $0 }
        return view
    }

    func updateNSView(_ view: ShiftTrackingView, context: Context) {
        view.onChange = { isHeld = $0 }
    }

    static func dismantleNSView(_ view: ShiftTrackingView, coordinator: ()) {
        view.stop()
    }
}

final class ShiftTrackingView: NSView {
    var onChange: (Bool) -> Void = { _ in }
    private var monitor: Any?
    private var lastValue: Bool?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        start()
    }

    func sync() {
        let held = NSEvent.modifierFlags.contains(.shift)
        guard lastValue != held else { return }
        lastValue = held
        onChange(held)
    }

    private func start() {
        stop()
        guard window != nil else { return }
        sync()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.sync()
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
#endif
