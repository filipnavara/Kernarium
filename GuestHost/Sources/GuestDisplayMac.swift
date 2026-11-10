// SPDX-License-Identifier: GPL-2.0-or-later

#if os(macOS)
import AppKit
import Foundation
import GuestHostCore
import MetalKit
import SwiftUI

/// The guest's display in a Mac window, with the same interface as the iOS
/// view (GuestDisplay.swift): the runtime draws into the `GuestMetalView`,
/// and the view sends the guest what the Mac's pointer and keyboard do.
///
/// A Mac has its own keyboard, so the guest gets its keys whenever the view
/// has the keyboard focus, which a click gives it; `keyboardVisible` asks for
/// the focus and never takes it away.
struct GuestDisplayView: NSViewRepresentable {
    @Binding var keyboardVisible: Bool
    let retinaMode: Bool
    /// Told each time a touch begins on the display, after its contacts have
    /// gone to the guest.
    var touchDidBegin: (@MainActor () -> Void)?
    let viewDidLayout: @MainActor (
        GuestMetalView,
        GuestDisplayGeometry
    ) -> Void

    func makeNSView(context: Context) -> GuestMetalView {
        let view = GuestMetalView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.viewDidLayout = viewDidLayout
        view.touchDidBegin = touchDidBegin
        view.retinaMode = retinaMode
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.autoResizeDrawable = false
        return view
    }

    func updateNSView(_ view: GuestMetalView, context: Context) {
        view.touchDidBegin = touchDidBegin
        view.retinaMode = retinaMode
        if keyboardVisible { view.takeKeyboardFocus() }
        view.reportLayout()
    }

    static func dismantleNSView(_ view: GuestMetalView, coordinator: ()) {
        view.cancelTrackedTouches()
        view.releaseKeys()
        view.finishHostResize()
        if view.window?.firstResponder === view {
            view.window?.makeFirstResponder(nil)
        }
    }
}

/// The view the runtime draws the guest into, on a Mac.
///
/// The pointer is a finger on the guest's touchscreen: the primary button
/// touches, a scroll drags (`GuestScrollDrag`) and a pinch is two fingers
/// (`GuestPinch`), each a contact of its own. The secondary button is
/// Android's Back key. Keys reach the guest by position (`MacKeyboard`).
final class GuestMetalView: MTKView {
    var viewDidLayout: (@MainActor (
        GuestMetalView,
        GuestDisplayGeometry
    ) -> Void)?
    var touchDidBegin: (@MainActor () -> Void)?
    var retinaMode = false
    @objc private(set) var umlGuestResizeInProgress = false

    private enum Contact: Hashable {
        case pointer
        case scroll
        case pinch(Int)
    }

    /// Why the guest's display mode is held while the view changes size.
    private enum ResizeHold: Hashable {
        case liveResize
        case fullScreen
    }

    private var touchContacts = GuestTouchContacts<Contact>()
    private var guestContentSize: CGSize?
    private var keys = GuestKeyState()
    private var scrollDrag = GuestScrollDrag()
    private var pinch = GuestPinch()
    private var wheelIdle: DispatchWorkItem?
    private var resizeHolds: Set<ResizeHold> = []
    private var windowObservers: [NSObjectProtocol] = []
    private var fullScreenFallback: DispatchWorkItem?

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Layout

    override func layout() {
        super.layout()
        reportLayout()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        reportLayout()
    }

    func reportLayout() {
        guard let window else { return }
        let scale = retinaMode ? window.backingScaleFactor : 1
        guard bounds.width > 0, bounds.height > 0,
              scale.isFinite, scale > 0 else { return }
        // Point-resolution mode maps the view's points to guest pixels;
        // Retina mode maps its backing pixels.
        let pixelSize = CGSize(
            width: (bounds.width * scale).rounded(.down),
            height: (bounds.height * scale).rounded(.down)
        )
        guard pixelSize.width >= 1, pixelSize.height >= 1 else { return }
        drawableSize = pixelSize
        let dotsPerInch = UInt32((CGFloat(160) * scale).rounded())
        viewDidLayout?(
            self,
            GuestDisplayGeometry(pixelSize: pixelSize, dotsPerInch: dotsPerInch)
        )
    }

