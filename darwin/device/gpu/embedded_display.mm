// SPDX-License-Identifier: GPL-2.0-or-later

#include "embedded_display.hpp"

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>

#include <atomic>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <utility>

namespace uml::gpu {
namespace {

NSString* const resizeWillBeginNotification =
    @"org.linux-um-darwin.guest-display-resize-will-begin";
NSString* const resizeDidEndNotification =
    @"org.linux-um-darwin.guest-display-resize-did-end";
constexpr std::int64_t resizeSettleNanoseconds =
    150LL * NSEC_PER_MSEC;

} // namespace

struct EmbeddedDisplayState final :
    public NativeDisplayStateCore,
    public std::enable_shared_from_this<EmbeddedDisplayState> {
    EmbeddedDisplayState(
        std::uint32_t width,
        std::uint32_t height,
        std::uint32_t maximumDimension,
        bool autoResizeGuest)
        : NativeDisplayStateCore(
              width, height, maximumDimension, autoResizeGuest)
    {
    }

    void attachView(void* nativeView);
    void scheduleResize(CGSize size) noexcept;
    void beginResize() noexcept;
    void commitResize(CGSize size) noexcept;
    [[nodiscard]] bool guestScanoutChanged(
        std::uint32_t width,
        std::uint32_t height) noexcept override;
    void resetGuestSession() noexcept override;
    void publishGuestSize(DisplaySize size) noexcept;
    void requestRedraw() noexcept;
    void shutdown() noexcept override;

    id<MTKViewDelegate> delegate;
    id resizeWillBeginObserver;
    id resizeDidEndObserver;
    __weak MTKView* view;
    std::atomic_bool running {true};
    std::atomic_bool redrawScheduled {};
    std::atomic_uint64_t resizeGeneration {};
    DisplaySize latestSettledHostSize;
};

} // namespace uml::gpu

@interface UmlEmbeddedMetalViewDelegate : NSObject <MTKViewDelegate>
- (instancetype)initWithState:
    (std::weak_ptr<uml::gpu::EmbeddedDisplayState>)state;
@end

@protocol UmlEmbeddedGuestResizeLifecycle <NSObject>
@property(nonatomic, readonly) BOOL umlGuestResizeInProgress;
@end

@protocol UmlEmbeddedGuestDisplayGeometry <NSObject>
- (void)umlSetGuestDisplayWidth:(uint32_t)width height:(uint32_t)height;
@end

@implementation UmlEmbeddedMetalViewDelegate {
    std::weak_ptr<uml::gpu::EmbeddedDisplayState> _state;
}

- (instancetype)initWithState:
    (std::weak_ptr<uml::gpu::EmbeddedDisplayState>)state
{
    self = [super init];
    if (self != nil)
        _state = std::move(state);
    return self;
}

- (void)mtkView:(MTKView*)view drawableSizeWillChange:(CGSize)size
{
    (void)view;
    if (auto state = _state.lock()) {
        state->presentation.drawableSizeChanged();
        state->scheduleResize(size);
    }
}

- (void)drawInMTKView:(MTKView*)view
{
    if (auto state = _state.lock())
        state->presentation.draw((__bridge void*)view);
}

@end

