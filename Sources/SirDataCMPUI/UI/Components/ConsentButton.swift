import SwiftUI
import SirDataCMP

/// Visual style for a consent button (mirrors Android `ConsentButtonStyle`).
enum ConsentButtonStyle {
    case primary    // filled with the theme main color
    case tonal      // filled neutral — same visual mass as primary (CNIL parity)
    case outlined   // bordered, main-colored label
    case link       // text-only, main-colored label
    case close      // minimal, low-emphasis text
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

        case .close:
            // GAP-M04: Web uses dual-layer mask for CLOSE style. Mobile uses simple
            // low-emphasis button — accepted platform deviation.
            Button(action: action) {
                Text(label)
                    .font(.footnote)
                    .foregroundColor(theme.text.opacity(0.6))
                    .frame(maxWidth: .infinity)
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

// MARK: - Theme enum → button style / label mapping (mirrors ConsentButton.kt)

extension ThemeNoConsentButtonStyle {
    var consentButtonStyle: ConsentButtonStyle {
        // BIG_DEFAULT renders as a filled tonal button so "reject" carries the
        // same visual weight as "accept" (CNIL equal-prominence requirement).
        if self == ThemeNoConsentButtonStyle.buttonBigDefault { return .tonal }
        if self == ThemeNoConsentButtonStyle.buttonBigPrimary { return .primary }
        if self == ThemeNoConsentButtonStyle.close { return .close }
        return .link
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
