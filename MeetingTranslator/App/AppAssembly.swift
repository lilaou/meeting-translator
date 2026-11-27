import Foundation
import MeetingCore
import SwiftData

/// Everything the app shares: one container (SwiftUI and `TranscriptStore` use the same
/// `mainContext`), one coordinator, one language selection (which holds the onboarding model
/// of the chosen language). All of them use one readiness.
@MainActor
struct AppEnvironment {
    let container: ModelContainer
    let coordinator: SessionCoordinator
    let selection: LanguageSelection
}

/// Wires the real engines together. Returns a result instead of crashing when the on-disk
/// store cannot be created.
@MainActor
enum AppAssembly {
    /// The `UserDefaults` key of the chosen language; only its identifier is stored.
    private static let languageKey = "sourceLanguage"

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
        let selection = LanguageSelection(
            readiness: readiness,
            storedIdentifier: UserDefaults.standard.string(forKey: languageKey),
            save: { UserDefaults.standard.set($0, forKey: languageKey) },
            meetingState: { coordinator.state })
        return .success(AppEnvironment(container: container, coordinator: coordinator,
                                       selection: selection))
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
