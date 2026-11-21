import Foundation

public enum PackState: Sendable, Equatable { case unsupported, notInstalled, installed }

public enum ReadinessFailure: Error, Sendable, Equatable {
    case speechPackMissing, translationPackMissing, selfTestFailed(String)
}

public protocol ReadinessChecking: Sendable {
    func speechState(for locale: Locale) async -> PackState
    func translationState(from source: Locale.Language) async -> PackState
    func installSpeechPack(for locale: Locale) async throws
    /// 实际跑一次识别和翻译；通过才算可离线使用
    func selfTest(locale: Locale) async throws
    /// 开会前的轻量检查：两个状态都为 installed，否则抛对应的 ReadinessFailure
    func preflight(locale: Locale) async throws
}
