import Foundation
import Testing
@testable import MeetingCore

private let bothSpeech: [ConversationPack: PackState] = [
    .speech(.chinese): .notInstalled, .speech(.korean): .notInstalled,
]
private let stillBoth = ConversationPacks.Step.missing([.speech(.chinese), .speech(.korean)])

@MainActor @Test func cancelDuringAnInstallReturnsToMissing() async {
    let checking = ScriptedPacks(bothSpeech, installGate: Gate())
    let packs = ConversationPacks(checking: checking, partner: .korean)
    await packs.refresh()
    let download = Task { await packs.download() }
    await checking.installEntered.wait()
    packs.cancel()
    #expect(packs.step == stillBoth)
    packs.cancel() // safe
    await download.value
    #expect(packs.step == stillBoth)
    #expect(!packs.isBusy)
    #expect(checking.installed == ["zh-CN"]) // the second install never started
}

@MainActor @Test func cancellingTheTaskThatStartedTheDownloadCancelsIt() async {
    let checking = ScriptedPacks(bothSpeech, installGate: Gate())
    weak var released: ConversationPacks?
    do {
        let packs = ConversationPacks(checking: checking, partner: .korean)
        released = packs
        await packs.refresh()
        let caller = Task { await packs.download() }
        await checking.installEntered.wait()
        caller.cancel()
        await caller.value
        #expect(packs.step == stillBoth)
        #expect(!packs.isBusy)
    }
    #expect(released == nil)
}

@MainActor @Test func aNewDownloadWaitsForAnInstallThatIgnoresCancellation() async {
    let gate = Gate()
    let checking = ScriptedPacks(bothSpeech, installGate: gate, honorsCancellation: false)
    let packs = ConversationPacks(checking: checking, partner: .korean)
    await packs.refresh()
    let first = Task { await packs.download() }
    await checking.installEntered.wait()
    packs.cancel()
    #expect(packs.isBusy) // the stuck install is still draining
    let second = Task { await packs.download() }
    await waitUntil { packs.callsWaitingForCancelledJob == 1 || packs.step != stillBoth }
    #expect(packs.callsWaitingForCancelledJob == 1)
    #expect(packs.step == stillBoth)
    #expect(checking.installed == ["zh-CN"])
    gate.open()
    await first.value
    await second.value
    #expect(checking.maxInstallsInFlight == 1)
    #expect(packs.step == .ready)
    #expect(!packs.isBusy)
}
