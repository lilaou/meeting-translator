import MeetingCore
import SwiftUI
import UIKit

extension SessionCoordinator.State {
    /// The screen must stay on from the moment the meeting is being set up until it is over
    /// (obligation 17); `idle` and `failed` let it sleep again.
    var keepsScreenAwake: Bool {
        switch self {
        case .preparing, .listening, .finishing: true
        case .idle, .failed: false
        }
    }
}

private struct KeepScreenAwake: ViewModifier {
    let isOn: Bool

    func body(content: Content) -> some View {
        content
            // `initial: true` applies the current value on appear; every later change (state
            // returning to idle/failed) is applied here too ...
            .onChange(of: isOn, initial: true) { _, on in
                UIApplication.shared.isIdleTimerDisabled = on
            }
            // ... and leaving the page always restores the system default, so the flag
            // cannot leak past the view that set it.
            .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }
}

extension View {
    /// The one place that touches `isIdleTimerDisabled`.
    func keepScreenAwake(_ isOn: Bool) -> some View { modifier(KeepScreenAwake(isOn: isOn)) }
}
