import Foundation

/// 把识别引擎吐出的定稿片段拼成完整句子。纯逻辑，无系统依赖。
/// 停顿时限不在这里处理：由 SessionCoordinator 计时并调用 `flush()`。
public struct SentenceAssembler: Sendable {
    private let maxCharacters: Int
    private var buffer: [Character] = []
    private var bufferStart: TimeInterval = 0
    private var bufferEnd: TimeInterval = 0

    private static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "vs", "etc", "e.g", "i.e"
    ]
    private static let alwaysTerminators: Set<Character> = ["。", "？", "！"]
    private static let conditionalTerminators: Set<Character> = [".", "?", "!"]

    public init(maxCharacters: Int) {
        self.maxCharacters = max(1, maxCharacters)
    }

    public var hasPending: Bool {
        buffer.contains { !$0.isWhitespace }
    }

    /// 接收一个定稿片段，返回因此切出的完整句子（可能 0 到多句）
    public mutating func ingest(text: String, range: ClosedRange<TimeInterval>) -> [Sentence] {
        let piece = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !piece.isEmpty else { return [] }
        if buffer.isEmpty {
            bufferStart = range.lowerBound
        } else if let last = buffer.last, let first = piece.first,
                  !(Self.joinsWithoutSpace(last) && Self.joinsWithoutSpace(first)) {
            buffer.append(" ")
        }
        buffer.append(contentsOf: piece)
        bufferEnd = range.upperBound

        var out: [Sentence] = []
        while let cut = nextCut() {
            let sentence = String(buffer[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
            var rest = Array(buffer[cut...])
            while let first = rest.first, first.isWhitespace { rest.removeFirst() }
            if !sentence.isEmpty {
                out.append(Sentence(text: sentence, start: bufferStart, end: range.upperBound))
            }
            buffer = rest
            // 剩下的尾巴来自当前片段。
            bufferStart = range.lowerBound
        }
        return out
    }

    /// 把缓冲里剩下的内容作为一句切出；缓冲为空返回 nil
    public mutating func flush() -> Sentence? {
        let text = String(buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        let sentence = text.isEmpty ? nil : Sentence(text: text, start: bufferStart, end: bufferEnd)
        buffer = []
        return sentence
    }

    // MARK: - Splitting

    /// 下一个切点（不含该下标）。优先句末符，其次超长切分。
    private func nextCut() -> Int? {
        for i in buffer.indices where isTerminator(at: i) {
            return i + 1
        }
        guard buffer.count > maxCharacters else { return nil }
        // 句子长度不超过上限：切点（空白的下标）最大为 maxCharacters。
        if let space = (1...maxCharacters).last(where: { buffer[$0].isWhitespace }) {
            return space
        }
        return maxCharacters
    }

    private func isTerminator(at i: Int) -> Bool {
        let c = buffer[i]
        if Self.alwaysTerminators.contains(c) { return true }
        guard Self.conditionalTerminators.contains(c) else { return false }
        if i + 1 < buffer.count, !buffer[i + 1].isWhitespace { return false }
        guard c == "." else { return true }
        if i > 0, i + 1 < buffer.count, buffer[i - 1].isNumber, buffer[i + 1].isNumber { return false }
        return !isAbbreviation(endingBefore: i)
    }

    /// `.` 之前的词是缩写（缩写表、单字母、或点分单字母如 U.S / a.m）。
    private func isAbbreviation(endingBefore dot: Int) -> Bool {
        var start = dot
        while start > 0, !buffer[start - 1].isWhitespace { start -= 1 }
        let word = String(buffer[start..<dot]).trimmingCharacters(in: .punctuationCharacters.subtracting(["."]))
        guard !word.isEmpty else { return false }
        if Self.abbreviations.contains(word.lowercased()) { return true }
        return word.wholeMatch(of: /([A-Za-z]\.)*[A-Za-z]/) != nil
    }

    /// Han, kana, CJK punctuation and full-width forms: written without spaces between words.
    /// Hangul is deliberately not included, because Korean separates words with spaces.
    private static func joinsWithoutSpace(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value else { return false }
        return (0x3000...0x9FFF).contains(v) || (0xFF00...0xFFEF).contains(v)
    }
}
