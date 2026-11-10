// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// The system's general pasteboard, which a copy button writes text to.
@MainActor
enum HostPasteboard {
    static func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}
