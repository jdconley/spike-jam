import simd

/// Every knob of the placeholder look in one place, so the final art pass can retune it
/// without touching the rig, court or material code.
///
/// Colors are sRGB components in 0...1.
public struct ArtStyle: Sendable, Equatable {
    /// How a ramp band is picked: `n · l` (−1...1) at or above `litThreshold` is lit,
    /// at or above `shadowThreshold` is mid, anything lower is shadow.
    public var litThreshold: Float
    public var shadowThreshold: Float
    /// Brightness multipliers of the three bands, lit to shadow.
    public var bandLevels: SIMD3<Float>
    /// Hue shift mixed into the shadow band (anime shadows lean cool), and how much of it.
    public var shadowTint: SIMD3<Float>
    public var shadowTintAmount: Float
    /// World-space direction toward the key light. Normalized on use.
    public var lightDirection: SIMD3<Float>
    /// Ink outline thickness for players, in meters at the 1.9 m reference height.
    public var outlineWidth: Float
    /// Ink outline thickness for court props (posts, antennas, referee stand).
    public var propOutlineWidth: Float
    public var outlineColor: SIMD3<Float>
    /// `.automatic` uses `CustomMaterial` where it builds, else the banded `UnlitMaterial`.
    public var shading: Shading

    // Court and arena colors.
    public var courtColor: SIMD3<Float>
    public var freeZoneColor: SIMD3<Float>
    public var arenaFloorColor: SIMD3<Float>
    public var lineColor: SIMD3<Float>
    public var netColor: SIMD3<Float>
    public var background: SIMD3<Float>

    public enum Shading: Sendable, Equatable {
        /// `CustomMaterial` with the toon surface shader, else the banded fallback.
        case automatic
        /// Always the `UnlitMaterial` banded fallback (per-face bands baked at build time).
        case bandedFallback
    }

    public init(
        litThreshold: Float = 0.35,
        shadowThreshold: Float = -0.15,
        bandLevels: SIMD3<Float> = [1.0, 0.78, 0.52],
        shadowTint: SIMD3<Float> = [0.35, 0.3, 0.75],
        shadowTintAmount: Float = 0.18,
        lightDirection: SIMD3<Float> = [-0.45, 0.85, 0.35],
        outlineWidth: Float = 0.022,
        propOutlineWidth: Float = 0.025,
        outlineColor: SIMD3<Float> = [0.04, 0.03, 0.06],
        shading: Shading = .automatic,
        courtColor: SIMD3<Float> = [0.93, 0.6, 0.3],
        freeZoneColor: SIMD3<Float> = [0.16, 0.36, 0.75],
        arenaFloorColor: SIMD3<Float> = [0.12, 0.1, 0.22],
        lineColor: SIMD3<Float> = [1, 1, 1],
        netColor: SIMD3<Float> = [0.06, 0.06, 0.08],
        background: SIMD3<Float> = [0.05, 0.04, 0.1]
    ) {
        self.litThreshold = litThreshold
        self.shadowThreshold = shadowThreshold
        self.bandLevels = bandLevels
        self.shadowTint = shadowTint
        self.shadowTintAmount = shadowTintAmount
        self.lightDirection = lightDirection
        self.outlineWidth = outlineWidth
        self.propOutlineWidth = propOutlineWidth
        self.outlineColor = outlineColor
        self.shading = shading
        self.courtColor = courtColor
        self.freeZoneColor = freeZoneColor
        self.arenaFloorColor = arenaFloorColor
        self.lineColor = lineColor
        self.netColor = netColor
        self.background = background
    }

    /// The placeholder look.
    public static let placeholder = ArtStyle()

    /// The band (0 lit, 1 mid, 2 shadow) for a normal, the same rule the shader uses.
    public func band(forNormal n: SIMD3<Float>) -> Int {
        let ndotl = simd_dot(simd_normalize(n), simd_normalize(lightDirection))
        if ndotl >= litThreshold { return 0 }
        if ndotl >= shadowThreshold { return 1 }
        return 2
    }

    /// The color of `base` in `band`, the same math the shader uses.
    public func shade(_ base: SIMD3<Float>, band: Int) -> SIMD3<Float> {
        let level = bandLevels[min(max(band, 0), 2)]
        var c = base * level
        if band == 2 { c = simd_mix(c, c * shadowTint * 2, SIMD3(repeating: shadowTintAmount)) }
        return simd_clamp(c, .zero, .one)
    }
}