namespace uml::gpu {

void EmbeddedDisplayState::attachView(void* nativeView)
{
    if (nativeView == nullptr)
        throw std::invalid_argument("the embedded display needs an MTKView");
    MTKView* metalView = (__bridge MTKView*)nativeView;
    if (![metalView isKindOfClass:MTKView.class])
        throw std::invalid_argument("the embedded display view is not an MTKView");
    auto state = shared_from_this();
    presentation.setRedrawCallback([weak = weak_from_this()] {
        if (auto locked = weak.lock())
            locked->requestRedraw();
    });
    const auto configure = ^{
        metalView.device = (__bridge id<MTLDevice>)state->presentation.device();
        metalView.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
        metalView.clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
        metalView.framebufferOnly = YES;
        metalView.enableSetNeedsDisplay = YES;
        metalView.paused = YES;
        metalView.autoResizeDrawable = NO;
        UmlEmbeddedMetalViewDelegate* viewDelegate =
            [[UmlEmbeddedMetalViewDelegate alloc] initWithState:state];
        state->view = metalView;
        state->delegate = viewDelegate;
        metalView.delegate = viewDelegate;
        const auto guestSize = state->geometryPolicy.activeGuestSize();
        if ([metalView respondsToSelector:
                @selector(umlSetGuestDisplayWidth:height:)]) {
            [(id<UmlEmbeddedGuestDisplayGeometry>)metalView
                umlSetGuestDisplayWidth:guestSize.width
                height:guestSize.height];
        }
        NSNotificationCenter* center = NSNotificationCenter.defaultCenter;
        auto weak = state->weak_from_this();
        state->resizeWillBeginObserver = [center
            addObserverForName:resizeWillBeginNotification
                        object:metalView
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification*) {
                        if (auto locked = weak.lock())
                            locked->beginResize();
                    }];
        state->resizeDidEndObserver = [center
            addObserverForName:resizeDidEndNotification
                        object:metalView
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification*) {
                        if (auto locked = weak.lock())
                            locked->commitResize(metalView.drawableSize);
                    }];
        const bool transitionActive =
            [metalView respondsToSelector:@selector(umlGuestResizeInProgress)] &&
            [(id<UmlEmbeddedGuestResizeLifecycle>)metalView
                umlGuestResizeInProgress];
        if (transitionActive)
            state->beginResize();
        else
            state->commitResize(metalView.drawableSize);
        [metalView draw];
    };
    if ([NSThread isMainThread])
        configure();
    else
        dispatch_sync(dispatch_get_main_queue(), configure);
}

void EmbeddedDisplayState::beginResize() noexcept
{
    std::lock_guard lock(resizeLifecycleMutex);
    resizeInProgress.store(true, std::memory_order_release);
    resizeGeneration.fetch_add(1, std::memory_order_acq_rel);
}

void EmbeddedDisplayState::commitResize(CGSize size) noexcept
{
    std::lock_guard lock(resizeLifecycleMutex);
    resizeGeneration.fetch_add(1, std::memory_order_acq_rel);
    const auto width = displayDimension(
        size.width, resizeNotifier.maximumDimension());
    const auto height = displayDimension(
        size.height, resizeNotifier.maximumDimension());
    if (width && height &&
        running.load(std::memory_order_acquire)) {
        latestSettledHostSize = {.width = *width, .height = *height};
        resizeNotifier.requestCommitted(*width, *height);
        resizeCommitPending.store(true, std::memory_order_release);
    }
    resizeInProgress.store(false, std::memory_order_release);
}

void EmbeddedDisplayState::scheduleResize(CGSize size) noexcept
{
    const auto width = displayDimension(
        size.width, resizeNotifier.maximumDimension());
    const auto height = displayDimension(
        size.height, resizeNotifier.maximumDimension());
    if (!width || !height)
        return;
    std::uint64_t generation;
    {
        std::lock_guard lock(resizeLifecycleMutex);
        if (resizeInProgress.load(std::memory_order_acquire))
            return;
        generation =
            resizeGeneration.fetch_add(1, std::memory_order_acq_rel) + 1U;
    }
    auto weak = weak_from_this();
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, resizeSettleNanoseconds),
        dispatch_get_main_queue(),
        ^{
            if (auto state = weak.lock()) {
                std::lock_guard lock(state->resizeLifecycleMutex);
                if (state->running.load(std::memory_order_acquire) &&
                    !state->resizeInProgress.load(std::memory_order_acquire) &&
                    state->resizeGeneration.load(std::memory_order_acquire) ==
                        generation) {
                    state->latestSettledHostSize = {
                        .width = *width,
                        .height = *height,
                    };
                    state->resizeNotifier.request(*width, *height);
                }
            }
        });
}

void EmbeddedDisplayState::publishGuestSize(DisplaySize size) noexcept
{
    auto weak = weak_from_this();
    dispatch_async(dispatch_get_main_queue(), ^{
        if (auto state = weak.lock()) {
            if (!state->running.load(std::memory_order_acquire))
                return;
            MTKView* nativeView = state->view;
            if ([nativeView respondsToSelector:
                    @selector(umlSetGuestDisplayWidth:height:)]) {
                [(id<UmlEmbeddedGuestDisplayGeometry>)nativeView
                    umlSetGuestDisplayWidth:size.width
                    height:size.height];
            }
        }
    });
}

