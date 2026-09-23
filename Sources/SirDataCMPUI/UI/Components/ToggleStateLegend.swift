import SwiftUI
import SirDataCMP

/// Legend revealed by the help (ⓘ) button: one disabled toggle per state with
/// its label — Rejected / Partially rejected / Partially accepted / Accepted, in
/// that order, which is the order of the glyph scale ✕ → − → + → ✓.
///
/// Web parity: `HelpBox.jsx`, rendered by the shared `Help` component on BOTH
/// the purposes screen (`Purposes.jsx`, next to `ourActivities`) and the
/// partners screen (`Vendors.jsx`, next to `ourPartners`). `buttons.help` is
/// only the icon's `title` attribute on the web — never the panel's content.
///
/// Laid out as a column, like `HelpBox.jsx` (`.hContent` is a flex column of
/// `.hcRow`). It used to be a single row, which no longer fits: four toggles plus
/// their labels overflow any phone width.
/// The four labels come from the `cmpToggleStateNames` environment value — the
/// very texts the toggles expose as their accessible value, resolved once per
/// structure rebuild. Reading them here rather than calling `localize.getText`
/// four times keeps Kotlin off the render path, and gives the two newest keys an
/// English fallback instead of an empty label.
struct ToggleStateLegend: View {
    @Environment(\.cmpToggleStateNames) private var stateNames

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            item(state: ToggleState.off, label: stateNames.rejected)
            item(state: ToggleState.partiallyRejected, label: stateNames.partiallyRejected)
            item(state: ToggleState.partiallyAccepted, label: stateNames.partiallyAccepted)
            item(state: ToggleState.on, label: stateNames.accepted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cmp.help.legend")
    }

    @ViewBuilder
    private func item(state: String, label: String) -> some View {
        HStack(spacing: 4) {
            ConsentToggle(state: state, onToggleChange: { _ in }, isDisabled: true)
            Text(label)
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }
}
