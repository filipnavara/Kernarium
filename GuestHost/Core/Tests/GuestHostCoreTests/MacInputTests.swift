// SPDX-License-Identifier: GPL-2.0-or-later

import CoreGraphics
import Foundation
import Testing

@testable import GuestHostCore

struct MacKeyboardTests {
    @Test func keysMapToTheLinuxKeyInTheSamePlace() {
        #expect(MacKeyboard.linuxCode(macKeyCode: 0x00) == 30) // A
        #expect(MacKeyboard.linuxCode(macKeyCode: 0x06) == 44) // Z
        #expect(MacKeyboard.linuxCode(macKeyCode: 0x12) == 2) // 1
        #expect(MacKeyboard.linuxCode(macKeyCode: 0x1D) == 11) // 0
        #expect(MacKeyboard.linuxCode(macKeyCode: 0x24) == 28) // Return
        #expect(MacKeyboard.linuxCode(macKeyCode: 0x33) == 14) // backspace
        #expect(MacKeyboard.linuxCode(macKeyCode: 0x35) == 1) // Escape
        #expect(MacKeyboard.linuxCode(macKeyCode: 0x7E) == 103) // up
        #expect(MacKeyboard.linuxCode(macKeyCode: 0x7A) == 59) // F1
        #expect(MacKeyboard.linuxCode(macKeyCode: 0x6F) == 88) // F12
    }

    @Test func everyLetterAndDigitHasItsOwnCode() {
        let letters: [UInt16] = [
            0x00, 0x0B, 0x08, 0x02, 0x0E, 0x03, 0x05, 0x04, 0x22, 0x26, 0x28,
            0x25, 0x2E, 0x2D, 0x1F, 0x23, 0x0C, 0x0F, 0x01, 0x11, 0x20, 0x09,
            0x0D, 0x07, 0x10, 0x06,
        ]
        let digits: [UInt16] = [0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19, 0x1D]
        let codes = (letters + digits).compactMap { MacKeyboard.linuxCode(macKeyCode: $0) }
        #expect(codes.count == 36)
        #expect(Set(codes).count == 36)
        #expect(digits.compactMap { MacKeyboard.linuxCode(macKeyCode: $0) } == Array(2...11))
    }

    @Test func everyMappedKeyIsOneTheGuestKeyboardAdvertises() {
        #expect(!MacKeyboard.table.isEmpty)
        #expect(MacKeyboard.table.values.allSatisfy { (1...127).contains($0) })
    }

    @Test func commandAndFunctionNeverReachTheGuest() {
        for code in MacKeyboard.commandMacKeyCodes {
            #expect(MacKeyboard.linuxCode(macKeyCode: code) == nil)
        }
        #expect(MacKeyboard.linuxCode(macKeyCode: 0x3F) == nil) // Fn
    }

    @Test func aModifierIsDownWhileItsOwnFlagIsSet() {
        let leftShift: UInt = 0x2
        let rightShift: UInt = 0x4
        #expect(MacKeyboard.modifierIsDown(macKeyCode: 0x38, modifierFlags: leftShift) == true)
        // The right Shift's flag says nothing about the left one.
        #expect(MacKeyboard.modifierIsDown(macKeyCode: 0x38, modifierFlags: rightShift) == false)
        #expect(MacKeyboard.modifierIsDown(macKeyCode: 0x3C, modifierFlags: rightShift) == true)
        #expect(MacKeyboard.modifierIsDown(macKeyCode: 0x00, modifierFlags: leftShift) == nil)
        #expect(MacKeyboard.modifierIsDown(
            macKeyCode: MacKeyboard.capsLockMacKeyCode, modifierFlags: 0
        ) == nil)
    }

    @Test func aHeldKeyIsPressedOnceAndReleasedOnFocusLoss() {
        var keys = GuestKeyState()
        let result1 = keys.press(30)
        #expect(result1)
        let result2 = keys.press(30)
        #expect(!result2) // the host's repeat
        let result3 = keys.press(42)
        #expect(result3)
        let result4 = keys.release(31)
        #expect(!result4)
        let result5 = keys.releaseAll()
        #expect(result5 == [42, 30])
        let result6 = keys.releaseAll()
        #expect(result6.isEmpty)
        let result7 = keys.release(30)
        #expect(!result7)
    }
}

struct GuestScrollDragTests {
    private let pointer = CGPoint(x: 100, y: 200)

