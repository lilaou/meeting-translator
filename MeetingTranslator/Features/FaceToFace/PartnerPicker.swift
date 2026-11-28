import MeetingCore
import SwiftUI

/// The menu that chooses the other side's language. Every item names it in Chinese and in
/// itself, so the other side can point at it.
struct PartnerPicker: View {
    let partner: ConversationSide
    /// False while a turn is in progress.
    let canChoose: Bool
    let choose: (ConversationSide) -> Void

    var body: some View {
        Menu("对方语言：\(partner.chineseName)") {
            ForEach(ConversationSide.partners, id: \.self) { side in
                Button { choose(side) } label: {
                    let title = "\(side.chineseName) \(side.nativeName)"
                    if side == partner {
                        Label(title, systemImage: "checkmark")
                    } else {
                        Text(title)
                    }
                }
            }
        }
        .disabled(!canChoose)
    }
}
