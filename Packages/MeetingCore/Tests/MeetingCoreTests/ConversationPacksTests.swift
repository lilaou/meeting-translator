import Foundation
import Testing
@testable import MeetingCore

@MainActor @Test func allInstalledIsReady() async {
    let checking = ScriptedPacks()
    let packs = ConversationPacks(checking: checking)
    #expect(packs.step == .checking)
    await packs.refresh()
    #expect(packs.step == .ready)
    #expect(checking.queries == 4)
    #expect(checking.installed.isEmpty)
    #expect(!packs.isBusy)
}

@MainActor @Test func missingPacksAreListedInOrder() async {
    let all = ConversationPacks(checking: ScriptedPacks.empty())
    await all.refresh()
    #expect(all.step == .missing(allPacks))

    let some = ConversationPacks(checking: ScriptedPacks([
        .translation(from: .korean): .notInstalled, .speech(.korean): .notInstalled,
    ]))
    await some.refresh()
    #expect(some.step == .missing([.speech(.korean), .translation(from: .korean)]))
}

@MainActor @Test func downloadInstallsSpeechThenAsksForEachTranslationPair() async {
    let checking = ScriptedPacks.empty()
    let packs = ConversationPacks(checking: checking)
    await packs.refresh()
    await packs.download()
    #expect(checking.installed == ["zh-CN", "ko-KR"])
    #expect(packs.step == .awaitingTranslationDownload(from: .chinese))
    #expect(!packs.isBusy)

    checking.set(.translation(from: .chinese), .installed)
    await packs.translationDownloadFinished(error: nil)
    #expect(packs.step == .awaitingTranslationDownload(from: .korean))

    checking.set(.translation(from: .korean), .installed)
    await packs.translationDownloadFinished(error: nil)
    #expect(packs.step == .ready)
}

@MainActor @Test func theInstallingStepNamesThePack() async {
    let gate = Gate()
    let checking = ScriptedPacks([.speech(.korean): .notInstalled], installGate: gate)
    let packs = ConversationPacks(checking: checking)
    await packs.refresh()
    let download = Task { await packs.download() }
    await checking.installEntered.wait()
    #expect(packs.step == .installing(.speech(.korean)))
    #expect(packs.isBusy)
    await packs.refresh() // a live job: ignored
    #expect(packs.step == .installing(.speech(.korean)))
    gate.open()
    await download.value
    #expect(packs.step == .ready)
    #expect(checking.installed == ["ko-KR"])
}

@MainActor @Test func anUnsupportedPackFails() async {
    let speech = ConversationPacks(checking: ScriptedPacks([.speech(.korean): .unsupported]))
    await speech.refresh()
    #expect(speech.step == .failed("系统不支持韩语的离线语音识别"))

    let translation = ConversationPacks(checking: ScriptedPacks([
        .speech(.chinese): .notInstalled, .translation(from: .chinese): .unsupported,
    ]))
    await translation.refresh()
    #expect(translation.step == .failed("系统不支持把中文离线翻译成韩语"))

    let reverse = ConversationPacks(checking: ScriptedPacks([.translation(from: .korean): .unsupported]))
    await reverse.refresh()
    #expect(reverse.step == .failed("系统不支持把韩语离线翻译成中文"))
}

@MainActor @Test func anInstallErrorFailsWithItsMessage() async {
    let error = ModelReadinessError.speechInstallFailed("名额已满")
    let checking = ScriptedPacks([.speech(.chinese): .notInstalled, .speech(.korean): .notInstalled],
                                 installError: error)
    let packs = ConversationPacks(checking: checking)
    await packs.refresh()
    await packs.download()
    #expect(packs.step == .failed("语音识别模型安装失败：名额已满"))
    #expect(checking.installed == ["zh-CN"]) // stops at the first failure

    await packs.refresh() // starts over
    #expect(packs.step == .missing([.speech(.chinese), .speech(.korean)]))
}

@MainActor @Test func aCancelledTranslationDownloadReturnsToMissing() async {
    let checking = ScriptedPacks.empty()
    let packs = ConversationPacks(checking: checking)
    await packs.refresh()
    await packs.download()
    let still = ConversationPacks.Step.missing([.translation(from: .chinese), .translation(from: .korean)])

    await packs.translationDownloadFinished(error: CancellationError())
    #expect(packs.step == still)

    await packs.download()
    #expect(packs.step == .awaitingTranslationDownload(from: .chinese))
    packs.cancel()
    #expect(packs.step == still)
    #expect(checking.installed == ["zh-CN", "ko-KR"]) // nothing installed twice
}

@MainActor @Test func reportsOutsideAwaitingAreIgnored() async {
    let checking = ScriptedPacks.empty()
    let packs = ConversationPacks(checking: checking)
    await packs.download()
    await packs.translationDownloadFinished(error: nil)
    packs.cancel()
    #expect(packs.step == .checking)
    #expect(checking.queries == 0)

    await packs.refresh()
    await packs.translationDownloadFinished(error: FakeError.translation)
    packs.cancel()
    #expect(packs.step == .missing(allPacks))

    await packs.download()
    let queries = checking.queries
    await packs.refresh() // the view's download is in flight: ignored
    await packs.download()
    #expect(packs.step == .awaitingTranslationDownload(from: .chinese))
    #expect(checking.queries == queries)

    packs.cancel()
    checking.set(.translation(from: .chinese), .installed)
    await packs.translationDownloadFinished(error: nil) // late: dropped
    #expect(packs.step == .missing([.translation(from: .chinese), .translation(from: .korean)]))
    #expect(checking.queries == queries)
}

@MainActor @Test func aDownloadThatDidNotInstallThePackFails() async {
    let translation = ConversationPacks(checking: ScriptedPacks([.translation(from: .korean): .notInstalled]))
    await translation.refresh()
    await translation.download()
    #expect(translation.step == .awaitingTranslationDownload(from: .korean))
    await translation.translationDownloadFinished(error: nil)
    #expect(translation.step == .failed("翻译离线包仍未就绪，请重试"))

    let speech = ConversationPacks(checking: ScriptedPacks([.speech(.chinese): .notInstalled],
                                                           installDoesNothing: true))
    await speech.refresh()
    await speech.download()
    #expect(speech.step == .failed("语音识别离线包仍未就绪，请重试"))
}

@MainActor @Test func aFailedTranslationDownloadFailsWithItsReason() async {
    let packs = ConversationPacks(checking: ScriptedPacks([.translation(from: .chinese): .notInstalled]))
    await packs.refresh()
    await packs.download()
    await packs.translationDownloadFinished(error: FakeError.translation)
    #expect(packs.step == .failed(UserMessages.translationDownloadFailed(FakeError.translation)))
}
