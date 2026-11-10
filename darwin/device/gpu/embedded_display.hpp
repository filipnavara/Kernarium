// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once

#include "native_display_state.hpp"

#include <cstdint>
#include <memory>

namespace uml::gpu {

/* The state of a NativeDisplay that presents into an MTKView its host
 * application owns, on iOS and macOS alike: the application lays the view
 * out, delivers input through its own path, and brackets a live resize with
 * the guest-display resize notifications on that view. The view may adopt
 * umlSetGuestDisplayWidth:height: to learn the guest's size and
 * umlGuestResizeInProgress to report a resize already under way. */
[[nodiscard]] std::shared_ptr<NativeDisplayStateCore> makeEmbeddedDisplayState(
    std::uint32_t width,
    std::uint32_t height,
    void* nativeView,
    std::uint32_t maximumDimension,
    bool autoResizeGuest);

} // namespace uml::gpu
