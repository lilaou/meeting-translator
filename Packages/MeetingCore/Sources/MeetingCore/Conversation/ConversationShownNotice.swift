/// What one half shows for a turn's notice.
public enum ConversationShownNotice: Equatable, Sendable {
    /// The half's own "nothing was heard" line.
    case notHeard
    /// The half's own fixed failure line, with no reason.
    case failed
    /// A readable reason in Chinese.
    case reason(String)
}

extension ConversationSession.Notice {
    /// What the half of `side` shows when `speaker`'s turn ended with this notice. The partner's
    /// half shows only lines in its own language, and only for its own turn. Reasons exist only
    /// in Chinese, so the Chinese half shows them for either side's turn.
    public func shown(on side: ConversationSide,
                      speaker: ConversationSide) -> ConversationShownNotice? {
        switch (self, side) {
        case (.notHeard, _): side == speaker ? .notHeard : nil
        case (.failed(let reason), .chinese):
            .reason(side == speaker ? reason : "对方这次出错了：" + reason)
        case (.failed, _): side == speaker ? .failed : nil
        }
    }
}