    // A live resize and a full-screen transition each pass through many
    // sizes; the guest keeps its mode until they settle, then gets the last.
    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        hold(.liveResize)
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        release(.liveResize)
    }

    private func hold(_ reason: ResizeHold) {
        let wasHeld = !resizeHolds.isEmpty
        resizeHolds.insert(reason)
        if !wasHeld { beginHostResize() }
    }

    private func release(_ reason: ResizeHold) {
        guard resizeHolds.remove(reason) != nil, resizeHolds.isEmpty else { return }
        finishHostResize()
    }

    func beginHostResize() {
        guard !umlGuestResizeInProgress else { return }
        umlGuestResizeInProgress = true
        NotificationCenter.default.post(name: .guestDisplayResizeWillBegin, object: self)
    }

    /// Ends every hold: the guest gets the size the view has now.
    func finishHostResize() {
        resizeHolds.removeAll()
        guard umlGuestResizeInProgress else { return }
        reportLayout()
        umlGuestResizeInProgress = false
        NotificationCenter.default.post(name: .guestDisplayResizeDidEnd, object: self)
    }

    @objc(umlSetGuestDisplayWidth:height:)
    func setGuestDisplay(width: UInt32, height: UInt32) {
        cancelTrackedTouches()
        guard width > 0, height > 0 else {
            guestContentSize = nil
            return
        }
        guestContentSize = CGSize(width: CGFloat(width), height: CGFloat(height))
    }

    // MARK: Window

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers = []
        guard let window else {
            cancelTrackedTouches()
            releaseKeys()
            return
        }
        // A window that is no longer key stops getting the keyboard and the
        // pointer, so nothing it holds may stay down in the guest.
        observe(window, NSWindow.didResignKeyNotification) {
            $0.releaseKeys()
            $0.cancelTrackedTouches()
        }
        observe(window, NSWindow.willEnterFullScreenNotification) { $0.holdForFullScreen() }
        observe(window, NSWindow.didEnterFullScreenNotification) { $0.release(.fullScreen) }
        observe(window, NSWindow.willExitFullScreenNotification) { $0.holdForFullScreen() }
        observe(window, NSWindow.didExitFullScreenNotification) { $0.release(.fullScreen) }
        reportLayout()
    }

    private func observe(
        _ window: NSWindow,
        _ name: Notification.Name,
        action: @escaping @MainActor (GuestMetalView) -> Void
    ) {
        windowObservers.append(NotificationCenter.default.addObserver(
            forName: name, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                if let self { action(self) }
            }
        })
    }

    /// A full-screen transition that fails sends no notification of its
    /// own, so a hold for one ends on its own after `fullScreenHoldSeconds`.
    private func holdForFullScreen() {
        hold(.fullScreen)
        fullScreenFallback?.cancel()
        let fallback = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.release(.fullScreen) }
        }
        fullScreenFallback = fallback
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.fullScreenHoldSeconds,
            execute: fallback
        )
    }

    private static let fullScreenHoldSeconds = 3.0

    func takeKeyboardFocus() {
        guard let window, window.firstResponder !== self else { return }
        window.makeFirstResponder(self)
    }

    // MARK: Pointer

    /// The event's position in the view, from its top-left corner, as the
    /// guest's touchscreen and the iOS view measure it.
    private func location(of event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: point.x, y: bounds.height - point.y)
    }

    override func mouseDown(with event: NSEvent) {
        takeKeyboardFocus()
        apply(.begin(location(of: event)), to: .pointer)
        touchDidBegin?()
    }

    override func mouseDragged(with event: NSEvent) {
        apply(.move(location(of: event)), to: .pointer)
    }

    override func mouseUp(with event: NSEvent) {
        apply(.end(location(of: event)), to: .pointer)
    }

    override func rightMouseDown(with event: NSEvent) {
        takeKeyboardFocus()
        if keys.press(MacKeyboard.backLinuxCode) {
            sendKey(code: MacKeyboard.backLinuxCode, pressed: true)
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        if keys.release(MacKeyboard.backLinuxCode) {
            sendKey(code: MacKeyboard.backLinuxCode, pressed: false)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let phase: GuestScrollDrag.Phase
        if !event.momentumPhase.isEmpty {
            phase = .momentum
        } else if event.phase.isEmpty {
            phase = .wheel
        } else if event.phase.contains(.began) {
            phase = .began
        } else if event.phase.contains(.changed) {
            phase = .changed
        } else if event.phase.contains(.ended) {
            phase = .ended
        } else if event.phase.contains(.cancelled) {
            phase = .cancelled
        } else {
            return
        }
        let perUnit = event.hasPreciseScrollingDeltas ? 1 : GuestScrollDrag.pointsPerLine
        let began = !scrollDrag.isActive
        let steps = scrollDrag.scroll(
            at: location(of: event),
            delta: CGVector(
                dx: event.scrollingDeltaX * perUnit,
                dy: event.scrollingDeltaY * perUnit
            ),
            phase: phase
        )
        steps.forEach { apply($0, to: .scroll) }
        if began, scrollDrag.isActive { touchDidBegin?() }
        if phase == .wheel { finishWheelWhenIdle() }
    }

    private func finishWheelWhenIdle() {
        wheelIdle?.cancel()
        let finish = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.scrollDrag.finish().forEach { self.apply($0, to: .scroll) }
            }
        }
        wheelIdle = finish
        DispatchQueue.main.asyncAfter(
            deadline: .now() + GuestScrollDrag.wheelIdleSeconds,
            execute: finish
        )
    }

    override func magnify(with event: NSEvent) {
        let steps: [GuestPinch.Step]
        if event.phase.contains(.began) {
            steps = pinch.begin(at: location(of: event)) + pinch.change(by: event.magnification)
        } else if event.phase.contains(.changed) {
            steps = pinch.change(by: event.magnification)
        } else if event.phase.contains(.ended) {
            steps = pinch.end()
        } else if event.phase.contains(.cancelled) {
            steps = pinch.cancel()
        } else {
            return
        }
        steps.forEach { apply($0.step, to: .pinch($0.finger)) }
        if event.phase.contains(.began) { touchDidBegin?() }
    }

    private func apply(_ step: GuestPointerStep, to contact: Contact) {
        let geometry = touchGeometry()
        switch step {
        case .begin(let point):
            sendTouchEvents(touchContacts.begin(contact, at: point, geometry: geometry))
        case .move(let point):
            sendTouchEvents(touchContacts.move(contact, through: [point], geometry: geometry))
        case .end(let point):
            sendTouchEvents(touchContacts.end(contact, at: point, geometry: geometry))
        case .cancel:
            sendTouchEvents(touchContacts.cancel(contact))
        }
    }

    private func touchGeometry() -> GuestTouchGeometry? {
        GuestTouchGeometry(
            coordinateSpace: .touchscreen,
            boundsSize: bounds.size,
            drawableSize: drawableSize,
            contentSize: guestContentSize ?? drawableSize
        )
    }

    private func sendTouchEvents(_ events: [GuestTouchContactEvent]) {
        for contact in events {
            if contact.event.cancelled {
                kernarium_runtime_loader_cancel_touch(contact.slot)
                continue
            }
            kernarium_runtime_loader_send_touch(
                contact.slot,
                contact.event.x,
                contact.event.y,
                contact.event.pressed ? 1 : 0
            )
        }
    }

    /// Withdraws every finger the guest has from the host, without a lift.
    func cancelTrackedTouches() {
        wheelIdle?.cancel()
        wheelIdle = nil
        _ = scrollDrag.cancel()
        _ = pinch.cancel()
        sendTouchEvents(touchContacts.cancelAll())
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        // Command's shortcuts are the host's.
        guard !event.modifierFlags.contains(.command),
              let code = MacKeyboard.linuxCode(macKeyCode: event.keyCode) else {
            super.keyDown(with: event)
            return
        }
        // The guest repeats a held key itself.
        if keys.press(code) { sendKey(code: code, pressed: true) }
    }

    override func keyUp(with event: NSEvent) {
        guard let code = MacKeyboard.linuxCode(macKeyCode: event.keyCode) else {
            super.keyUp(with: event)
            return
        }
        if keys.release(code) { sendKey(code: code, pressed: false) }
    }

    override func flagsChanged(with event: NSEvent) {
        let macKeyCode = event.keyCode
        if macKeyCode == MacKeyboard.capsLockMacKeyCode {
            sendKey(code: MacKeyboard.capsLockLinuxCode, pressed: true)
            sendKey(code: MacKeyboard.capsLockLinuxCode, pressed: false)
            return
        }
        guard let code = MacKeyboard.linuxCode(macKeyCode: macKeyCode),
              let down = MacKeyboard.modifierIsDown(
                  macKeyCode: macKeyCode,
                  modifierFlags: event.modifierFlags.rawValue
              ) else {
            super.flagsChanged(with: event)
            return
        }
        if down ? keys.press(code) : keys.release(code) {
            sendKey(code: code, pressed: down)
        }
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { releaseKeys() }
        return resigned
    }

    /// Releases in the guest every key it has been told is down.
    func releaseKeys() {
        for code in keys.releaseAll() {
            sendKey(code: code, pressed: false)
        }
    }

    private func sendKey(code: UInt16, pressed: Bool) {
        kernarium_runtime_loader_send_key(code, pressed ? 1 : 0)
    }
}
#endif
