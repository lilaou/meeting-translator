import Foundation
import MeetingCore
import SwiftData

/// Everything the app shares: one container (SwiftUI and `TranscriptStore` use the same
/// `mainContext`), one coordinator, one onboarding model.
@MainActor
struct AppEnvironment {
    let container: ModelContainer
    let coordinator: SessionCoordinator
    let onboarding: OnboardingModel
}

/// Wires the real engines together. Returns a result instead of crashing when the on-disk
/// store cannot be created.
@MainActor
enum AppAssembly {
    static let sourceLocale = Locale(identifier: "en-US")

    static func make() -> Result<AppEnvironment, AssemblyError> {
        let container: ModelContainer
        do {
            container = try MeetingStorage.makeContainer(at: try storeURL())
        } catch {
            return .failure(AssemblyError(reason: String(describing: error)))
        }
        let engine = AppleSpeechEngine()
        let translator = AppleTranslator()
        let readiness = ModelReadiness(engine: engine, translator: translator)
        let coordinator = SessionCoordinator(
            engine: engine, translator: translator, audio: AudioCapture(),
            readiness: readiness, store: TranscriptStore(container: container),
            config: PipelineConfig())
        let onboarding = OnboardingModel(readiness: readiness, locale: sourceLocale)
        return .success(AppEnvironment(container: container, coordinator: coordinator,
                                       onboarding: onboarding))
    }

    private static func storeURL() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        return support.appending(path: "Meetings.store")
    }
}

struct AssemblyError: Error {
    let reason: String
}
