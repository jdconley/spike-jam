import CoreGraphics
import Foundation
import Metal
import RealityKit
import simd

/// The cel-shaded look: flat albedo times a 3-band light ramp, plus an ink outline.
///
/// Two paths, picked once per `ArtStyle`:
/// - **Custom:** a `CustomMaterial` running `ToonShaderSource`, unlit, banding by the world-space
///   normal against `ArtStyle.lightDirection`. Bands follow the limbs as they move.
/// - **Banded fallback:** where `CustomMaterial` can't be built (no Metal device, a simulator
///   that refuses it), each mesh is split per face into three `UnlitMaterial`s by its rest-pose
///   normal. Bands are baked, so they turn with the part, which is fine for placeholder art.
///
/// The outline is an inverted hull: the mesh pushed out along smoothed normals, drawn black with
/// front faces culled, so only the rim behind the silhouette shows.
@MainActor
public enum ToonMaterial {
    /// Which path a style resolves to.
    public enum Path: Sendable, Equatable { case custom, bandedFallback }

    private static var compiledShader: CustomMaterial.SurfaceShader?
    private static var shaderFailed = false
    private static var ramps: [ArtStyle: TextureResource] = [:]
    private static var white: TextureResource?

    /// The path `style` uses on this device.
    public static func path(for style: ArtStyle) -> Path {
        if style.shading == .bandedFallback { return .bandedFallback }
        return surfaceShader() != nil && (try? customMaterial(color: [1, 1, 1], texture: nil, style: style)) != nil
            ? .custom : .bandedFallback
    }

    /// A toon `CustomMaterial`, or `nil` when the custom path isn't available.
    public static func custom(color: SIMD3<Float>, texture: TextureResource? = nil,
                              style: ArtStyle = .placeholder) -> CustomMaterial? {
        guard style.shading == .automatic else { return nil }
        return try? customMaterial(color: color, texture: texture, style: style)
    }

    /// The three fallback band materials, lit to shadow, indexed by `ArtStyle.band(forNormal:)`.
    public static func banded(color: SIMD3<Float>, texture: TextureResource? = nil,
                              style: ArtStyle = .placeholder) -> [UnlitMaterial] {
        (0..<3).map { band in
            var m = UnlitMaterial(color: Palette.color(style.shade(color, band: band)))
            if let texture { m.color = .init(tint: Palette.color(style.shade(color, band: band)), texture: .init(texture)) }
            return m
        }
    }

    /// The ink outline material: unlit, front faces culled.
    public static func outline(style: ArtStyle = .placeholder) -> UnlitMaterial {
        var m = UnlitMaterial(color: Palette.color(style.outlineColor))
        m.faceCulling = .front
        return m
    }

    /// A flat unlit color, for lines and markers that shouldn't shade.
    public static func flat(_ color: SIMD3<Float>, alpha: Float = 1) -> UnlitMaterial {
        var m = UnlitMaterial(color: Palette.color(color, alpha: alpha))
        if alpha < 1 { m.blending = .transparent(opacity: .init(floatLiteral: alpha)) }
        return m
    }

    // MARK: Internals

    static func surfaceShader() -> CustomMaterial.SurfaceShader? {
        if let compiledShader { return compiledShader }
        if shaderFailed { return nil }
        guard let device = MTLCreateSystemDefaultDevice(),
              let library = try? device.makeLibrary(source: ToonShaderSource.source, options: nil)
        else {
            shaderFailed = true
            return nil
        }
        let shader = CustomMaterial.SurfaceShader(named: ToonShaderSource.functionName, in: library)
        compiledShader = shader
        return shader
    }

    static func customMaterial(color: SIMD3<Float>, texture: TextureResource?, style: ArtStyle) throws -> CustomMaterial {
        guard let shader = surfaceShader() else { throw ToonError.shaderUnavailable }
        var m = try CustomMaterial(surfaceShader: shader, lightingModel: .unlit)
        let tex = try texture ?? whiteTexture()
        m.baseColor = .init(tint: Palette.color(color), texture: .init(tex))
        let l = simd_normalize(style.lightDirection)
        m.custom = .init(value: SIMD4(l, 0), texture: .init(try ramp(for: style)))
        return m
    }

    /// The 256×1 ramp: band multipliers indexed by `n · l` remapped to 0...1.
    static func ramp(for style: ArtStyle) throws -> TextureResource {
        if let r = ramps[style] { return r }
        let width = 256
        var px = [UInt8](repeating: 255, count: width * 4)
        for i in 0..<width {
            let ndotl = Float(i) / Float(width - 1) * 2 - 1
            let band = ndotl >= style.litThreshold ? 0 : (ndotl >= style.shadowThreshold ? 1 : 2)
            let c = style.shade([1, 1, 1], band: band)
            px[i * 4] = UInt8(c.x * 255); px[i * 4 + 1] = UInt8(c.y * 255); px[i * 4 + 2] = UInt8(c.z * 255)
        }
        let image = try rgbaImage(px, width: width, height: 1)
        let r = try TextureResource(image: image, options: .init(semantic: .color, mipmapsMode: .none))
        ramps[style] = r
        return r
    }

    static func whiteTexture() throws -> TextureResource {
        if let white { return white }
        let image = try rgbaImage([UInt8](repeating: 255, count: 4 * 4 * 4), width: 4, height: 4)
        let t = try TextureResource(image: image, options: .init(semantic: .color))
        white = t
        return t
    }

    static func rgbaImage(_ px: [UInt8], width: Int, height: Int) throws -> CGImage {
        guard let provider = CGDataProvider(data: Data(px) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw ToonError.imageFailed }
        return image
    }

    enum ToonError: Error { case shaderUnavailable, imageFailed }
}

extension ArtStyle: Hashable {
    public func hash(into h: inout Hasher) {
        h.combine(litThreshold); h.combine(shadowThreshold)
        h.combine(bandLevels.x); h.combine(bandLevels.y); h.combine(bandLevels.z)
        h.combine(shadowTint.x); h.combine(shadowTint.y); h.combine(shadowTint.z); h.combine(shadowTintAmount)
    }
}

/// Builds cel-shaded `ModelEntity`s from `LowPolyMesh`es on whichever path the style resolves to.
@MainActor
public enum ToonModel {
    /// A model of `mesh` in `color` (times `texture`), with an ink outline child named "outline"
    /// unless `outlineWidth` is 0.
    public static func make(_ mesh: LowPolyMesh, color: SIMD3<Float>, texture: TextureResource? = nil,
                            outlineWidth: Float, style: ArtStyle = .placeholder,
                            name: String = "part") -> ModelEntity {
        let entity: ModelEntity
        if let custom = ToonMaterial.custom(color: color, texture: texture, style: style),
           let res = try? MeshResource.generate(from: [mesh.descriptor(name: name)]) {
            entity = ModelEntity(mesh: res, materials: [custom])
        } else {
            let faces = (0..<mesh.triangleCount).map { UInt32(style.band(forNormal: mesh.faceNormal($0))) }
            let res = (try? MeshResource.generate(from: [mesh.descriptor(name: name, faceMaterials: faces)]))
                ?? MeshResource.generateBox(size: 0.01)
            entity = ModelEntity(mesh: res, materials: ToonMaterial.banded(color: color, texture: texture, style: style))
        }
        entity.name = name
        if outlineWidth > 0, let hull = try? MeshResource.generate(from: [mesh.outlineHull(width: outlineWidth).descriptor(name: name + "-outline")]) {
            let o = ModelEntity(mesh: hull, materials: [ToonMaterial.outline(style: style)])
            o.name = "outline"
            entity.addChild(o)
        }
        return entity
    }
}
