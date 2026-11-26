import SpikeArt
import SwiftUI

@main
struct SpikeArtDemoApp: App {
    var body: some Scene {
        WindowGroup {
            SpikeArtDemoView()
                .statusBarHidden()
                .persistentSystemOverlays(.hidden)
        }
    }
}
