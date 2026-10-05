import SwiftUI
import SirDataCMP

/// Visual style for a consent button (mirrors Android `ConsentButtonStyle`).
///
/// There is no « close » style: the refusal button in `CLOSE` style is a link drawn at the top of
/// the banner, in place of the close button (`MainBannerView`, `NoConsentCloseLink`). The
/// low-emphasis text button that stood for it in the footer (GAP-M04) was removed on 01/10/2026.
enum ConsentButtonStyle {
    case primary    // filled with the theme main color
    case tonal      // filled neutral — same visual mass as primary (CNIL parity)
    case outlined   // bordered, main-colored label
    case link       // text-only, main-colored label
}

/// Config-driven consent button whose styling derives from the CMP theme,
/// mirroring Android's `ConsentButton` composable.
struct ConsentButton: View {
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
    // visible button surface is tappable — not just the text glyphs.
    var body: some View {
        switch style {
        case .primary:
            Button(action: action) {
                labelText(color: theme.onMain, weight: .semibold)
                    .frame(maxWidth: .infinity)
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
                    .frame(maxWidth: .infinity)
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
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .overlay(shape.stroke(theme.main, lineWidth: 1))
                    .contentShape(shape)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label)

        case .link:
            Button(action: action) {
                labelText(color: theme.main, weight: .medium)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
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

// MARK: - Theme enum → button style / label mapping (mirrors ConsentButton.kt)

extension ThemeNoConsentButtonStyle {
    /// The style of the refusal button when it is drawn as a BUTTON in the banner footer.
    ///
    /// Same rule as the web (`FooterMain.jsx`): the class of « Accept » (`btnPrimary`) for
    /// `BUTTON_BIG_PRIMARY`, `btnDefault` for every other style. `LINK` and `CLOSE` only reach
    /// the footer when the banner is reopened (`MANUAL_DISPLAY`), where the web draws them as
    /// `btnDefault` buttons. `btnDefault` is also the class of « Set choices », drawn here as
    /// `.outlined`: both buttons look the same, as on the web. They were a filled grey `.tonal`
    /// button until 01/10/2026, which the web never draws.
    var consentButtonStyle: ConsentButtonStyle {
        if self == ThemeNoConsentButtonStyle.buttonBigPrimary { return .primary }
        return .outlined
    }
}

extension ThemeSetChoicesStyle {
    var consentButtonStyle: ConsentButtonStyle {
        if self == ThemeSetChoicesStyle.button { return .outlined }
        return .link // LINK and IN_TEXT
    }
}

extension ThemeNoConsentButton {
    /// Resolves the "no consent" button label, or nil when it should be hidden
    /// (`NONE`). Mirrors `ThemeNoConsentButton.resolveLabel`.
    func resolveLabel(_ localize: Localize) -> String? {
        if self == ThemeNoConsentButton.none { return nil }
        if self == ThemeNoConsentButton.continue_ { return localize.getText(key: LocaleKey.buttonsContinue.key) }
        if self == ThemeNoConsentButton.askLater { return localize.getText(key: LocaleKey.buttonsAskMeLater.key) }
        return localize.getText(key: LocaleKey.buttonsReject.key) // REJECT
    }
}
