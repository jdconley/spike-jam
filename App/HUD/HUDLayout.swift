import CoreGraphics
import SwiftUI

/// Where the HUD's fixed pieces sit for a view size (spec §4.4; Review Focus 5). The top band
/// holds the menu button, the prompt and the score; the bottom band holds the switch strip.
/// While the local player aims, the camera keeps their court between the two bands
/// (`CameraDirector.aimBands`), so nothing fixed covers where you aim.
struct HUDLayout: Equatable {
    var size: CGSize
    /// The safe area: the Dynamic Island side and the home indicator in landscape.
    var insets: EdgeInsets = EdgeInsets()

    /// Big enough for a kid's finger (Apple's minimum is 44).
    static let chipHeight: CGFloat = 46
    static let edge: CGFloat = 8
    /// The top band's height: the menu button, the prompt and the score.
    static let topBand: CGFloat = 44
    static let menuSize: CGFloat = 40
    static let scoreWidth: CGFloat = 132

    var leading: CGFloat { max(insets.leading, Self.edge + 4) }
    var trailing: CGFloat { max(insets.trailing, Self.edge + 4) }

    /// The switch strip's row along the bottom edge.
    var stripRect: CGRect {
        let bottom = max(insets.bottom, Self.edge)
        return CGRect(x: leading, y: size.height - bottom - Self.chipHeight,
                      width: max(size.width - leading - trailing, 0), height: Self.chipHeight)
    }

    var menuRect: CGRect {
        CGRect(x: leading, y: (Self.topBand - Self.menuSize) / 2, width: Self.menuSize, height: Self.menuSize)
    }

    var scoreRect: CGRect {
        CGRect(x: size.width - trailing - Self.scoreWidth, y: 6, width: Self.scoreWidth, height: Self.topBand - 12)
    }

    /// The prompt, between the menu button and the score.
    var promptRect: CGRect {
        let x0 = menuRect.maxX + 10, x1 = scoreRect.minX - 10
        return CGRect(x: x0, y: 6, width: max(x1 - x0, 0), height: Self.topBand - 12)
    }

    /// Everything fixed on screen during a rally.
    var fixedRects: [CGRect] { [menuRect, promptRect, scoreRect, stripRect] }

    /// The camera's NDC limits for the court you aim on: below the top band, above the strip.
    var aimBands: CameraDirector.AimBands {
        guard size.height > 0 else { return CameraDirector.AimBands() }
        let h = Float(size.height)
        let top = 1 - 2 * Float(Self.topBand + 2) / h
        let bottom = 1 - 2 * Float(size.height - stripRect.minY + 4) / h
        return CameraDirector.AimBands(top: top, bottom: bottom)
    }
}
