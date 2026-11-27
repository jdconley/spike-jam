import SpikeCore
import SwiftUI

/// The huddle between rallies (spec §4.3), basic version: your side's rotation top down with the
/// net at the top, a chip per player to pick who you play, a call chip under each attacker that a
/// tap cycles (a long press says what the call means), "BALL" to follow the ball, "GO" when
/// you're done, and a bar counting down to the serve. Doing nothing keeps the last picks.
struct HuddleView: View {
    let huddle: HUDModel.HuddleModel
    let pick: (Pick) -> Void
    let cycle: (AthleteID) -> Void
    let explain: (AthleteID) -> Void
    let ready: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                bigButton("BALL", lit: huddle.ballPicked, id: "huddle-ball") { pick(.ball) }
                Countdown(fraction: huddle.fraction)
                bigButton(huddle.ready ? "READY" : "GO!", lit: huddle.ready, gold: !huddle.ready, id: "huddle-ready", action: ready)
            }
            VStack(spacing: 0) {
                // The net along the top.
                Rectangle().fill(.white.opacity(0.85)).frame(height: 3)
                Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                    GridRow { cell(.z4); cell(.z3); cell(.z2) }
                    GridRow { cell(.z5); cell(.z6); cell(.z1) }
                }
                .padding(8)
            }
            .background(Color(red: 0.85, green: 0.55, blue: 0.3).opacity(0.35), in: Rectangle())
            .overlay(Rectangle().stroke(.white.opacity(0.7), lineWidth: 2))
            Text(huddle.meaning ?? (huddle.serving ? "YOU SERVE • TAP WHO YOU PLAY" : "THEY SERVE • TAP WHO YOU PLAY"))
                .font(HUDStyle.font(11))
                .foregroundStyle(.white.opacity(huddle.meaning == nil ? 0.7 : 1))
                .lineLimit(1).minimumScaleFactor(0.6)
                .frame(height: 16)
        }
        .padding(10)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 18))
    }

    @ViewBuilder private func cell(_ z: Zone) -> some View {
        if let spot = huddle.spots.first(where: { $0.zone == z }) {
            VStack(spacing: 4) {
                Button {
                    pick(.athlete(spot.id))
                } label: {
                    Text(spot.text)
                        .font(HUDStyle.font(14))
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .foregroundStyle(spot.picked ? .black : .white)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(spot.picked ? Color.white : HUDStyle.ink, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("huddle-pick-\(spot.id.index)")
                if let call = spot.call {
                    Text(call.display)
                        .font(HUDStyle.font(15))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(HUDStyle.gold.opacity(spot.canCycle ? 1 : 0.6), in: Capsule())
                        .contentShape(Capsule())
                        .onTapGesture { cycle(spot.id) }
                        .onLongPressGesture(minimumDuration: 0.4) { explain(spot.id) }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityIdentifier("huddle-call-\(spot.id.index)")
                } else {
                    Color.clear.frame(height: 36)
                }
            }
            .frame(width: 104)
        }
    }

    private func bigButton(_ text: String, lit: Bool, gold: Bool = false, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(HUDStyle.font(16))
                .foregroundStyle(lit || gold ? .black : .white)
                .frame(minWidth: 76, minHeight: 44)
                .background(gold ? HUDStyle.gold : lit ? Color.white : HUDStyle.ink, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}

/// The bar running down to the serve.
private struct Countdown: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.15))
                Capsule().fill(.white).frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 10)
    }
}
