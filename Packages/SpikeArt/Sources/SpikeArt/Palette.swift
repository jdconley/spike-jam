import Foundation
import simd

#if canImport(UIKit)
import UIKit
public typealias PlatformColor = UIColor
#elseif canImport(AppKit)
import AppKit
public typealias PlatformColor = NSColor
#endif

/// Which side a player is on. Mirrors SpikeCore's `TeamSide` without depending on it.
public enum ArtTeam: Int, Sendable, Hashable, CaseIterable {
    case home, away
}

/// The placeholder palette. sRGB components in 0...1.
public enum Palette {
    /// 10 skin-tone stops across the human range, ordered from lightest (0) to darkest (9).
    /// SpikeCore's `Athlete.skinTone` indexes into this.
    public static let skin: [SIMD3<Float>] = [
        [0.98, 0.88, 0.80],
        [0.95, 0.80, 0.69],
        [0.90, 0.72, 0.59],
        [0.84, 0.63, 0.48],
        [0.76, 0.55, 0.40],
        [0.66, 0.46, 0.32],
        [0.56, 0.38, 0.26],
        [0.45, 0.30, 0.20],
        [0.35, 0.23, 0.15],
        [0.25, 0.16, 0.11],
    ]

    /// Team jersey colors, from the spike's score chips.
    public static let homeJersey: SIMD3<Float> = [0.95, 0.25, 0.2]
    public static let awayJersey: SIMD3<Float> = [0.1, 0.75, 0.75]
    /// The libero's contrasting jersey: home white, away navy.
    public static let homeLibero: SIMD3<Float> = [0.96, 0.96, 0.96]
    public static let awayLibero: SIMD3<Float> = [0.12, 0.12, 0.3]

    /// A few natural hair colors, indexed by `PlayerLook.hairColor`.
    public static let hair: [SIMD3<Float>] = [
        [0.08, 0.06, 0.05], // black
        [0.25, 0.15, 0.08], // dark brown
        [0.45, 0.28, 0.14], // brown
        [0.78, 0.6, 0.3],   // blond
        [0.62, 0.24, 0.1],  // auburn
        [0.7, 0.7, 0.72],   // silver
    ]

    /// Shoe colors, indexed by `PlayerLook.shoeColor`.
    public static let shoes: [SIMD3<Float>] = [
        [0.96, 0.96, 0.96], // white
        [0.1, 0.1, 0.12],   // black
        [1.0, 0.82, 0.1],   // yellow
        [0.3, 0.45, 1.0],   // blue
        [0.95, 0.4, 0.7],   // pink
    ]

    /// Knee pads, headbands and sleeves.
    public static let gearDark: SIMD3<Float> = [0.12, 0.12, 0.14]
    public static let gearLight: SIMD3<Float> = [0.94, 0.94, 0.94]

    public static func jersey(_ team: ArtTeam, libero: Bool) -> SIMD3<Float> {
        switch (team, libero) {
        case (.home, false): homeJersey
        case (.away, false): awayJersey
        case (.home, true): homeLibero
        case (.away, true): awayLibero
        }
    }

    /// Shorts: a deep shade that reads against both jersey and court.
    public static func shorts(_ team: ArtTeam, libero: Bool) -> SIMD3<Float> {
        team == .home ? [0.16, 0.06, 0.08] : [0.04, 0.14, 0.2]
    }

    /// The number ink: white on dark or saturated jerseys, team-dark on the white libero top.
    public static func numberInk(_ team: ArtTeam, libero: Bool) -> SIMD3<Float> {
        (team == .home && libero) ? [0.75, 0.12, 0.1] : [1, 1, 1]
    }

    /// CIE L* (0...100) of an sRGB color: the order `skin` is sorted by.
    public static func lightness(_ c: SIMD3<Float>) -> Float {
        func lin(_ v: Float) -> Float { v <= 0.04045 ? v / 12.92 : powf((v + 0.055) / 1.055, 2.4) }
        let y = 0.2126 * lin(c.x) + 0.7152 * lin(c.y) + 0.0722 * lin(c.z)
        return y > 216.0 / 24389.0 ? 116 * cbrtf(y) - 16 : y * 24389.0 / 27.0
    }

    public static func color(_ c: SIMD3<Float>, alpha: Float = 1) -> PlatformColor {
        PlatformColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: CGFloat(alpha))
    }

    static func cgColor(_ c: SIMD3<Float>, alpha: Float = 1) -> CGColor {
        CGColor(srgbRed: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: CGFloat(alpha))
    }
}
