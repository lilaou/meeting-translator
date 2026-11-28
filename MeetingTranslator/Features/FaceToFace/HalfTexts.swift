import MeetingCore

/// The fixed texts of one half, in its side's language.
struct HalfTexts {
    let speak, stop, starting, listening, finishing, notHeard, translationFailed, failed: String

    init(_ side: ConversationSide) {
        switch side {
        case .chinese:
            (speak, stop) = ("我说中文", "结束")
            (starting, listening, finishing) = ("正在准备…", "在听…", "正在翻译…")
            (notHeard, translationFailed, failed) = ("没听清", "翻译失败", "出错了")
        case .korean:
            (speak, stop) = ("말하기", "멈추기")
            (starting, listening, finishing) = ("준비 중…", "듣는 중…", "번역 중…")
            (notHeard, translationFailed, failed) = ("잘 안 들렸어요", "번역 실패", "오류가 발생했어요")
        case .japanese:
            (speak, stop) = ("話す", "終了")
            (starting, listening, finishing) = ("準備中…", "聞いています…", "翻訳中…")
            (notHeard, translationFailed, failed) =
                ("よく聞き取れませんでした", "翻訳に失敗しました", "エラーが発生しました")
        case .english:
            (speak, stop) = ("Speak", "Stop")
            (starting, listening, finishing) = ("Getting ready…", "Listening…", "Translating…")
            (notHeard, translationFailed, failed) =
                ("Didn't catch that", "Translation failed", "Something went wrong")
        }
    }
}
