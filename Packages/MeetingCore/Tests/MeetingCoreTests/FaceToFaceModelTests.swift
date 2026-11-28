import Foundation
import Testing
@testable import MeetingCore

/// Builds the visits of a `FaceToFaceModel` and records what the model asked for.
@MainActor private final class VisitRecorder {
    let engine = ManualASREngine()
    let translator: ConversationTranslator
    let audio: ProbeAudioSource
    private let checking: (ConversationSide) -> ScriptedPacks
    private(set) var made: [ConversationSide] = []
    private(set) var saved: [String] = []

    init(audio: ProbeAudioSource = ProbeAudioSource(),
         translator: ConversationTranslator = ConversationTranslator(),
         checking: @escaping (ConversationSide) -> ScriptedPacks = { ScriptedPacks(partner: $0) }) {
        self.audio = audio
        self.translator = translator
        self.checking = checking
    }

    func model(stored: String? = nil) -> FaceToFaceModel {
        FaceToFaceModel(
            storedPartner: stored,
            save: { self.saved.append($0) },
            makeVisit: { partner in
                self.made.append(partner)
                return ConversationVisit(
                    partner: partner,
                    session: makeConversation(engine: self.engine, audio: self.audio,
                                              translator: self.translator),
                    packs: ConversationPacks(checking: self.checking(partner), partner: partner))
            })
    }

    /// One whole turn by the Chinese side of `session`.
    func speak(_ text: String, in session: ConversationSession) async {
        await session.tap(.chinese)
        engine.send(.finalized(text: text, range: 0...1))
        await session.tap(.chinese)
        await waitUntil { session.phase == .idle }
    }
}

/// A regression hangs until the suite's time limit.
@Suite(.timeLimit(.minutes(1)))
struct FaceToFaceModelTests {
    @MainActor @Test(arguments: [
        (nil, ConversationSide.korean), ("japanese", .japanese), ("chinese", .korean),
    ] as [(String?, ConversationSide)])
    func initMakesOneVisitForTheStoredPartnerAndSavesNothing(stored: String?,
                                                             partner: ConversationSide) {
        let recorder = VisitRecorder()
        let model = recorder.model(stored: stored)
        #expect(recorder.made == [partner])
        #expect(model.visit.partner == partner)
        #expect(model.visit.packs.partner == partner)
        #expect(model.canChoose)
        #expect(recorder.saved.isEmpty)
    }

    @MainActor @Test func choosingAnotherLanguageStartsANewVisitAndClearsTheOldOne() async {
        let recorder = VisitRecorder()
        let model = recorder.model()
        let old = model.visit.session
        await recorder.speak("你好", in: old)
        #expect(old.utterances.count == 1)
        model.choose(.english)
        #expect(recorder.made == [.korean, .english])
        #expect(recorder.saved == ["english"])
        #expect(model.visit.partner == .english)
        #expect(model.visit.session !== old)
        await waitUntil { old.utterances.isEmpty }
    }

    @MainActor @Test(arguments: [ConversationSide.korean, .chinese])
    func choosingTheCurrentLanguageOrChineseChangesNothing(choice: ConversationSide) {
        let recorder = VisitRecorder()
        let model = recorder.model()
        let session = model.visit.session
        model.choose(choice)
        #expect(recorder.made == [.korean])
        #expect(recorder.saved.isEmpty)
        #expect(model.visit.session === session)
    }

    @MainActor @Test func choosingIsRefusedUntilTheTurnIsOver() async {
        let startGate = Gate(), translationGate = Gate()
        let audio = ProbeAudioSource(startGate: startGate)
        let translator = ConversationTranslator(gate: translationGate)
        let recorder = VisitRecorder(audio: audio, translator: translator)
        let model = recorder.model()
        let session = model.visit.session
        func expectRefused(_ phase: ConversationSession.Phase) {
            #expect(session.phase == phase)
            #expect(!model.canChoose)
            model.choose(.japanese)
            #expect(recorder.made == [.korean])
            #expect(recorder.saved.isEmpty)
            #expect(model.visit.session === session)
            #expect(session.phase == phase)
        }

        let start = Task { await session.tap(.chinese) }
        await audio.entered.wait()
        expectRefused(.starting(.chinese))
        startGate.open()
        await start.value
        recorder.engine.send(.finalized(text: "你好", range: 0...1))
        await waitUntil { session.liveText == "你好" }
        expectRefused(.listening(.chinese))
        await session.tap(.chinese)
        await translator.requested.wait()
        expectRefused(.finishing(.chinese))
        translationGate.open()
        await waitUntil { session.phase == .idle }
        #expect(session.utterances.map(\.translation) == ["译:你好"])
        #expect(model.canChoose)
    }

    @MainActor @Test(arguments: [true, false])
    func choosingCancelsTheOldPacksInstall(installHonorsCancellation: Bool) async {
        let installGate = Gate()
        var scripts: [ConversationSide: ScriptedPacks] = [:]
        let recorder = VisitRecorder(checking: { partner in
            let script = partner == .korean
                ? ScriptedPacks.empty(installGate: installGate,
                                      honorsCancellation: installHonorsCancellation)
                : ScriptedPacks.empty(partner: partner)
            scripts[partner] = script
            return script
        })
        let model = recorder.model()
        let old = model.visit.packs
        await old.refresh()
        let download = Task { await old.download() }
        await scripts[.korean]?.installEntered.wait()

        model.choose(.japanese)
        let new = model.visit.packs
        #expect(old.step == .missing(allPacks))
        await new.refresh()
        #expect(new.step == .missing(packList(.japanese)))
        // A cancelled install ends by itself; one that ignores cancellation ends when released.
        if !installHonorsCancellation {
            #expect(old.isBusy)
            installGate.open()
        }
        await download.value
        #expect(!old.isBusy)
        #expect(old.step == .missing(allPacks))
        #expect(scripts[.korean]?.installed == ["zh-CN"]) // the second install never started
        #expect(new.step == .missing(packList(.japanese)))
        #expect(!new.isBusy)
        #expect(scripts[.japanese]?.installed == [])
    }

    @MainActor @Test func closeEndsTheCurrentVisitWithoutWaiting() async {
        let recorder = VisitRecorder()
        let model = recorder.model()
        let session = model.visit.session
        await session.tap(.chinese)
        model.close()
        #expect(session.phase == .listening(.chinese)) // `close` returned before the leave ran
        await waitUntil { session.phase == .idle }
        #expect(model.visit.session === session)
        #expect(recorder.made == [.korean])
        #expect(recorder.saved.isEmpty)
    }
}
