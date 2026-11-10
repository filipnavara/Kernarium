// SPDX-License-Identifier: GPL-2.0-or-later

#include "native_display.hpp"

#include "embedded_display.hpp"

#include <utility>

namespace uml::gpu {

/* An iOS guest display is always the application's own view. */
NativeDisplay::NativeDisplay(
    std::uint32_t width,
    std::uint32_t height,
    uml::input::vnc::VncInputSink,
    void* nativeView,
    uml::input::vnc::PointerMode,
    std::uint32_t maximumDimension,
    bool autoResizeGuest)
    : state_(makeEmbeddedDisplayState(
          width, height, nativeView, maximumDimension, autoResizeGuest))
{
}

} // namespace uml::gpu
