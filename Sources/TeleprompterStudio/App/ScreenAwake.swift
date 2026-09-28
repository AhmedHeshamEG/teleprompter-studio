import SwiftUI
import UIKit

/// Keeps the phone from auto-locking while a screen that's in the middle of a take is up.
///
/// iOS's idle timer only counts touches, so a phone sitting on a tripod — recording, or scrolling
/// the script for another camera — looked idle and locked itself mid-take, which kills the camera
/// session along with the screen. Ref-counted rather than a plain flag because Studio, Voice and
/// Companion can overlap during a transition (one's `onDisappear` lands after the next one's
/// `onAppear`), and the one leaving must not switch the lock back on under the one arriving.
@MainActor
enum ScreenAwake {
    private static var holders = 0

    static func acquire() {
        holders += 1
        UIApplication.shared.isIdleTimerDisabled = true
    }

    static func release() {
        holders = max(0, holders - 1)
        if holders == 0 { UIApplication.shared.isIdleTimerDisabled = false }
    }
}

extension View {
    /// Holds the screen awake for as long as this view is on screen.
    func keepsScreenAwake() -> some View {
        onAppear { ScreenAwake.acquire() }
            .onDisappear { ScreenAwake.release() }
    }
}
