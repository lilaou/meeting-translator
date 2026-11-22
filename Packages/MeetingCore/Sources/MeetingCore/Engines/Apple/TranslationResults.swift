import Foundation

/// Errors of `AppleTranslator`. The queue and the UI show `localizedDescription`, so every
/// case carries a readable message. Plain Foundation, so it is not gated by the SDK.
public enum AppleTranslatorError: Error, Sendable, Equatable, LocalizedError {
    /// The translation pack from this language (BCP-47 identifier) to Simplified Chinese
    /// is not installed.
    case packNotInstalled(String)
    /// A translation came back empty or blank.
    case emptyResult
    /// The batch answers do not match the requests one to one.
    case mismatchedResults
    /// The translation session failed; carries the underlying description.
    case translationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .packNotInstalled(let identifier):
            "本机尚未安装从“\(identifier)”到简体中文的翻译语言包。"
        case .emptyResult:
            "翻译结果为空。"
        case .mismatchedResults:
            "翻译结果与原文对不上。"
        case .translationFailed(let reason):
            "翻译失败：\(reason)"
        }
    }

    /// Keeps an `AppleTranslatorError`; wraps any other error with its description.
    static func wrapping(_ error: any Error) -> AppleTranslatorError {
        (error as? AppleTranslatorError) ?? .translationFailed(error.localizedDescription)
    }
}

/// One answer of a batch translation: the request's client identifier and the target text.
struct TranslatedText: Sendable, Equatable {
    let identifier: String?
    let text: String
}

/// The batch requests use the input index as client identifier ("0", "1", ...). Puts the
/// answers back in input order by that identifier, whatever order they arrived in.
/// Throws for the whole batch when the answers are not exactly one per request (count,
/// missing, unknown or repeated identifier) or when any text is blank.
func orderedTranslations(_ answers: [TranslatedText], count: Int) throws(AppleTranslatorError) -> [String] {
    guard answers.count == count else { throw .mismatchedResults }
    var slots = [String?](repeating: nil, count: count)
    for answer in answers {
        guard let identifier = answer.identifier, let index = Int(identifier),
              slots.indices.contains(index), slots[index] == nil
        else { throw .mismatchedResults }
        guard !answer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw .emptyResult
        }
        slots[index] = answer.text
    }
    // Every slot is filled: `count` answers, each in a different slot.
    return slots.compactMap { $0 }
}
