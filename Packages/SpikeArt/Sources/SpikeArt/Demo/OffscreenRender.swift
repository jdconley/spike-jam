import CoreGraphics
import Foundation
import Metal
import RealityKit

/// Renders an entity tree to a `CGImage` with `RealityRenderer`, no window needed.
/// For the art pass (turntables, look-dev sheets) and for tests that check what reaches the screen.
@MainActor
public enum OffscreenRender {
    public enum RenderError: Error { case noDevice, textureFailed, imageFailed }

    /// Renders `root` through `camera` (which must be inside `root`) for `frames` frames and
    /// returns the last one.
    public static func image(of root: Entity, camera: Entity, width: Int, height: Int,
                             background: SIMD3<Float>, frames: Int = 3) async throws -> CGImage {
        guard let device = MTLCreateSystemDefaultDevice() else { throw RenderError.noDevice }
        let renderer = try RealityRenderer()
        renderer.entities.append(root)
        renderer.activeCamera = camera
        renderer.cameraSettings.colorBackground = .color(Palette.cgColor(background))
        renderer.cameraSettings.antialiasing = .multisample4X
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: width,
                                                            height: height, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: desc) else { throw RenderError.textureFailed }
        let output = try RealityRenderer.CameraOutput(.singleProjection(colorTexture: texture))
        for _ in 0..<max(frames, 1) {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
                do {
                    try renderer.updateAndRender(deltaTime: 1.0 / 60, cameraOutput: output,
                                                 onComplete: { _ in cont.resume() })
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
        renderer.entities.removeAll()
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                                           | CGBitmapInfo.byteOrder32Little.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw RenderError.imageFailed }
        return image
    }

    /// The demo scene as an image.
    public static func demo(width: Int = 1600, height: Int = 900, style: ArtStyle = .placeholder) async throws -> CGImage {
        let scene = DemoScene(style: style)
        return try await image(of: scene.root, camera: scene.camera, width: width, height: height,
                               background: style.background)
    }
}
