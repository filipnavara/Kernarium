// SPDX-License-Identifier: GPL-2.0-or-later

#if os(macOS)
import AppKit
import SwiftUI

// The iOS names the screens use, with their Mac meaning, so a screen is one
// source on both platforms. A modifier with nothing to do on a Mac is the
// view itself.

extension NSColor {
    /// A grouped list's backdrop: the window's own background.
    static var systemGroupedBackground: NSColor { .windowBackgroundColor }
    /// A card on that backdrop.
    static var secondarySystemGroupedBackground: NSColor { .controlBackgroundColor }
    static var secondaryLabel: NSColor { .secondaryLabelColor }
    static var tertiaryLabel: NSColor { .tertiaryLabelColor }
}

/// A navigation bar's title modes; a Mac window titles itself.
enum NavigationBarTitleDisplayMode {
    case automatic
    case inline
    case large
}

/// A grouped list's section spacing; a Mac list keeps its own.
enum ListSectionSpacing {
    case compact
    case `default`
}

extension View {
    func navigationBarTitleDisplayMode(_ mode: NavigationBarTitleDisplayMode) -> some View { self }

    func listSectionSpacing(_ spacing: ListSectionSpacing) -> some View { self }

    /// A Mac window has no status bar.
    func statusBarHidden(_ hidden: Bool = true) -> some View { self }
}

extension ToolbarItemPlacement {
    static var topBarTrailing: ToolbarItemPlacement { .primaryAction }
}
#endif
