// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// A Mac's physical keys as the guest's Linux keyboard sees them.
///
/// A Mac reports each key by its virtual key code, the position of the key on
/// an ANSI keyboard, whatever the layout prints on it; the guest's keyboard is
/// a Linux one, whose codes are positions too. A key maps to the key in the
/// same place, so the guest's own layout decides the character, as it does
/// for a USB keyboard. Command is the host's: its shortcuts go to the
/// application's menus and it reaches the guest neither alone nor with
/// another key. The Fn key has no Linux counterpart.
///
/// The secondary mouse button is Android's Back key (`backLinuxCode`), which
/// the guest's keyboard advertises beside its keys.
public enum MacKeyboard {
    /// The Linux code of the key at `macKeyCode`, or nil for a key the guest
    /// does not get.
    public static func linuxCode(macKeyCode: UInt16) -> UInt16? {
        table[macKeyCode]
    }

    /// Whether the modifier key `macKeyCode` is down in `modifierFlags`, an
    /// event's raw modifier flags, which tell the left and right keys apart;
    /// nil for a key that is not a modifier the guest gets.
    ///
    /// A modifier's own event says only that it changed: whether it went
    /// down or up is read from the flags that came with it. Caps Lock's flag
    /// is its lock, not the key: every change is one press of the key.
    public static func modifierIsDown(
        macKeyCode: UInt16,
        modifierFlags: UInt
    ) -> Bool? {
        guard let mask = deviceModifierMasks[macKeyCode] else { return nil }
        return modifierFlags & mask != 0
    }

    public static let capsLockMacKeyCode: UInt16 = 0x39
    public static let capsLockLinuxCode: UInt16 = 58
    /// Linux's KEY_BACK, which Android's Generic key layout maps to Back.
    public static let backLinuxCode: UInt16 = 158
    public static let commandMacKeyCodes: Set<UInt16> = [0x36, 0x37]

    // Device-dependent modifier bits of an event's modifier flags (IOKit's
    // NX_DEVICE*KEYMASK), one per physical key.
    private static let deviceModifierMasks: [UInt16: UInt] = [
        0x3B: 0x0000_0001, // left Control
        0x38: 0x0000_0002, // left Shift
        0x3C: 0x0000_0004, // right Shift
        0x3A: 0x0000_0020, // left Option
        0x3D: 0x0000_0040, // right Option
        0x3E: 0x0000_2000, // right Control
    ]

    // Mac virtual key codes (HIToolbox kVK_*) to Linux input event codes
    // (linux/input-event-codes.h). The guest's keyboard advertises the codes
    // 1 through 127 (darwin/device/input/virtio/protocol.hpp) and delivers no
    // other, so F13 to F20 and the keys past 127 have no entry.
    static let table: [UInt16: UInt16] = [
        // Letters.
        0x00: 30, 0x0B: 48, 0x08: 46, 0x02: 32, 0x0E: 18, 0x03: 33,
        0x05: 34, 0x04: 35, 0x22: 23, 0x26: 36, 0x28: 37, 0x25: 38,
        0x2E: 50, 0x2D: 49, 0x1F: 24, 0x23: 25, 0x0C: 16, 0x0F: 19,
        0x01: 31, 0x11: 20, 0x20: 22, 0x09: 47, 0x0D: 17, 0x07: 45,
        0x10: 21, 0x06: 44,
        // Digits.
        0x12: 2, 0x13: 3, 0x14: 4, 0x15: 5, 0x17: 6, 0x16: 7,
        0x1A: 8, 0x1C: 9, 0x19: 10, 0x1D: 11,
        // Punctuation.
        0x1B: 12, // minus
        0x18: 13, // equal
        0x21: 26, // left bracket
        0x1E: 27, // right bracket
        0x29: 39, // semicolon
        0x27: 40, // quote
        0x32: 41, // grave
        0x2A: 43, // backslash
        0x2B: 51, // comma
        0x2F: 52, // period
        0x2C: 53, // slash
        0x0A: 86, // ISO section, the key beside left Shift (KEY_102ND)
        // Editing and whitespace.
        0x35: 1, // Escape
        0x33: 14, // Delete: backspace
        0x30: 15, // Tab
        0x24: 28, // Return
        0x31: 57, // Space
        0x75: 111, // forward delete
        0x72: 110, // Help, where a PC keyboard has Insert
        // Modifiers.
        0x3B: 29, // left Control
        0x38: 42, // left Shift
        0x3C: 54, // right Shift
        0x3A: 56, // left Option: left Alt
        0x3E: 97, // right Control
        0x3D: 100, // right Option: right Alt
        0x39: 58, // Caps Lock
        // Navigation.
        0x73: 102, // Home
        0x7E: 103, // up
        0x74: 104, // Page Up
        0x7B: 105, // left
        0x7C: 106, // right
        0x77: 107, // End
        0x7D: 108, // down
        0x79: 109, // Page Down
        // Function keys.
        0x7A: 59, 0x78: 60, 0x63: 61, 0x76: 62, 0x60: 63, 0x61: 64,
        0x62: 65, 0x64: 66, 0x65: 67, 0x6D: 68, 0x67: 87, 0x6F: 88,
        // Keypad.
        0x52: 82, 0x53: 79, 0x54: 80, 0x55: 81, 0x56: 75, 0x57: 76,
        0x58: 77, 0x59: 71, 0x5B: 72, 0x5C: 73,
        0x41: 83, // decimal
        0x43: 55, // multiply
        0x45: 78, // plus
        0x4E: 74, // minus
        0x4B: 98, // divide
        0x4C: 96, // Enter
        0x51: 117, // equals
        0x47: 69, // Clear, where a PC keypad has Num Lock
        // Media keys that arrive as keys.
        0x4A: 113, // mute
        0x49: 114, // volume down
        0x48: 115, // volume up
        // JIS keys.
        0x5D: 124, // yen
        0x5E: 89, // underscore (KEY_RO)
        0x5F: 95, // keypad comma (KEY_KPJPCOMMA)
        0x66: 94, // Eisu (KEY_MUHENKAN)
        0x68: 92, // Kana (KEY_HENKAN)
    ]
}

/// The guest's keys that are down, so that none stays down in the guest when
/// the host stops telling it about the keyboard: when the display loses the
/// keyboard focus, or its window does, the held keys are released.
public struct GuestKeyState: Sendable {
    private var down: [UInt16] = []

    public init() {}

    /// Whether a press of `code` is news to the guest; a key the host
    /// repeats while it is held is not.
    public mutating func press(_ code: UInt16) -> Bool {
        guard !down.contains(code) else { return false }
        down.append(code)
        return true
    }

    /// Whether a release of `code` is news to the guest: only a key it has
    /// been told is down can come up.
    public mutating func release(_ code: UInt16) -> Bool {
        guard let index = down.firstIndex(of: code) else { return false }
        down.remove(at: index)
        return true
    }

    /// Every key that is down, latest first, and none is any longer.
    public mutating func releaseAll() -> [UInt16] {
        defer { down.removeAll() }
        return down.reversed()
    }
}
