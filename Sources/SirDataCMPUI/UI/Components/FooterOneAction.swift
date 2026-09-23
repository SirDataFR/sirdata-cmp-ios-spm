import SwiftUI

/// A footer with a single full-width primary button.
///
/// Web CMP parity: `FooterOneAction.jsx` — renders one `btnPrimary` button
/// that spans the full footer width. Used by the Cookiewall and PurposeOne
/// screens where a single action ("Modify Choice" / "Accept Cookies") is
/// the only available user interaction.
struct FooterOneAction: View {
    let label: String
    let action: () -> Void

    @Environment(\.cmpResolvedTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            Button(action: action) {
                Text(label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(theme.onMain)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(theme.main)
                    // Web parity: half the configured radius on buttons (buttons.less).
                    .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius / 2))
            }
            .buttonStyle(.plain)
            .padding(16)
        }
        .background(theme.background)
    }
}
