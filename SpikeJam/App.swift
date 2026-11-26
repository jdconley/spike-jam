// THROWAWAY SPIKE. App shell and the 2D overlay: score, prompts, timing ring, set markers, banners.

import SwiftUI
import Observation

struct RingState { var center: CGPoint; var progress: CGFloat; var perfect: Bool }
struct SetMarker: Identifiable { var id: String { label }; var label: String; var at: CGPoint; var available: Bool; var hot: Bool }
struct Banner: Identifiable, Equatable { let id = UUID(); var text: String; var hot: Bool; var small = false }
struct Flash: Identifiable, Equatable { let id = UUID(); var text: String; var good: Bool; var at: CGPoint }

@Observable
final class HUDModel {
    var score = [0, 0]
    var serving: Team = .home
    var prompt: String?
    var ring: RingState?
    var options: [SetMarker] = []
    var banner: Banner?
    var flashes: [Flash] = []
    var matchOver = false
    var speedIndex = 1

    func show(_ text: String, hot: Bool, small: Bool = false) {
        let b = Banner(text: text, hot: hot, small: small)
        withAnimation(.spring(response: 0.25, dampingFraction: 0.5)) { banner = b }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.banner?.id == b.id else { return }
            withAnimation(.easeIn(duration: 0.2)) { self.banner = nil }
        }
    }

    func flash(_ text: String, good: Bool, at: CGPoint) {
        let f = Flash(text: text, good: good, at: at)
        withAnimation(.spring(response: 0.2, dampingFraction: 0.6)) { flashes.append(f) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            withAnimation(.easeOut(duration: 0.2)) { self?.flashes.removeAll { $0.id == f.id } }
        }
    }
}

@main
struct SpikeJamApp: App {
    var body: some Scene {
        WindowGroup { GameScreen().ignoresSafeArea().statusBarHidden().persistentSystemOverlays(.hidden) }
    }
}

struct CourtRepresentable: UIViewRepresentable {
    let hud: HUDModel
    let holder: ViewHolder
    func makeUIView(context: Context) -> CourtView {
        let v = CourtView(hud: hud)
        holder.view = v
        return v
    }
    func updateUIView(_ uiView: CourtView, context: Context) {}
}

final class ViewHolder { weak var view: CourtView? }

struct GameScreen: View {
    @State var hud = HUDModel()
    @State var holder = ViewHolder()
    let speeds: [(String, Double)] = [("FAST", 1.2), ("FASTER", 1.0), ("STUPID FAST", 0.82)]

    var body: some View {
        ZStack {
            CourtRepresentable(hud: hud, holder: holder)
            overlay.allowsHitTesting(false)
            VStack {
                HStack {
                    Spacer()
                    Button(speeds[hud.speedIndex].0) {
                        hud.speedIndex = (hud.speedIndex + 1) % speeds.count
                        holder.view?.sim.speedFactor = speeds[hud.speedIndex].1
                    }
                    .font(.system(size: 12, weight: .black)).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.black.opacity(0.4), in: Capsule())
                }
                Spacer()
            }
            .padding(.top, 14).padding(.trailing, 60)
        }
        .background(Color.black)
    }

    var overlay: some View {
        ZStack {
            // Score
            VStack {
                HStack(spacing: 14) {
                    scoreChip("YOU", hud.score[0], Color(red: 0.95, green: 0.25, blue: 0.2), serving: hud.serving == .home)
                    scoreChip("CPU", hud.score[1], Color(red: 0.1, green: 0.75, blue: 0.75), serving: hud.serving == .away)
                }
                .padding(.top, 12)
                Spacer()
                if let p = hud.prompt {
                    Text(p)
                        .font(.system(size: 18, weight: .black)).italic()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(.black.opacity(0.45), in: Capsule())
                        .padding(.bottom, 18)
                }
            }
            // Timing ring
            if let r = hud.ring {
                let size = 34 + 110 * r.progress
                ZStack {
                    Circle().stroke(r.perfect ? Color.green : Color.white, lineWidth: r.perfect ? 7 : 4).frame(width: size, height: size)
                    Circle().fill(r.perfect ? Color.green.opacity(0.5) : Color.white.opacity(0.18)).frame(width: 34, height: 34)
                }
                .position(r.center)
            }
            // Set options
            ForEach(hud.options) { o in
                Text(o.label)
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(o.available ? .black : .white.opacity(0.5))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(o.available ? (o.hot ? Color.orange : Color.white) : Color.gray.opacity(0.5), in: Capsule())
                    .position(x: o.at.x, y: o.at.y - 30)
            }
            // Judgement flashes
            ForEach(hud.flashes) { f in
                Text(f.text)
                    .font(.system(size: 20, weight: .black)).italic()
                    .foregroundStyle(f.good ? Color.green : Color.white)
                    .shadow(color: .black, radius: 2)
                    .position(x: f.at.x, y: f.at.y - 50)
                    .transition(.scale(scale: 0.3).combined(with: .opacity))
            }
            // Banner
            if let b = hud.banner {
                Text(b.text)
                    .font(.system(size: b.small ? 30 : 64, weight: .black)).italic()
                    .foregroundStyle(b.hot
                        ? AnyShapeStyle(LinearGradient(colors: [.yellow, .orange, .red], startPoint: .top, endPoint: .bottom))
                        : AnyShapeStyle(LinearGradient(colors: [.white, Color(white: 0.8)], startPoint: .top, endPoint: .bottom)))
                    .shadow(color: .black.opacity(0.8), radius: 0, x: 4, y: 4)
                    .shadow(color: b.hot ? .orange : .blue, radius: 18)
                    .rotationEffect(.degrees(-6))
                    .frame(maxHeight: .infinity, alignment: b.small ? .top : .center)
                    .padding(.top, b.small ? 64 : 0)
                    .id(b.id)
                    .transition(.scale(scale: 2.4).combined(with: .opacity))
            }
            if hud.matchOver {
                VStack { Spacer(); Text("TAP FOR A REMATCH").font(.system(size: 16, weight: .black)).foregroundStyle(.white).padding(.bottom, 60) }
            }
        }
    }

    func scoreChip(_ name: String, _ s: Int, _ c: Color, serving: Bool) -> some View {
        HStack(spacing: 8) {
            if serving { Circle().fill(.white).frame(width: 8, height: 8) }
            Text(name).font(.system(size: 13, weight: .black))
            Text("\(s)").font(.system(size: 26, weight: .black)).monospacedDigit()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14).padding(.vertical, 4)
        .background(c.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
    }
}
