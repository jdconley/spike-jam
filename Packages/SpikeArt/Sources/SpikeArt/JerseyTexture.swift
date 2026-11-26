import CoreGraphics
import CoreText
import Foundation
import RealityKit

/// Core Graphics jersey atlases: one 512×512 image per (team, number, libero), with the number
/// big on the front and bigger on the back, and small on the shorts.
///
/// Layout, top-left origin, in pixels:
/// ```
/// 0     256    512
/// +------+------+ 0
/// |front |back  |
/// |  7   |  7   |
/// +------+------+ 320
/// | jersey solid| 384   (sides, top, sleeves)
/// +------+------+
/// |shorts|shorts| 512
/// | 7    |solid |
/// +------+------+
/// ```
public enum JerseyTexture {
    public static let size = 512

    public struct Key: Hashable, Sendable {
        public var team: ArtTeam
        public var number: Int
        public var libero: Bool
        public init(team: ArtTeam, number: Int, libero: Bool) {
            self.team = team; self.number = number; self.libero = libero
        }
    }

    /// Where each panel sits in the atlas, as UV rects (top-left origin, 0...1).
    public enum Region {
        public static let front = LowPolyMesh.UVRect(0, 0, 0.5, 0.625)
        public static let back = LowPolyMesh.UVRect(0.5, 0, 1, 0.625)
        public static let jerseySolid = LowPolyMesh.UVRect(0.02, 0.645, 0.98, 0.68)
        public static let shortsFront = LowPolyMesh.UVRect(0, 0.75, 0.5, 1)
        public static let shortsSolid = LowPolyMesh.UVRect(0.52, 0.77, 0.98, 0.98)
    }

    @MainActor private static var cache: [Key: TextureResource] = [:]

    /// The cached texture for `key`, drawn on first use.
    @MainActor public static func texture(for key: Key) throws -> TextureResource {
        if let t = cache[key] { return t }
        let t = try TextureResource(image: image(for: key), options: .init(semantic: .color))
        cache[key] = t
        return t
    }

    @MainActor public static func texture(team: ArtTeam, number: Int, libero: Bool) throws -> TextureResource {
        try texture(for: Key(team: team, number: number, libero: libero))
    }

    /// How many atlases are cached (for tests).
    @MainActor public static var cachedCount: Int { cache.count }

    /// Draws the atlas. Pure Core Graphics, so it can run anywhere.
    public static func image(for key: Key) -> CGImage {
        let s = size
        let ctx = CGContext(data: nil, width: s, height: s, bitsPerComponent: 8, bytesPerRow: s * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Work in top-left coordinates for rects; text flips itself back.
        func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: x, y: CGFloat(s) - y - h, width: w, height: h)
        }
        let jersey = Palette.jersey(key.team, libero: key.libero)
        let shorts = Palette.shorts(key.team, libero: key.libero)
        let ink = Palette.numberInk(key.team, libero: key.libero)
        let trim: SIMD3<Float> = key.libero ? (key.team == .home ? Palette.homeJersey : Palette.awayJersey)
                                            : (key.team == .home ? [1, 0.9, 0.85] : [0.9, 1, 1])

        ctx.setFillColor(Palette.cgColor(jersey))
        ctx.fill(rect(0, 0, 512, 384))
        // A collar trim and side piping so front and back read as a shirt.
        ctx.setFillColor(Palette.cgColor(trim))
        ctx.fill(rect(0, 0, 256, 14)); ctx.fill(rect(256, 0, 256, 14))
        ctx.fill(rect(0, 352, 512, 10))
        ctx.setFillColor(Palette.cgColor(shorts))
        ctx.fill(rect(0, 384, 512, 128))
        ctx.setFillColor(Palette.cgColor(trim))
        ctx.fill(rect(0, 500, 512, 12))

        let text = String(key.number)
        let outline: SIMD3<Float> = (key.team == .home && key.libero) ? [1, 1, 1] : [0.05, 0.04, 0.08]
        drawNumber(text, in: rect(16, 40, 224, 260), height: 200, ink: ink, outline: outline, ctx: ctx)
        drawNumber(text, in: rect(268, 30, 232, 280), height: 240, ink: ink, outline: outline, ctx: ctx)
        // Shorts: the number on the left leg (the right half of the front panel, as seen).
        drawNumber(text, in: rect(150, 400, 96, 90), height: 72, ink: ink, outline: outline, ctx: ctx)
        return ctx.makeImage()!
    }

    static func drawNumber(_ text: String, in box: CGRect, height: CGFloat, ink: SIMD3<Float>,
                           outline: SIMD3<Float>, ctx: CGContext) {
        // A condensed heavy face so two digits fit; falls back to Helvetica Bold.
        let font = CTFontCreateWithName("HelveticaNeue-CondensedBlack" as CFString, height, nil)
        func line(stroke: CGFloat) -> CTLine {
            var attrs: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): Palette.cgColor(ink),
            ]
            if stroke > 0 {
                attrs[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] = stroke
                attrs[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] = Palette.cgColor(outline)
            }
            return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        }
        let fill = line(stroke: 0)
        ctx.textMatrix = .identity
        ctx.textPosition = .zero
        var bounds = CTLineGetImageBounds(fill, ctx)
        // Squash wide numbers to fit the panel.
        let sx = min(1, (box.width * 0.92) / max(bounds.width, 1))
        bounds.size.width *= sx
        ctx.saveGState()
        ctx.translateBy(x: box.midX - bounds.width / 2 - bounds.minX * sx, y: box.midY - bounds.height / 2 - bounds.minY)
        ctx.scaleBy(x: sx, y: 1)
        ctx.textPosition = .zero
        // Stroke width is a percentage of the font size: ~9% gives a bold ink edge.
        CTLineDraw(line(stroke: 18), ctx)
        ctx.textPosition = .zero
        CTLineDraw(fill, ctx)
        ctx.restoreGState()
        ctx.textPosition = .zero
    }
}
