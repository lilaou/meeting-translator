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
    }

    public private(set) var page: Page = .launching

    @ObservationIgnored private let readiness: any ReadinessChecking
    @ObservationIgnored private var hasLaunched = false

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
}
