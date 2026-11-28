import Foundation

/// Joins the recognized pieces of one turn into one text.
enum ConversationText {
    /// Trims every piece and drops blank ones. A space goes between two pieces only when
    /// neither character at the seam is Han, kana, CJK punctuation or a full-width form (see
    /// `SentenceAssembler.joinsWithoutSpace`), so Korean and English keep their spaces and
    /// Chinese and Japanese get none. A Latin or digit piece next to such a character gets no
    /// space either; two Latin or digit pieces get one.
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
