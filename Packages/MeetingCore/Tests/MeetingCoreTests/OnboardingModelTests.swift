import Foundation
import Testing
@testable import MeetingCore

private let english = Locale(identifier: "en-US")

@MainActor
private func model(_ readiness: ScriptedReadiness) -> OnboardingModel {
    OnboardingModel(readiness: readiness, locale: english)
}

@MainActor
private func failure(_ step: OnboardingModel.Step) -> String? {
    if case .failed(let message) = step { return message }
    return nil
}

// MARK: - refresh

@MainActor
@Test(arguments: [PackState.installed, .notInstalled, .unsupported],
      [PackState.installed, .notInstalled, .unsupported])
func refreshMapsEveryCombinationOfPackStates(speech: PackState, translation: PackState) async {
    let readiness = ScriptedReadiness(speech: speech, translation: translation)
    let onboarding = model(readiness)
    #expect(onboarding.step == .checking)
    await onboarding.refresh()
    if speech == .unsupported || translation == .unsupported {
        #expect(failure(onboarding.step)?.isEmpty == false)
        #expect(readiness.count(.selfTest) == 0)
    } else if speech == .installed, translation == .installed {
        #expect(onboarding.step == .ready)
        #expect(readiness.count(.selfTest) == 1)
    } else {
        #expect(onboarding.step == .needsSetup(speech: speech, translation: translation))
        #expect(readiness.count(.selfTest) == 0)
    }
    #expect(readiness.count(.install) == 0)
    #expect(readiness.selfTestsBeforeInstalled == 0)
    #expect(!onboarding.isBusy)
}

@MainActor @Test func unsupportedLanguagesAreNamedReadably() async {
    let noSpeech = model(ScriptedReadiness(speech: .unsupported, translation: .unsupported))
    await noSpeech.refresh()
    #expect(noSpeech.step == .failed("系统不支持英语的离线语音识别"))

    let noTranslation = model(ScriptedReadiness(speech: .installed, translation: .unsupported))
    await noTranslation.refresh()
    #expect(noTranslation.step == .failed("系统不支持把英语离线翻译成中文"))
}

// MARK: - setup

@MainActor @Test func happyPathInstallsSpeechWaitsForTheViewThenSelfTests() async {
    let readiness = ScriptedReadiness(speech: .notInstalled, translation: .notInstalled,
                                      blocking: [.install, .selfTest])
    let onboarding = model(readiness)
    await onboarding.refresh()
    #expect(onboarding.step == .needsSetup(speech: .notInstalled, translation: .notInstalled))

    let setup = Task { await onboarding.startSetup() }
    await readiness.entered(.install)
    #expect(onboarding.step == .installingSpeech)
    readiness.release(.install)
    await setup.value
    #expect(onboarding.step == .awaitingTranslationDownload)
    #expect(readiness.count(.selfTest) == 0)
    #expect(!onboarding.isBusy)

    // The view downloads the translation pack and reports back.
    readiness.setTranslation(.installed)
    let finished = Task { await onboarding.translationDownloadFinished(error: nil) }
    await readiness.entered(.selfTest)
    #expect(onboarding.step == .selfTesting)
    readiness.release(.selfTest)
    await finished.value
    #expect(onboarding.step == .ready)
    #expect(readiness.count(.install) == 1)
    #expect(readiness.count(.selfTest) == 1)
    #expect(readiness.selfTestsBeforeInstalled == 0)
    #expect(readiness.maxInFlight == 1)
}

@MainActor @Test func translationAlreadyInstalledGoesStraightToTheSelfTest() async {
    let readiness = ScriptedReadiness(speech: .notInstalled, translation: .installed)
    let onboarding = model(readiness)
    await onboarding.refresh()
    await onboarding.startSetup()
    #expect(onboarding.step == .ready)
    #expect(readiness.count(.install) == 1)
    #expect(readiness.count(.selfTest) == 1)
    #expect(readiness.selfTestsBeforeInstalled == 0)
}

@MainActor @Test func speechAlreadyInstalledSkipsTheInstall() async {
    let readiness = ScriptedReadiness(speech: .installed, translation: .notInstalled)
    let onboarding = model(readiness)
    await onboarding.refresh()
    await onboarding.startSetup()
    #expect(onboarding.step == .awaitingTranslationDownload)
    #expect(readiness.count(.install) == 0)
    #expect(readiness.count(.selfTest) == 0)
}

@MainActor @Test func aSpeechInstallErrorFailsWithAReadableMessage() async {
    let readable = ScriptedReadiness(speech: .notInstalled, translation: .notInstalled,
                                     installError: ModelReadinessError.speechInstallFailed("disk full"))
    let first = model(readable)
    await first.refresh()
    await first.startSetup()
    #expect(first.step == .failed("语音识别模型安装失败：disk full"))
    #expect(readable.count(.selfTest) == 0)

    let other = ScriptedReadiness(speech: .notInstalled, translation: .notInstalled,
                                  installError: FakeError.asr)
    let second = model(other)
    await second.refresh()
    await second.startSetup()
    #expect(second.step == .failed("语音识别离线包安装失败：\(FakeError.asr.localizedDescription)"))
}

