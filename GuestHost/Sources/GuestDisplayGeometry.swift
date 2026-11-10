// SPDX-License-Identifier: GPL-2.0-or-later

import CoreGraphics
import Foundation

/// The guest display's size in pixels and density, as the host view lays it
/// out on either platform.
struct GuestDisplayGeometry {
    let pixelSize: CGSize
    let dotsPerInch: UInt32
}

/// The notifications that bracket a host resize on the guest's view. The
/// runtime's display (darwin/device/gpu/embedded_display.mm) observes them on
/// the view it draws into and holds the guest's display mode between them.
extension Notification.Name {
    static let guestDisplayResizeWillBegin = Notification.Name(
        "org.linux-um-darwin.guest-display-resize-will-begin"
    )
    static let guestDisplayResizeDidEnd = Notification.Name(
        "org.linux-um-darwin.guest-display-resize-did-end"
    )
}
