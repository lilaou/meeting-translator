import Foundation
import MeetingCore
import SwiftData

/// Everything the app shares: one container (SwiftUI and `TranscriptStore` use the same
/// `mainContext`), one coordinator, one language selection (which holds the onboarding model
/// of the chosen language) and the route between the pages. All of them use one readiness, as
/// does the face-to-face setup.
@MainActor
struct AppEnvironment {
    let container: ModelContainer
    let coordinator: SessionCoordinator
    let selection: LanguageSelection
    /// Lives as long as the app, so the launch preflight runs once.
    let route: AppRoute
    let faceToFace: FaceToFaceSetup
}

/// What the face-to-face screen is made of. The translators (one per direction) and the shared
/// engine and readiness live as long as the app; `makeVisit` builds the rest for one visit.
@MainActor
struct FaceToFaceSetup {
    let engine: AppleSpeechEngine
    let readiness: ModelReadiness
    private let fromChinese = AppleTranslator(target: ConversationSide.chinese.other.translationLanguage)
    private let fromKorean = AppleTranslator(target: ConversationSide.korean.other.translationLanguage)

    init(engine: AppleSpeechEngine, readiness: ModelReadiness) {
        self.engine = engine
        self.readiness = readiness
    }

    /// A new conversation and a new pack check. The `AudioCapture` is the conversation's own,
    /// not the meeting's, and new per visit: a stop still pending from a closed visit then
    /// cannot end the recording of a later one.
    func makeVisit() -> FaceToFaceVisit {
        let session = ConversationSession(
            engine: engine, audio: AudioCapture(),
            translator: { [fromChinese, fromKorean] side in
                switch side {
                case .chinese: fromChinese
                case .korean: fromKorean
                }
            },
            timing: ConversationTiming())
        return FaceToFaceVisit(session: session, packs: ConversationPacks(checking: readiness))
    }
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
                                       selection: selection,
                                       route: AppRoute(readiness: readiness),
                                       faceToFace: FaceToFaceSetup(engine: engine,
                                                                   readiness: readiness)))
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
