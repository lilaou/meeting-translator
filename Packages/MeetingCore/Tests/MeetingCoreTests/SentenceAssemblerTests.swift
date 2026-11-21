import Testing
@testable import MeetingCore

@Suite struct SentenceAssemblerTests {
    @Test func piecesJoinUntilTerminator() {
        var a = SentenceAssembler(maxCharacters: 200)
        #expect(a.ingest(text: "We'll start the pilot", range: 0...2).isEmpty)
        let out = a.ingest(text: "run next Monday.", range: 2...4)
        #expect(out == [Sentence(text: "We'll start the pilot run next Monday.", start: 0, end: 4)])
        #expect(!a.hasPending)
    }

    @Test func onePieceWithTwoSentencesYieldsTwo() {
        var a = SentenceAssembler(maxCharacters: 200)
        let out = a.ingest(text: "Okay. Let's begin.", range: 1...3)
        #expect(out == [Sentence(text: "Okay.", start: 1, end: 3),
                        Sentence(text: "Let's begin.", start: 1, end: 3)])
        #expect(!a.hasPending)
    }

    @Test func decimalPointDoesNotSplit() {
        var a = SentenceAssembler(maxCharacters: 200)
        let out = a.ingest(text: "Yield rose to 3.5 percent.", range: 0...2)
        #expect(out == [Sentence(text: "Yield rose to 3.5 percent.", start: 0, end: 2)])
    }

    @Test func abbreviationDoesNotSplit() {
        var a = SentenceAssembler(maxCharacters: 200)
        #expect(a.ingest(text: "The U.S. market is next.", range: 0...2).map(\.text) == ["The U.S. market is next."])
        #expect(a.ingest(text: "Dr. Lee agrees.", range: 2...4).map(\.text) == ["Dr. Lee agrees."])
        #expect(a.ingest(text: "Meet at 9 a.m. sharp, e.g. here, vs. them, plus item A. done.", range: 4...6).map(\.text)
                == ["Meet at 9 a.m. sharp, e.g. here, vs. them, plus item A. done."])
    }

    @Test func sentenceFinalDottedAbbreviationStaysPendingUntilFlush() {
        // 决定：点分缩写在句末也不切，留在缓冲里，由后续片段或 flush() 带出，不会丢。
        var a = SentenceAssembler(maxCharacters: 200)
        #expect(a.ingest(text: "We moved to the U.S.", range: 0...2).isEmpty)
        #expect(a.hasPending)
        #expect(a.flush() == Sentence(text: "We moved to the U.S.", start: 0, end: 2))
        #expect(a.flush() == nil)
        // 后续片段到来时仍能正常收尾。
        #expect(a.ingest(text: "We moved to the U.S.", range: 0...2).isEmpty)
        #expect(a.ingest(text: "last year.", range: 2...3).map(\.text) == ["We moved to the U.S. last year."])
    }

    @Test func whitespaceOnlyPieceIsIgnored() {
        var a = SentenceAssembler(maxCharacters: 200)
        #expect(a.ingest(text: "   ", range: 0...1).isEmpty)
        #expect(!a.hasPending)
        #expect(a.ingest(text: "\n \t", range: 1...2).isEmpty)
        #expect(a.flush() == nil)
    }

    @Test func overLimitCutsAtLastSpace() {
        var a = SentenceAssembler(maxCharacters: 20)
        let original = "we should consider moving the launch to the following quarter instead"
        var sentences = a.ingest(text: original, range: 0...5)
        if let tail = a.flush() { sentences.append(tail) }
        #expect(sentences.count > 1)
        #expect(sentences.allSatisfy { $0.text.count <= 20 })
        #expect(sentences.map(\.text).joined(separator: " ") == original)
    }

    @Test func overLimitWithoutSpacesHardCuts() {
        var a = SentenceAssembler(maxCharacters: 20)
        let original = String(repeating: "a", count: 40)
        var sentences = a.ingest(text: original, range: 0...2)
        if let tail = a.flush() { sentences.append(tail) }
        #expect(sentences.map(\.text) == [String(repeating: "a", count: 20), String(repeating: "a", count: 20)])
        #expect(sentences.map(\.text).joined(separator: " ").replacingOccurrences(of: " ", with: "") == original)
    }

    @Test func exactlyMaxCharactersIsNotCut() {
        var a = SentenceAssembler(maxCharacters: 20)
        #expect(a.ingest(text: String(repeating: "b", count: 20), range: 0...1).isEmpty)
        #expect(a.flush()?.text.count == 20)
    }

    @Test func flushReturnsRemainderOnce() {
        var a = SentenceAssembler(maxCharacters: 200)
        #expect(a.ingest(text: "and then", range: 3...4).isEmpty)
        #expect(a.hasPending)
        #expect(a.flush() == Sentence(text: "and then", start: 3, end: 4))
        #expect(a.flush() == nil)
        #expect(!a.hasPending)
    }

    @Test func chineseTerminatorSplitsWithoutSpace() {
        var a = SentenceAssembler(maxCharacters: 200)
        let out = a.ingest(text: "好的。开始吧。", range: 0...2)
        #expect(out.map(\.text) == ["好的。", "开始吧。"])
    }

    @Test func cjkBufferJoinsWithoutInsertedSpace() {
        var a = SentenceAssembler(maxCharacters: 200)
        #expect(a.ingest(text: "我们先", range: 0...1).isEmpty)
        #expect(a.ingest(text: "看一下。", range: 1...2).map(\.text) == ["我们先看一下。"])
    }

    @Test func sentenceSpanningTwoPiecesCarriesTailTiming() {
        var a = SentenceAssembler(maxCharacters: 200)
        #expect(a.ingest(text: "We will ship", range: 0...2).isEmpty)
        let out = a.ingest(text: "soon. Then we", range: 2...4)
        #expect(out == [Sentence(text: "We will ship soon.", start: 0, end: 4)])
        #expect(a.hasPending)
        let out2 = a.ingest(text: "celebrate.", range: 4...6)
        #expect(out2 == [Sentence(text: "Then we celebrate.", start: 2, end: 6)])
        #expect(!a.hasPending)
    }

    @Test func flushUsesTailTiming() {
        var a = SentenceAssembler(maxCharacters: 200)
        _ = a.ingest(text: "Done. and then", range: 5...7)
        #expect(a.flush() == Sentence(text: "and then", start: 5, end: 7))
    }

    @Test func questionAndExclamationRequireTrailingSpaceOrEnd() {
        var a = SentenceAssembler(maxCharacters: 200)
        #expect(a.ingest(text: "Really? Yes!", range: 0...1).map(\.text) == ["Really?", "Yes!"])
        #expect(a.ingest(text: "Visit example.com now", range: 1...2).isEmpty)
    }
}
