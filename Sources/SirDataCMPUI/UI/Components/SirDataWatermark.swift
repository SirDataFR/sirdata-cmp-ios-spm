import SwiftUI

/// Small watermark rendered at the bottom of the consent UI.
///
/// The config delivers the watermark as a CSS image value
/// (`url(data:image/png;base64,...)`). Raster data URIs are decoded and shown
/// as an image; anything else renders NOTHING. The web writes this value into a
/// CSS image property, so it never shows it as text either: the plain-text
/// branch that lived here printed the word `NONE` (the console's "no image") or
/// a hosted `url(https://…)` as text. Automatically hidden when `whiteLabel` is
/// enabled.
///
/// Mirrors Android's `SirDataWatermark` composable.
struct SirDataWatermark: View {
    @Environment(\.cmpResolvedTheme) private var theme

    var body: some View {
        if theme.whiteLabel {
            EmptyView()
        } else {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        // `watermarkImage` is nil for an empty value and for a data URI that
        // couldn't be decoded (e.g. SVG): both render nothing.
        if let image = theme.watermarkImage {
            HStack {
                Spacer()
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 28)
                    .accessibilityLabel("Sirdata")
                Spacer()
            }
            .padding(.vertical, 8)
        }
    }
}
