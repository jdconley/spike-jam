#!/usr/bin/env swift
// Draws the placeholder app icon: a volleyball over the words SPIKE JAM, 1024×1024, opaque.
//
//   scripts/make-icon.swift    writes SpikeJam/Assets.xcassets/AppIcon.appiconset/AppIcon.png
//
// A stand-in until the real art exists. The App Store wants one opaque 1024 px PNG; Xcode derives
// the other sizes from it.
import AppKit
import CoreGraphics

let size = 1024
let out = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent().deletingLastPathComponent()
  .appendingPathComponent("SpikeJam/Assets.xcassets/AppIcon.appiconset/AppIcon.png")

let space = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                          space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
else { fatalError("no bitmap context") }

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: 1) }
let s = CGFloat(size)

// Background: a hot orange-to-magenta arcade gradient.
let gradient = CGGradient(colorsSpace: space, colors: [rgb(1.0, 0.55, 0.1), rgb(0.85, 0.1, 0.45)] as CFArray,
                          locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])

// The ball, upper middle (Core Graphics' origin is bottom left).
let center = CGPoint(x: s / 2, y: s * 0.60)
let r = s * 0.27
// Drop shadow.
ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.25))
ctx.fillEllipse(in: CGRect(x: center.x - r + 18, y: center.y - r - 22, width: r * 2, height: r * 2))
ctx.setFillColor(rgb(1, 0.97, 0.88))
ctx.fillEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))

// Panel seams: three curved bands, clipped to the ball.
ctx.saveGState()
ctx.addEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
ctx.clip()
// Blue panels, between pairs of seams.
ctx.setFillColor(rgb(0.15, 0.4, 0.95))
for angle in [0.0, 2.0 * .pi / 3, 4.0 * .pi / 3] {
  ctx.saveGState()
  ctx.translateBy(x: center.x, y: center.y)
  ctx.rotate(by: angle)
  let band = CGMutablePath()
  band.move(to: CGPoint(x: -r * 0.05, y: 0))
  band.addCurve(to: CGPoint(x: -r * 0.55, y: r * 1.1), control1: CGPoint(x: -r * 0.05, y: r * 0.5),
                control2: CGPoint(x: -r * 0.3, y: r * 0.9))
  band.addLine(to: CGPoint(x: -r * 1.1, y: r * 0.9))
  band.addCurve(to: CGPoint(x: -r * 0.05, y: 0), control1: CGPoint(x: -r * 0.6, y: r * 0.6),
                control2: CGPoint(x: -r * 0.2, y: r * 0.1))
  ctx.addPath(band)
  ctx.fillPath()
  ctx.restoreGState()
}
ctx.setStrokeColor(rgb(0.1, 0.1, 0.2))
ctx.setLineWidth(s * 0.012)
for angle in [0.0, 2.0 * .pi / 3, 4.0 * .pi / 3] {
  ctx.saveGState()
  ctx.translateBy(x: center.x, y: center.y)
  ctx.rotate(by: angle)
  ctx.move(to: .zero)
  ctx.addCurve(to: CGPoint(x: -r * 0.55, y: r * 1.1), control1: CGPoint(x: 0, y: r * 0.5),
               control2: CGPoint(x: -r * 0.3, y: r * 0.9))
  ctx.strokePath()
  ctx.restoreGState()
}
ctx.restoreGState()
ctx.setStrokeColor(rgb(0.1, 0.1, 0.2))
ctx.setLineWidth(s * 0.014)
ctx.strokeEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))

// Motion streaks to the upper left: it's a spike.
ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.85))
ctx.setLineCap(.round)
ctx.setLineWidth(s * 0.025)
for (i, len) in [0.20, 0.28, 0.20].enumerated() {
  let offset = CGFloat(i - 1) * r * 0.45
  let start = CGPoint(x: center.x - r * 0.75 + offset * 0.6, y: center.y + r * 0.75 - offset * -0.6)
  ctx.move(to: CGPoint(x: start.x - s * 0.02, y: start.y + s * 0.02))
  ctx.addLine(to: CGPoint(x: start.x - s * len * 0.7, y: start.y + s * len * 0.7))
}
ctx.strokePath()

// The words.
let nsctx = NSGraphicsContext(cgContext: ctx, flipped: false)
NSGraphicsContext.current = nsctx
let font = NSFont.systemFont(ofSize: s * 0.17, weight: .black)
let shadow = NSShadow()
shadow.shadowColor = NSColor(white: 0, alpha: 0.35)
shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
shadow.shadowBlurRadius = s * 0.01
let style = NSMutableParagraphStyle()
style.alignment = .center
let text = NSAttributedString(string: "SPIKE JAM", attributes: [
  .font: font, .foregroundColor: NSColor.white, .paragraphStyle: style, .shadow: shadow,
  .kern: -s * 0.004,
])
text.draw(in: CGRect(x: 0, y: s * 0.09, width: s, height: s * 0.22))
NSGraphicsContext.current = nil

guard let image = ctx.makeImage(),
      let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
else { fatalError("can't encode the PNG") }
try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
try data.write(to: out)
print("wrote \(out.path)")
