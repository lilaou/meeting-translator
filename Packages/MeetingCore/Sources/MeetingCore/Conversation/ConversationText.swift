import Foundation

/// Joins the recognized pieces of one turn into one text.
enum ConversationText {
    /// Trims every piece and drops blank ones. A space goes between two pieces only when
    /// neither character at the seam is Han or CJK punctuation (see
    /// `SentenceAssembler.joinsWithoutSpace`), so Korean keeps its spaces and Chinese gets none.
    static func join(_ pieces: [String]) -> String {
        var out = ""
        for piece in pieces {
            let piece = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let first = piece.first else { continue }
            if let last = out.last, !SentenceAssembler.joinsWithoutSpace(last),
               !SentenceAssembler.joinsWithoutSpace(first) {
                out.append(" ")
            }
            out += piece
        }
        return out
    }
}
