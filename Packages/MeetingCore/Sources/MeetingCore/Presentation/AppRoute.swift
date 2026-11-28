import Foundation
import Observation

/// Which page the app shows. At launch the readiness preflight (pack states only: offline, no
/// self-test) decides once; after that only the user moves, so no later change of the packs or
/// of the onboarding takes them to another page.
@MainActor @Observable public final class AppRoute {
    public enum Page: Equatable, Sendable {
        /// The launch preflight has not answered yet.
        case launching
        /// Language choice, language packs and self-test.
        case onboarding
        /// The caption page. A pack that went missing is reported there by
        /// `SessionCoordinator.start`'s own preflight.
        case captions
        /// The face-to-face conversation, opened from the captions or the onboarding.
        case faceToFace
        /// The saved meetings and conversations, opened from the captions or the onboarding.
        case history
    }

    public private(set) var page: Page = .launching

    @ObservationIgnored private let readiness: any ReadinessChecking
    @ObservationIgnored private var hasLaunched = false
    /// Where `closeFaceToFace` returns to.
    @ObservationIgnored private var pageBeforeFaceToFace: Page = .captions
    /// Where `closeHistory` returns to.
    @ObservationIgnored private var pageBeforeHistory: Page = .captions

    /// `readiness` is the instance the coordinator and the onboarding use.
    public init(readiness: any ReadinessChecking) { self.readiness = readiness }

    /// Call when the launch page appears; only the first call does anything. A passing
    /// preflight of `locale` leads to the captions, any error to the onboarding, unless the
    /// page has changed meanwhile.
    ///
    /// The preflight runs in a task of its own: cancelling the caller (SwiftUI cancels a
    /// view's `.task` when the view goes away) must not be read as "not ready".
    public func launch(locale: Locale) async {
        guard !hasLaunched else { return }
        hasLaunched = true
        await Task {
            let next: Page
            do {
                try await readiness.preflight(locale: locale)
                next = .captions
            } catch {
                next = .onboarding
            }
            if page == .launching { page = next }
        }.value
    }

    /// The user tapped "开始" on the onboarding page. No meeting starts here.
    public func showCaptions() { page = .captions }

    /// The user asked to change the language or to check the packs.
    public func showOnboarding() { page = .onboarding }

    /// The user asked for the face-to-face conversation. Remembers the page it was asked from;
    /// ignored while launching, in the history and when already open. The caller offers
    /// it only while no meeting runs.
    public func showFaceToFace() {
        switch page {
        case .onboarding, .captions:
            pageBeforeFaceToFace = page
            page = .faceToFace
        case .launching, .faceToFace, .history: return
        }
    }

    /// Back to the page `showFaceToFace` was called on; does nothing on any other page.
    public func closeFaceToFace() {
        if page == .faceToFace { page = pageBeforeFaceToFace }
    }

    /// The user asked for the saved records. Remembers the page it was asked from; ignored
    /// while launching, in a face-to-face conversation and when already open.
    public func showHistory() {
        switch page {
        case .onboarding, .captions:
            pageBeforeHistory = page
            page = .history
        case .launching, .faceToFace, .history: return
        }
    }

    /// Back to the page `showHistory` was called on; does nothing on any other page.
    public func closeHistory() {
        if page == .history { page = pageBeforeHistory }
    }
}
