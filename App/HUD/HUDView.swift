import SpikeCore
import SwiftUI

/// The HUD's look (spec §4.4): every signal white, one look each. Green only for perfect timing,
/// orange only for fire; team colors stay on the jerseys.
enum HUDStyle {
    static let ink = Color.black.opacity(0.5)
    static let perfect = Color(red: 0.2, green: 0.95, blue: 0.35)
    static let fire = Color(red: 1, green: 0.55, blue: 0.1)
    static let gold = Color(red: 1, green: 0.85, blue: 0.3)

    static func font(_ size: CGFloat) -> Font { .system(size: size, weight: .black) }
}

/// The match HUD over the court: the drawn signals (tags, arrow, ring, reticle, labels, flashes),
/// the top band (menu, prompt, score) and banners. The strip and the huddle are their own views.
struct HUDView: View {
    let model: HUDModel
    let layout: HUDLayout
    let autoplay: Bool
    let menu: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            HUDCanvas(model: model)
                .allowsHitTesting(false)
            Button(action: menu) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(.white)
                    .frame(width: HUDLayout.menuSize, height: HUDLayout.menuSize)
                    .background(HUDStyle.ink, in: Circle())
            }
            .accessibilityLabel("Menu")
            .position(x: layout.menuRect.midX, y: layout.menuRect.midY)
            if let prompt = model.prompt {
                Text(prompt)
                    .font(HUDStyle.font(14)).italic()
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(HUDStyle.ink, in: Capsule())
                    .frame(maxWidth: layout.promptRect.width)
                    .position(x: layout.promptRect.midX, y: layout.promptRect.midY)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("prompt")
            }
            ScoreChip(score: model.score, autoplay: autoplay, you: model.ownership.localSide ?? .home)
                .frame(width: layout.scoreRect.width, height: layout.scoreRect.height)
                .position(x: layout.scoreRect.midX, y: layout.scoreRect.midY)
                .allowsHitTesting(false)
            if let b = model.banner {
                BannerText(banner: b)
                    .position(x: layout.size.width / 2, y: layout.size.height * 0.42)
                    .id(b.serial)
                    .transition(.scale(scale: 2.2).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .frame(width: layout.size.width, height: layout.size.height)
        .animation(.spring(response: 0.25, dampingFraction: 0.55), value: model.banner?.serial)
    }
}

private struct ScoreChip: View {
    let score: ScoreLine
    let autoplay: Bool
    /// The local player's side, which reads YOU (on the same Wi-Fi it can be away).
    var you: TeamSide = .home

    var body: some View {
        HStack(spacing: 6) {
            side(name(.home), score.home, serving: score.serving == .home)
            Text("–").foregroundStyle(.white.opacity(0.6))
            side(name(.away), score.away, serving: score.serving == .away)
        }
        .font(HUDStyle.font(13))
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HUDStyle.ink, in: Capsule())
        .accessibilityIdentifier("score")
    }

    private func name(_ side: TeamSide) -> String {
        if autoplay { return side == .home ? "HOME" : "AWAY" }
        return side == you ? "YOU" : "THEM"
    }

    private func side(_ name: String, _ points: Int, serving: Bool) -> some View {
        HStack(spacing: 4) {
            Circle().fill(.white).frame(width: 6, height: 6).opacity(serving ? 1 : 0)
            Text(name).font(HUDStyle.font(10)).foregroundStyle(.white.opacity(0.75)).fixedSize()
            Text("\(points)").font(HUDStyle.font(18)).monospacedDigit().fixedSize()
        }
    }
}

private struct BannerText: View {
    let banner: HUDModel.Banner

    var body: some View {
        Text(banner.text)
            .font(.system(size: 64, weight: .black).italic())
            .foregroundStyle(banner.hot
                ? AnyShapeStyle(LinearGradient(colors: [.yellow, HUDStyle.fire, .red], startPoint: .top, endPoint: .bottom))
                : AnyShapeStyle(LinearGradient(colors: [.white, Color(white: 0.82)], startPoint: .top, endPoint: .bottom)))
            .shadow(color: .black.opacity(0.8), radius: 0, x: 4, y: 4)
            .rotationEffect(.degrees(-6))
    }
}

