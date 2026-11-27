import SpikeCore
import SwiftUI

/// The switch strip (spec §4.1): your six teammates as "#7 OH" chips along the bottom and a
/// "BALL" chip, the one you control lit. Tap one to play them right away. Taps here never count
/// as timing taps: the strip's frame goes to `TouchTranslator.excludedRects`.
struct SwitchStrip: View {
    let chips: [HUDModel.StripChip]
    let tap: (Pick) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(chips) { chip in
                Button {
                    tap(chip.pick)
                } label: {
                    Text(chip.text)
                        .font(HUDStyle.font(chip.pick == .ball ? 15 : 14))
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(chip.lit ? .black : .white)
                        .padding(.horizontal, 12)
                        .frame(minWidth: 64, minHeight: HUDLayout.chipHeight)
                        .background(chip.lit ? Color.white : HUDStyle.ink, in: RoundedRectangle(cornerRadius: 12))
                        .overlay {
                            if chip.pick == .ball && !chip.lit {
                                RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.6), lineWidth: 2)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("strip-\(chip.id)")
                .accessibilityAddTraits(chip.lit ? .isSelected : [])
            }
        }
    }
}