@MainActor @Test func speechStillMissingAfterTheInstallFails() async {
    let readiness = ScriptedReadiness(speech: .notInstalled, translation: .installed,
                                      speechAfterInstall: .notInstalled)
    let onboarding = model(readiness)
    await onboarding.refresh()
    await onboarding.startSetup()
    #expect(onboarding.step == .failed("语音识别离线包仍未就绪，请重试"))
    #expect(readiness.count(.selfTest) == 0)
}

// MARK: - translation download reported by the view

@MainActor
private func awaitingDownload(_ readiness: ScriptedReadiness) async -> OnboardingModel {
    let onboarding = model(readiness)
    await onboarding.refresh()
    await onboarding.startSetup()
    #expect(onboarding.step == .awaitingTranslationDownload)
    return onboarding
}

@MainActor @Test func aDownloadErrorFromTheViewFails() async {
    let readiness = ScriptedReadiness(speech: .installed, translation: .notInstalled)
    let onboarding = await awaitingDownload(readiness)
    await onboarding.translationDownloadFinished(error: FakeError.translation)
    #expect(onboarding.step == .failed("翻译离线包下载失败：\(FakeError.translation.localizedDescription)"))
    #expect(readiness.count(.selfTest) == 0)
}

@MainActor @Test func aDownloadReportedDoneButStillNotInstalledFails() async {
    let readiness = ScriptedReadiness(speech: .installed, translation: .notInstalled)
    let onboarding = await awaitingDownload(readiness)
    await onboarding.translationDownloadFinished(error: nil)
    #expect(onboarding.step == .failed("翻译离线包仍未就绪，请重试"))
    #expect(readiness.count(.selfTest) == 0)
}

@MainActor @Test func aCancelledDownloadIsNotAFailure() async {
    let readiness = ScriptedReadiness(speech: .installed, translation: .notInstalled)
    let onboarding = await awaitingDownload(readiness)
    await onboarding.translationDownloadFinished(error: CancellationError())
    #expect(onboarding.step == .needsSetup(speech: .installed, translation: .notInstalled))
    #expect(readiness.count(.selfTest) == 0)
}

// MARK: - self-test failure and retry

@MainActor @Test func aSelfTestFailureShowsTheReasonAndRetrySucceeds() async {
    let readiness = ScriptedReadiness(speech: .installed, translation: .installed,
                                      selfTestErrors: [ReadinessFailure.selfTestFailed("译文为空。")])
    let onboarding = model(readiness)
    await onboarding.refresh()
    #expect(onboarding.step == .failed("离线自检未通过：译文为空。"))
    await onboarding.retry()
    #expect(onboarding.step == .ready)
    #expect(readiness.count(.selfTest) == 2)
}

@MainActor @Test func anUnknownSelfTestErrorShowsItsDescription() async {
    let readiness = ScriptedReadiness(speech: .installed, translation: .installed,
                                      selfTestErrors: [FakeError.translation])
    let onboarding = model(readiness)
    await onboarding.refresh()
    #expect(onboarding.step == .failed("离线自检未通过：\(FakeError.translation.localizedDescription)"))
}

@MainActor @Test func aSelfTestThatThrowsCancellationOnItsOwnIsNotAFailure() async {
    let readiness = ScriptedReadiness(speech: .installed, translation: .installed,
                                      selfTestErrors: [CancellationError()])
    let onboarding = model(readiness)
    await onboarding.refresh()
    #expect(onboarding.step == .needsSetup(speech: .installed, translation: .installed))
}

// MARK: - shared messages

@MainActor @Test func sessionHintsKeepTheirWordingAfterMovingToUserMessages() {
    #expect(SessionCoordinator.hint(for: ReadinessFailure.speechPackMissing) == "语音识别离线包未安装，请先下载")
    #expect(SessionCoordinator.hint(for: ReadinessFailure.translationPackMissing) == "翻译离线包未安装，请先下载")
    #expect(SessionCoordinator.hint(for: ReadinessFailure.selfTestFailed("x")) == "离线自检未通过：x")
    #expect(SessionCoordinator.hint(for: AudioCaptureError.permissionDenied) == "没有麦克风权限，请在系统设置中允许")
    #expect(SessionCoordinator.hint(for: AudioCaptureError.engineStartFailed("busy")) == "无法启动录音：busy")
    #expect(SessionCoordinator.hint(for: FakeError.asr) == "出现错误：\(FakeError.asr.localizedDescription)")
}
