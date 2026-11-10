// SPDX-License-Identifier: GPL-2.0-or-later

import CoreGraphics
import Foundation

/// What one synthesized finger does on the guest's touchscreen, at a point of
/// the host view (top-left origin, the view's points). A cancelled finger is
/// withdrawn where it was without a lift, so no tap follows.
public enum GuestPointerStep: Equatable, Sendable {
    case begin(CGPoint)
    case move(CGPoint)
    case end(CGPoint)
    case cancel
}

/// A Mac scroll as the guest's touchscreen sees it: a finger that lands where
/// the pointer is and drags the content the way the scroll moves it. A guest
/// has no scroll wheel, and a drag is how it scrolls.
///
/// A trackpad scroll has phases: the finger lands as it begins, follows each
/// change, and lifts when the fingers leave the trackpad. The momentum that
/// follows is the host's own fling; the guest flings from the speed of the
/// drag, so momentum moves nothing. A wheel has no phases: each notch moves
/// the finger, and it lifts when the wheel has been still for
/// `wheelIdleSeconds`, which the host times and reports with `finish()`.
public struct GuestScrollDrag: Sendable {
    public enum Phase: Equatable, Sendable {
        case began
        case changed
        case ended
        case cancelled
        /// The host's momentum after the fingers lifted.
        case momentum
        /// A wheel notch, which has no phase.
        case wheel
    }

    public static let wheelIdleSeconds = 0.15
    /// How far one line of a wheel without precise deltas drags.
    public static let pointsPerLine = CGFloat(40)

    private var position: CGPoint?

    public init() {}

    /// Whether a finger is down.
    public var isActive: Bool { position != nil }

    /// The steps one scroll event takes. `location` is the pointer, and
    /// `delta` how far the event moves the content: positive x to the right
    /// and positive y down, the way the finger moves.
    public mutating func scroll(
        at location: CGPoint,
        delta: CGVector,
        phase: Phase
    ) -> [GuestPointerStep] {
        switch phase {
        case .began:
            var steps = finish()
            position = location
            steps.append(.begin(location))
            return steps + move(by: delta)
        case .changed, .wheel:
            var steps: [GuestPointerStep] = []
            if position == nil {
                position = location
                steps.append(.begin(location))
            }
            return steps + move(by: delta)
        case .ended:
            return finish()
        case .cancelled:
            return cancel()
        case .momentum:
            return []
        }
    }

    /// Lifts the finger where it is.
    public mutating func finish() -> [GuestPointerStep] {
        guard let position else { return [] }
        self.position = nil
        return [.end(position)]
    }

    /// Withdraws the finger without a lift.
    public mutating func cancel() -> [GuestPointerStep] {
        guard position != nil else { return [] }
        position = nil
        return [.cancel]
    }

    private mutating func move(by delta: CGVector) -> [GuestPointerStep] {
        guard let start = position, delta.dx.isFinite, delta.dy.isFinite,
              delta.dx != 0 || delta.dy != 0 else { return [] }
        let next = CGPoint(x: start.x + delta.dx, y: start.y + delta.dy)
        position = next
        return [.move(next)]
    }
}

/// A Mac pinch as the guest's touchscreen sees it: two fingers either side of
/// the pointer, level with it, whose distance follows the magnification. The
/// fingers start `startSpread` apart, so the guest has room to tell the pinch
/// from a tap, and never come closer than `minimumSpread`.
public struct GuestPinch: Sendable {
    public static let startSpread = CGFloat(160)
    public static let minimumSpread = CGFloat(16)

    /// A step of one of the two fingers, `finger` 0 or 1.
    public struct Step: Equatable, Sendable {
        public let finger: Int
        public let step: GuestPointerStep

        public init(finger: Int, step: GuestPointerStep) {
            self.finger = finger
            self.step = step
        }
    }

    private var center: CGPoint?
    private var scale = CGFloat(1)

    public init() {}

    public var isActive: Bool { center != nil }

    /// Both fingers land around `location`.
    public mutating func begin(at location: CGPoint) -> [Step] {
        var steps = end()
        center = location
        scale = 1
        steps += positions().enumerated().map {
            Step(finger: $0.offset, step: .begin($0.element))
        }
        return steps
    }

    /// The pinch grew by `magnification`, an event's change in it (0.1 is
    /// ten percent wider than the pinch was).
    public mutating func change(by magnification: CGFloat) -> [Step] {
        guard center != nil, magnification.isFinite else { return [] }
        scale = max(scale * (1 + magnification), Self.minimumSpread / Self.startSpread)
        return positions().enumerated().map {
            Step(finger: $0.offset, step: .move($0.element))
        }
    }

    /// Both fingers lift where they are.
    public mutating func end() -> [Step] {
        guard center != nil else { return [] }
        let steps = positions().enumerated().map {
            Step(finger: $0.offset, step: .end($0.element))
        }
        center = nil
        return steps
    }

    /// Both fingers are withdrawn without a lift.
    public mutating func cancel() -> [Step] {
        guard center != nil else { return [] }
        center = nil
        return [Step(finger: 0, step: .cancel), Step(finger: 1, step: .cancel)]
    }

    private func positions() -> [CGPoint] {
        guard let center else { return [] }
        let half = max(Self.startSpread * scale, Self.minimumSpread) / 2
        return [
            CGPoint(x: center.x - half, y: center.y),
            CGPoint(x: center.x + half, y: center.y),
        ]
    }
}
