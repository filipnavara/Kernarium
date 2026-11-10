// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// What the run asks of the host application, on each platform.
///
/// An iOS application in the background is suspended, so the guest is paused
/// as Andarium leaves the foreground and woken as it returns. A Mac
/// application keeps running in the background, and so does its guest: the
/// only edges are becoming active, which rereads what may have changed while
/// Andarium was away, and termination.
@MainActor
enum HostApplication {
    enum Edge {
        case willResignActive
        case didEnterBackground
        case willEnterForeground
        case willTerminate
        case didBecomeActive
    }

    #if os(iOS)
    static var isActive: Bool { UIApplication.shared.applicationState == .active }

    static let edges: [(Notification.Name, Edge)] = [
        (UIApplication.willResignActiveNotification, .willResignActive),
        (UIApplication.didEnterBackgroundNotification, .didEnterBackground),
        (UIApplication.willEnterForegroundNotification, .willEnterForeground),
        (UIApplication.willTerminateNotification, .willTerminate),
        (UIApplication.didBecomeActiveNotification, .didBecomeActive),
    ]

    /// Keeps the screen on while a guest runs.
    static func guestRunning(_ running: Bool) {
        UIApplication.shared.isIdleTimerDisabled = running
    }
    #else
    /// A Mac guest runs whether or not Andarium is the active application.
    static var isActive: Bool { true }

    static let edges: [(Notification.Name, Edge)] = [
        (NSApplication.willTerminateNotification, .willTerminate),
        (NSApplication.didBecomeActiveNotification, .didBecomeActive),
    ]

    private static var activity: NSObjectProtocol?

    /// While a guest runs, the display stays on and the process is not
    /// napped: App Nap would run every thread of the guest at background
    /// priority and coalesce its timers, whatever the window shows.
    static func guestRunning(_ running: Bool) {
        if running {
            guard activity == nil else { return }
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleDisplaySleepDisabled, .latencyCritical],
                reason: "Running a guest")
        } else if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }
    #endif
}

/// A background-task assertion that keeps the process scheduled until it ends:
/// the caller ends it, or iOS expires it. Ending it twice is harmless. A Mac
/// does not suspend a background application, so there it asserts nothing.
@MainActor
final class PauseTaskAssertion {
    #if os(iOS)
    private var identifier = UIBackgroundTaskIdentifier.invalid

    init(named name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
    #else
    init(named name: String) {}

    func end() {}
    #endif
}
