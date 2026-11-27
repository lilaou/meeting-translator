import Foundation
import Observation

/// The app's one choice of source language, and the onboarding model that belongs to it.
/// The meeting's locale, the translation direction and the language pair of the download all
/// come from `language`.
///
/// An `OnboardingModel` serves one locale, so changing the language cancels the old model and
/// makes a new one that has done nothing yet: the view that shows `onboarding` must give it
/// a new identity (so that its appear/disappear handlers and any download attempt belong to
/// the new instance), and its appearing then calls `refresh()`.
@MainActor @Observable public final class LanguageSelection {
    public private(set) var language: SourceLanguage
    /// The onboarding of `language`.
    public private(set) var onboarding: OnboardingModel

    @ObservationIgnored private let readiness: any ReadinessChecking
    @ObservationIgnored private let save: @MainActor (String) -> Void
    @ObservationIgnored private let meetingState: @MainActor () -> SessionCoordinator.State

    /// `storedIdentifier` is what `save` was last given (nil or an unlisted value selects
    /// the default, "en-US"). `meetingState` reports the coordinator's state.
    public init(readiness: any ReadinessChecking, storedIdentifier: String?,
                save: @escaping @MainActor (String) -> Void,
                meetingState: @escaping @MainActor () -> SessionCoordinator.State) {
        let language = SourceLanguage.stored(storedIdentifier)
        self.language = language
        self.onboarding = OnboardingModel(readiness: readiness, locale: language.locale)
        self.readiness = readiness
        self.save = save
        self.meetingState = meetingState
    }

    /// False while a meeting is being prepared, running or wrapping up, and while the
    /// onboarding has a job (also a cancelled one still ending) or a download in progress.
    public var canChange: Bool {
        switch meetingState() {
        case .preparing, .listening, .finishing: return false
        case .idle, .failed: break
        }
        guard !onboarding.isBusy else { return false }
        switch onboarding.step {
        case .installingSpeech, .awaitingTranslationDownload, .selfTesting: return false
        case .checking, .needsSetup, .ready, .failed: return true
        }
    }

    /// Switches to the supported language with this identifier and saves it. Does nothing
    /// when `canChange` is false, or for the current or an unlisted identifier.
    public func select(_ identifier: String) {
        guard canChange, identifier != language.identifier,
              let chosen = SourceLanguage.all.first(where: { $0.identifier == identifier })
        else { return }
        onboarding.cancel()
        language = chosen
        onboarding = OnboardingModel(readiness: readiness, locale: chosen.locale)
        save(chosen.identifier)
    }
}
