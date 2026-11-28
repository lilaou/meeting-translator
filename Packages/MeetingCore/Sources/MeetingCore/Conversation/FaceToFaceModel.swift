import Observation

/// What one visit with one partner language owns.
@MainActor public struct ConversationVisit {
    public let partner: ConversationSide
    public let session: ConversationSession
    public let packs: ConversationPacks

    public init(partner: ConversationSide, session: ConversationSession, packs: ConversationPacks) {
        self.partner = partner
        self.session = session
        self.packs = packs
    }

    /// Never waits: cancels the packs, and `session.leave()` runs in a task of its own.
    public func close() {
        packs.cancel()
        Task { [session] in await session.leave() }
    }
}

/// The face-to-face screen across language changes: one visit at a time, a new one for every
/// change of the partner language.
@MainActor @Observable public final class FaceToFaceModel {
    public private(set) var visit: ConversationVisit

    @ObservationIgnored private let save: (String) -> Void
    @ObservationIgnored private let makeVisit: @MainActor (ConversationSide) -> ConversationVisit

    /// True only while the session is idle.
    public var canChoose: Bool { visit.session.phase == .idle }

    /// `storedPartner` is the value `save` received last, if any; only `choose` saves.
    public init(storedPartner: String?, save: @escaping (String) -> Void,
                makeVisit: @escaping @MainActor (ConversationSide) -> ConversationVisit) {
        self.save = save
        self.makeVisit = makeVisit
        visit = makeVisit(ConversationSide.storedPartner(storedPartner))
    }

    /// Closes the current visit, remembers `partner` and starts its visit. Does nothing for the
    /// current language, one that is not in `ConversationSide.partners`, or while `canChoose`
    /// is false.
    public func choose(_ partner: ConversationSide) {
        guard partner != visit.partner, ConversationSide.partners.contains(partner),
              canChoose else { return }
        visit.close()
        save(partner.rawValue)
        visit = makeVisit(partner)
    }

    /// Closes the current visit, for when the screen goes away; no new one is made.
    public func close() {
        visit.close()
    }
}
