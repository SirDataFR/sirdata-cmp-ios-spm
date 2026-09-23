import SwiftUI

/// Small watermark rendered at the bottom of the consent UI.
///
/// The config delivers the watermark as a CSS-style value: either plain text
/// or an image data URI (`url(data:image/png;base64,...)`). Raster data URIs
/// are decoded and shown as an image; plain text is shown as a faint label;
/// non-decodable data URIs (e.g. SVG) render nothing rather than leaking raw
/// base64. Automatically hidden when `whiteLabel` is enabled.
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
        let raw = theme.watermarkRaw
        if raw.isEmpty {
            EmptyView()
        } else if let image = theme.watermarkImage {
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
        } else if !raw.contains("data:image/") {
            // Plain-text watermark.
            HStack {
                Spacer()
                Text(raw)
                    .font(.caption2)
                    .foregroundColor(theme.text.opacity(0.4))
                Spacer()
            }
            .padding(.vertical, 8)
        } else {
            // Data URI that couldn't be decoded (e.g. SVG): render nothing.
            EmptyView()
        }
    }
}
