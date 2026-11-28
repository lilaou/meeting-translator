import Foundation
import Synchronization
import Testing
@testable import MeetingCore

private func locales(_ identifiers: String...) -> [Locale] {
    identifiers.map { Locale(identifier: $0) }
}

private func state(supported: [Locale] = locales("zh-CN", "ko-KR"), installed: [Locale],
                   reserved: [Locale]) -> PackState {
    reservedSpeechState(for: Locale(identifier: "zh-CN"), supported: supported,
                        installed: installed, reserved: reserved)
}

@Test func anInstalledAndReservedModelIsInstalled() {
    #expect(state(installed: locales("zh-CN"), reserved: locales("zh-CN")) == .installed)
}

@Test func aModelInstalledSystemWideButNotReservedIsNotInstalled() {
    #expect(state(installed: locales("zh-CN"), reserved: []) == .notInstalled)
    #expect(state(installed: locales("zh-CN"), reserved: locales("ko-KR", "yue-CN")) == .notInstalled)
}

@Test func aReservedButNotInstalledModelIsNotInstalled() {
    #expect(state(installed: [], reserved: locales("zh-CN")) == .notInstalled)
}

@Test func aLocaleWithoutASpeechModelIsUnsupported() {
    #expect(state(supported: locales("ko-KR"), installed: [], reserved: []) == .unsupported)
}

/// The system may list the same locale with its script in any of the three lists.
@Test func aScriptInAnyListStillMatches() {
    let plain = locales("zh-CN"), scripted = locales("zh-Hans-CN")
    #expect(state(supported: scripted, installed: plain, reserved: plain) == .installed)
    #expect(state(supported: plain, installed: scripted, reserved: plain) == .installed)
    #expect(state(supported: plain, installed: plain, reserved: scripted) == .installed)
}

/// Both models are on the system, none is reserved; installing only reserves.
private final class UnreservedPacks: ConversationPackChecking, Sendable {
    private let reserved = Mutex<[Locale]>([])
    var reservedIdentifiers: [String] { reserved.withLock { $0.map(\.identifier) } }

    func conversationSpeechState(for locale: Locale) async -> PackState {
        let system = locales("zh-CN", "ko-KR")
        return reservedSpeechState(for: locale, supported: system, installed: system,
                                   reserved: reserved.withLock { $0 })
    }
    func translationState(from: Locale.Language, to: Locale.Language) async -> PackState { .installed }
    func installSpeechPack(for locale: Locale) async throws { reserved.withLock { $0.append(locale) } }
}

@MainActor @Test func downloadingReservesTheInstalledModelsAndEndsReady() async {
    let checking = UnreservedPacks()
    let packs = ConversationPacks(checking: checking, partner: .korean)
    await packs.refresh()
    #expect(packs.step == .missing([.speech(.chinese), .speech(.korean)]))
    await packs.download()
    #expect(packs.step == .ready)
    #expect(checking.reservedIdentifiers == ["zh-CN", "ko-KR"])
}
