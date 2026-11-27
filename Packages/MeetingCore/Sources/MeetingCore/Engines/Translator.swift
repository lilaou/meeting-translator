import Foundation

public protocol Translator: Sendable {
    func canTranslate(from source: Locale.Language) async -> Bool
    func translate(_ text: String, from source: Locale.Language, context: [String]) async throws -> String
    /// 返回数组与输入等长、同序。默认实现逐句调用 translate。
    func translateBatch(_ texts: [String], from source: Locale.Language, context: [String]) async throws -> [String]
}

extension Translator {
    public func translateBatch(_ texts: [String], from source: Locale.Language, context: [String]) async throws -> [String] {
        var out: [String] = []
        out.reserveCapacity(texts.count)
        for text in texts {
            out.append(try await translate(text, from: source, context: context))
        }
        return out
    }
}

/// The meeting captions' fixed target language, Simplified Chinese: the single definition used
/// by `AppleTranslator.init()`, the pack-state query behind `translationState(from:)` and
/// `ConversationSide.chinese`, and named to the onboarding view as
/// `OnboardingModel.translationTarget`.
enum TranslationTarget {
    static let language = Locale.Language(identifier: "zh-Hans")
}
