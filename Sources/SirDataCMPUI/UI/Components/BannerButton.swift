import SwiftUI
import SirDataCMP

/// Banner-specific consent button.
///
/// This is a dedicated copy of `ConsentButton` used ONLY by `MainBannerView`.
/// It exists to isolate the banner's fixed-height layout (`.frame(height: 90)`
/// applied by the caller) from the generic `ConsentButton` used by the
/// purposes and partners screens.
///
/// The key difference: the button label fills the full height of the frame
/// (`.frame(maxWidth: .infinity, maxHeight: .infinity)` INSIDE the `Button`
/// label), so the background and tappable area expand to the 90pt height the
/// caller assigns. `ConsentButton` intentionally has NO height constraints so
/// it stays flexible on the other screens.
struct BannerButton: View {
    let label: String
    let action: () -> Void
    var style: ConsentButtonStyle = .primary
    /// When true, a `.primary` button uses the full main color; otherwise a
    /// slightly de-emphasized variant (parity with Android `isPrimary`).
    var isPrimary: Bool = true

    @Environment(\.cmpResolvedTheme) private var theme

    /// Web parity: buttons take HALF the configured radius
    /// (buttons.less `.btnContent { border-radius: calc(var(--border-radius) / 2) }`).
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: theme.cornerRadius / 2) }

    // NOTE (hit area): all decoration (frame/padding/background/overlay) lives
    // INSIDE the `Button` label, followed by `.contentShape`, so the whole
    // visible button surface — including the caller-assigned fixed height —
    // is tappable, not just the text glyphs.
    var body: some View {
        switch style {
        case .primary:
            Button(action: action) {
                labelText(color: theme.onMain, weight: .semibold)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.vertical, 12)
                    .background((isPrimary ? theme.main : theme.main.opacity(0.7)))
                    .clipShape(shape)
                    .contentShape(shape)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label)

        case .tonal:
            Button(action: action) {
                labelText(color: theme.text, weight: .semibold)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.vertical, 12)
                    .background(theme.text.opacity(0.15))
                    .clipShape(shape)
                    .contentShape(shape)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label)

        case .outlined:
            Button(action: action) {
                labelText(color: theme.main, weight: .medium)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.vertical, 12)
                    .overlay(shape.stroke(theme.main, lineWidth: 1))
                    .contentShape(shape)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label)

        case .link:
            Button(action: action) {
                labelText(color: theme.main, weight: .medium)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label)

        case .close:
            Button(action: action) {
                Text(label)
                    .font(.footnote)
                    .foregroundColor(theme.text.opacity(0.6))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
        }
    }

    private func labelText(color: Color, weight: Font.Weight) -> some View {
        Text(label)
            .font(.subheadline)
            .fontWeight(weight)
            .foregroundColor(color)
            .multilineTextAlignment(.center)
    }
}
