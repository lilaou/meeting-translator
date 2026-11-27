import MeetingCore
import SwiftUI

/// The onboarding page: the language choice above the onboarding of the chosen language.
///
/// `.id` gives each `OnboardingModel` a view of its own. Choosing a language replaces the
/// model, so the old `OnboardingView` disappears (its `onDisappear` cancels the OLD model,
/// which it holds) and a new one appears: its `.task` refreshes the new model, and the
/// download state in `TranslationDownloadModifier` starts empty. Without the new identity
/// the `.task` would not run again and an attempt could outlive its language. The picker
/// stays outside that identity. So does the "面对面" button: that screen checks its own four
/// packs, so it is offered whatever the state of these.
struct OnboardingPage: View {
    @Bindable var selection: LanguageSelection
    let onFaceToFace: () -> Void
    let onStart: () -> Void

    var body: some View {
        // `select` replaces both together, so one read of each is a consistent pair.
        let onboarding = selection.onboarding
        let direction = CaptionStrings.direction(from: selection.language.locale)
        VStack(spacing: 0) {
            Picker("会议语言", selection: $selection.selectedIdentifier) {
                ForEach(SourceLanguage.all) { Text($0.name).tag($0.identifier) }
            }
            .pickerStyle(.segmented)
            .disabled(!selection.canChange)
            .padding([.horizontal, .top])
            OnboardingView(onboarding: onboarding, direction: direction, onStart: onStart)
                .id(ObjectIdentifier(onboarding))
            Button("面对面", action: onFaceToFace)
                .buttonStyle(.bordered)
                .padding(.bottom)
        }
    }
}

extension LanguageSelection {
    /// For the picker's binding; `select` ignores a change that is not allowed.
    fileprivate var selectedIdentifier: String {
        get { language.identifier }
        set { select(newValue) }
    }
}
