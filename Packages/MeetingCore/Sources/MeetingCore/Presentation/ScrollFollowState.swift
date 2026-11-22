/// Whether the caption list follows new content. It follows at first; scrolling away from the
/// bottom stops following (and shows "回到最新"); scrolling back to the bottom or jumping to
/// the latest caption resumes it.
public struct ScrollFollowState: Equatable, Sendable {
    /// The list scrolls along with new content.
    public private(set) var isFollowing = true

    /// Following, as at the start of a meeting.
    public init() {}

    /// The user scrolled; `isAtBottom` is whether the newest caption is now in view.
    public mutating func userScrolled(isAtBottom: Bool) { isFollowing = isAtBottom }

    /// The user tapped "回到最新": scroll to the bottom and follow again.
    public mutating func jumpToLatest() { isFollowing = true }

    /// New content arrived: scroll to it only while following.
    public var shouldScrollOnNewContent: Bool { isFollowing }

    /// Show the "回到最新" button while not following.
    public var showsBackToLatest: Bool { !isFollowing }
}