bool EmbeddedDisplayState::guestScanoutChanged(
    std::uint32_t width,
    std::uint32_t height) noexcept
{
    DisplaySize guestSize;
    bool changed = false;
    bool publishFrame = false;
    {
        std::lock_guard lock(resizeLifecycleMutex);
        const auto& framebuffer = presentation.framebuffer();
        const bool presentationChanged =
            framebuffer.width() != width || framebuffer.height() != height;
        if (presentationChanged) {
            if (!presentation.resize(width, height, false))
                return false;
            publishFrame = true;
        }
        changed = geometryPolicy.guestScanoutChanged(width, height);
        guestSize = geometryPolicy.activeGuestSize();
    }
    if (changed)
        publishGuestSize(guestSize);
    if (changed || publishFrame) {
        /* The view coordinate update above reaches the main queue before the
         * redraw requested here can expose the new aspect ratio. */
        presentation.publishCpuFrame();
    }
    return true;
}

void EmbeddedDisplayState::resetGuestSession() noexcept
{
    DisplaySize guestSize;
    {
        std::lock_guard lock(resizeLifecycleMutex);
        /* Discard any pre-reset readiness byte before restoring the newest
         * settled host geometry below. Otherwise the transport could later
         * consume a stale size and advertise it as a post-reset resize. */
        (void)resizeNotifier.drain();
        if (latestSettledHostSize.width != 0 &&
            latestSettledHostSize.height != 0) {
            (void)geometryPolicy.hostSizeSettled(
                latestSettledHostSize.width,
                latestSettledHostSize.height);
        }
        const auto restored = geometryPolicy.settledHostSize();
        const auto& framebuffer = presentation.framebuffer();
        const DisplaySize presented {
            .width = framebuffer.width(),
            .height = framebuffer.height(),
        };
        const bool presentationReady = presented == restored ||
            presentation.resize(restored.width, restored.height, false);
        geometryPolicy.resetGuestSession(
            presentationReady ? restored : presented);
        guestSize = geometryPolicy.activeGuestSize();
        resizeGeneration.fetch_add(1, std::memory_order_acq_rel);
        resizeCommitPending.store(false, std::memory_order_release);
    }
    publishGuestSize(guestSize);
}

void EmbeddedDisplayState::requestRedraw() noexcept
{
    if (!running.load(std::memory_order_acquire) ||
        redrawScheduled.exchange(true, std::memory_order_acq_rel)) {
        return;
    }
    auto state = shared_from_this();
    dispatch_async(dispatch_get_main_queue(), ^{
        state->redrawScheduled.store(false, std::memory_order_release);
        if (!state->running.load(std::memory_order_acquire))
            return;
        MTKView* nativeView = state->view;
        if (nativeView != nil)
            [nativeView draw];
    });
}

void EmbeddedDisplayState::shutdown() noexcept
{
    if (!running.exchange(false, std::memory_order_acq_rel))
        return;
    {
        std::lock_guard lock(resizeLifecycleMutex);
        resizeInProgress.store(true, std::memory_order_release);
        resizeGeneration.fetch_add(1, std::memory_order_acq_rel);
    }
    presentation.shutdown();
    auto state = shared_from_this();
    dispatch_async(dispatch_get_main_queue(), ^{
        MTKView* nativeView = state->view;
        if (nativeView.delegate == state->delegate)
            nativeView.delegate = nil;
        NSNotificationCenter* center = NSNotificationCenter.defaultCenter;
        if (state->resizeWillBeginObserver != nil)
            [center removeObserver:state->resizeWillBeginObserver];
        if (state->resizeDidEndObserver != nil)
            [center removeObserver:state->resizeDidEndObserver];
        state->view = nil;
        state->delegate = nil;
        state->resizeWillBeginObserver = nil;
        state->resizeDidEndObserver = nil;
    });
}

std::shared_ptr<NativeDisplayStateCore> makeEmbeddedDisplayState(
    std::uint32_t width,
    std::uint32_t height,
    void* nativeView,
    std::uint32_t maximumDimension,
    bool autoResizeGuest)
{
    auto state = std::make_shared<EmbeddedDisplayState>(
        width, height, maximumDimension, autoResizeGuest);
    state->attachView(nativeView);
    return state;
}

} // namespace uml::gpu
