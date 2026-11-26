import Combine
import RealityKit
import SwiftUI

/// The demo: `DemoScene` in an `ARView` in non-AR mode, the way the app will draw the match.
public struct SpikeArtDemoView: View {
    let style: ArtStyle

    public init(style: ArtStyle = .placeholder) { self.style = style }

    public var body: some View {
        DemoARView(style: style).ignoresSafeArea()
    }
}

@MainActor
final class DemoHost {
    let scene: DemoScene
    var updates: (any Cancellable)?

    init(arView: ARView, style: ArtStyle) {
        scene = DemoScene(style: style)
        arView.environment.background = .color(Palette.color(style.background))
        #if os(iOS)
        arView.renderOptions.insert(.disableMotionBlur)
        #endif
        let anchor = AnchorEntity(world: .zero)
        anchor.addChild(scene.root)
        arView.scene.addAnchor(anchor)
        updates = arView.scene.subscribe(to: SceneEvents.Update.self) { [weak self] e in
            MainActor.assumeIsolated { self?.scene.step(Float(e.deltaTime)) }
        }
    }
}

#if os(iOS)
struct DemoARView: UIViewRepresentable {
    let style: ArtStyle

    func makeCoordinator() -> Box { Box() }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        context.coordinator.host = DemoHost(arView: view, style: style)
        return view
    }

    func updateUIView(_ view: ARView, context: Context) {}

    final class Box { var host: DemoHost? }
}
#elseif os(macOS)
struct DemoARView: NSViewRepresentable {
    let style: ArtStyle

    func makeCoordinator() -> Box { Box() }

    func makeNSView(context: Context) -> ARView {
        let view = ARView(frame: .zero)
        context.coordinator.host = DemoHost(arView: view, style: style)
        return view
    }

    func updateNSView(_ view: ARView, context: Context) {}

    final class Box { var host: DemoHost? }
}
#endif

#Preview("SpikeArt demo") {
    SpikeArtDemoView()
}
