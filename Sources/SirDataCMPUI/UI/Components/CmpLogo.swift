import SwiftUI

/// Renders the publisher logo from the CMP theme configuration.
///
/// The config delivers the logo as a CSS-style value
/// (`url(data:image/png;base64,...)`). Raster formats are decoded and shown;
/// SVG payloads cannot be rasterized by UIKit and render nothing (see
/// `decodeDataUriImage`). Renders nothing when the logo is absent.
///
/// Mirrors Android's `CmpLogo` composable.
struct CmpLogo: View {
    var height: CGFloat = 32

    @Environment(\.cmpResolvedTheme) private var theme

    var body: some View {
        if let logo = theme.logoImage {
            Image(uiImage: logo)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: height)
                .accessibilityHidden(true)
        }
    }
}