    @Test func aTrackpadScrollIsOneDrag() {
        var drag = GuestScrollDrag()
        let result8 = drag.scroll(at: pointer, delta: CGVector(dx: 0, dy: 10), phase: .began)
        #expect(result8 == [
            .begin(pointer), .move(CGPoint(x: 100, y: 210)),
        ])
        let result9 = drag.scroll(at: pointer, delta: CGVector(dx: -5, dy: 10), phase: .changed)
        #expect(result9 == [
            .move(CGPoint(x: 95, y: 220)),
        ])
        let result10 = drag.scroll(at: pointer, delta: .zero, phase: .ended)
        #expect(result10 == [
            .end(CGPoint(x: 95, y: 220)),
        ])
        #expect(!drag.isActive)
        // The host's momentum after the lift moves nothing.
        let result11 = drag.scroll(at: pointer, delta: CGVector(dx: 0, dy: 30), phase: .momentum)
        #expect(result11.isEmpty)
    }

    @Test func aWheelDragsUntilTheHostFinishesIt() {
        var drag = GuestScrollDrag()
        let result12 = drag.scroll(at: pointer, delta: CGVector(dx: 0, dy: -40), phase: .wheel)
        #expect(result12 == [
            .begin(pointer), .move(CGPoint(x: 100, y: 160)),
        ])
        let result13 = drag.scroll(at: pointer, delta: CGVector(dx: 0, dy: -40), phase: .wheel)
        #expect(result13 == [
            .move(CGPoint(x: 100, y: 120)),
        ])
        let result14 = drag.finish()
        #expect(result14 == [.end(CGPoint(x: 100, y: 120))])
        let result15 = drag.finish()
        #expect(result15.isEmpty)
    }

    @Test func aNewScrollLiftsTheFingerOfTheLastOne() {
        var drag = GuestScrollDrag()
        _ = drag.scroll(at: pointer, delta: CGVector(dx: 0, dy: 10), phase: .wheel)
        let other = CGPoint(x: 10, y: 10)
        let result16 = drag.scroll(at: other, delta: .zero, phase: .began)
        #expect(result16 == [
            .end(CGPoint(x: 100, y: 210)), .begin(other),
        ])
    }

    @Test func aCancelledScrollIsWithdrawn() {
        var drag = GuestScrollDrag()
        _ = drag.scroll(at: pointer, delta: CGVector(dx: 0, dy: 10), phase: .began)
        let result17 = drag.scroll(at: pointer, delta: .zero, phase: .cancelled)
        #expect(result17 == [.cancel])
        let result18 = drag.cancel()
        #expect(result18.isEmpty)
    }
}

struct GuestPinchTests {
    private let pointer = CGPoint(x: 300, y: 200)

    @Test func twoFingersLandEitherSideOfThePointer() {
        var pinch = GuestPinch()
        let result19 = pinch.begin(at: pointer)
        #expect(result19 == [
            .init(finger: 0, step: .begin(CGPoint(x: 220, y: 200))),
            .init(finger: 1, step: .begin(CGPoint(x: 380, y: 200))),
        ])
    }

    @Test func theFingersFollowTheMagnification() {
        var pinch = GuestPinch()
        _ = pinch.begin(at: pointer)
        let result20 = pinch.change(by: 0.5)
        #expect(result20 == [
            .init(finger: 0, step: .move(CGPoint(x: 180, y: 200))),
            .init(finger: 1, step: .move(CGPoint(x: 420, y: 200))),
        ])
        let result21 = pinch.end()
        #expect(result21 == [
            .init(finger: 0, step: .end(CGPoint(x: 180, y: 200))),
            .init(finger: 1, step: .end(CGPoint(x: 420, y: 200))),
        ])
        #expect(!pinch.isActive)
    }

    @Test func theFingersNeverMeet() {
        var pinch = GuestPinch()
        _ = pinch.begin(at: pointer)
        let steps = pinch.change(by: -0.99)
        #expect(steps == [
            .init(finger: 0, step: .move(CGPoint(x: 292, y: 200))),
            .init(finger: 1, step: .move(CGPoint(x: 308, y: 200))),
        ])
    }

    @Test func aCancelledPinchWithdrawsBothFingers() {
        var pinch = GuestPinch()
        _ = pinch.begin(at: pointer)
        let result22 = pinch.cancel()
        #expect(result22 == [
            .init(finger: 0, step: .cancel), .init(finger: 1, step: .cancel),
        ])
        let result23 = pinch.change(by: 0.2)
        #expect(result23.isEmpty)
    }
}