/// The signals drawn over the court each frame, in one Canvas so 12 tags at 120 Hz stay cheap.
private struct HUDCanvas: View {
    let model: HUDModel

    var body: some View {
        Canvas { ctx, _ in
            if let landing = model.landing {
                // Faint: where the ball you receive or dig comes down.
                let r = CGRect(x: landing.x - 22, y: landing.y - 9, width: 44, height: 18)
                ctx.stroke(Path(ellipseIn: r), with: .color(.white.opacity(0.35)), lineWidth: 3)
            }
            for tag in model.tags {
                pill(ctx, tag.text, at: tag.at, size: 10, fg: .white, bg: HUDStyle.ink)
            }
            if let at = model.arrowAt {
                var arrow = Path()
                arrow.move(to: CGPoint(x: at.x - 11, y: at.y - 14))
                arrow.addLine(to: CGPoint(x: at.x + 11, y: at.y - 14))
                arrow.addLine(to: CGPoint(x: at.x, y: at.y))
                arrow.closeSubpath()
                ctx.fill(arrow, with: .color(.white))
                ctx.stroke(arrow, with: .color(.black.opacity(0.6)), lineWidth: 1.5)
            }
            for label in model.setLabels {
                pill(ctx, label.text, at: label.at, size: 17, fg: label.live ? .black : .white.opacity(0.7),
                     bg: label.live ? .white : Color.gray.opacity(0.55), padX: 14, padY: 7)
            }
            if let r = model.reticle {
                if let from = r.from {
                    var line = Path()
                    line.move(to: from)
                    line.addLine(to: r.at)
                    ctx.stroke(line, with: .color(.white.opacity(0.85)), style: StrokeStyle(lineWidth: 2.5, dash: [8, 6]))
                }
                let ring = CGRect(x: r.at.x - 16, y: r.at.y - 16, width: 32, height: 32)
                ctx.stroke(Path(ellipseIn: ring), with: .color(.white), lineWidth: 3)
                var cross = Path()
                cross.move(to: CGPoint(x: r.at.x - 24, y: r.at.y))
                cross.addLine(to: CGPoint(x: r.at.x + 24, y: r.at.y))
                cross.move(to: CGPoint(x: r.at.x, y: r.at.y - 24))
                cross.addLine(to: CGPoint(x: r.at.x, y: r.at.y + 24))
                ctx.stroke(cross, with: .color(.white.opacity(r.onCourt ? 1 : 0.4)), lineWidth: 2)
            }
            if let ring = model.ring {
                let inner: CGFloat = 30
                let size = inner + 120 * ring.progress
                let outer = CGRect(x: ring.center.x - size / 2, y: ring.center.y - size / 2, width: size, height: size)
                let core = CGRect(x: ring.center.x - inner / 2, y: ring.center.y - inner / 2, width: inner, height: inner)
                ctx.fill(Path(ellipseIn: core), with: .color(ring.perfect ? HUDStyle.perfect.opacity(0.5) : .white.opacity(0.2)))
                ctx.stroke(Path(ellipseIn: outer), with: .color(ring.perfect ? HUDStyle.perfect : .white), lineWidth: ring.perfect ? 7 : 4)
            }
            for flash in model.flashes {
                let text = ctx.resolve(Text(flash.text).font(.system(size: 22, weight: .black).italic())
                    .foregroundStyle(flash.perfect ? HUDStyle.perfect : .white))
                var shadow = ctx
                shadow.addFilter(.shadow(color: .black, radius: 2))
                shadow.draw(text, at: CGPoint(x: flash.at.x, y: flash.at.y - 52))
            }
        }
    }

    private func pill(_ ctx: GraphicsContext, _ s: String, at p: CGPoint, size: CGFloat, fg: Color, bg: Color,
                      padX: CGFloat = 6, padY: CGFloat = 2.5) {
        let text = ctx.resolve(Text(s).font(.system(size: size, weight: .heavy)).foregroundStyle(fg))
        let m = text.measure(in: CGSize(width: 300, height: 100))
        let r = CGRect(x: p.x - m.width / 2 - padX, y: p.y - m.height / 2 - padY, width: m.width + 2 * padX,
                       height: m.height + 2 * padY)
        ctx.fill(Path(roundedRect: r, cornerRadius: r.height / 2), with: .color(bg))
        ctx.draw(text, at: p)
    }
}
