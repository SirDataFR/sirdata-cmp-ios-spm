import SwiftUI

/// A switch-style toggle supporting the four consent states, mirroring Android's
/// `ConsentToggle` and the web's `Toggle.jsx` / `toggle.module.less`:
///
/// | state | thumb | track | glyph |
/// |---|---|---|---|
/// | OFF (rejected) | left | neutral | ✕ |
/// | PARTIALLY_REJECTED | centre | neutral | − |
/// | PARTIALLY_ACCEPTED | centre | **coloured** | + |
/// | ON (accepted) | right | coloured | ✓ |
///
/// Two axes carry the meaning so neither has to be read alone. The glyph shape is
/// an ordered scale ✕ → − → + → ✓, the only signal that survives greyscale, high
/// contrast and colour-vision deficiencies (WCAG 1.4.1 — separating the two
/// partial states by colour alone would fail it). The track carries the consent
/// axis: coloured as soon as one consent is granted, so it never promises what was
/// not given — which is exactly what a tinted "mixed" track used to do for a
/// dual-basis purpose with consent OFF and legitimate interest un-opposed.
///
/// The two partial states share the centre position; telling them apart is the
/// glyph's and the track's job (web parity: the thumb keeps its three positions).
///
/// The callback reports intent to toggle. The new value is intentionally NOT
/// derived from `state` at the call site (which can lag the store); callers wire
/// this to a ViewModel method that flips from the live selector state. The Bool
/// argument is passed for source-compatibility but ignored by intent-based
/// callers. Mirrors the Android `ConsentToggle` intent contract.
struct ConsentToggle: View {
    /// One of `ToggleState.on` / `.off` / `.partiallyAccepted` / `.partiallyRejected`.
    let state: String
    let onToggleChange: (Bool) -> Void
    var accessibilityName: String = ""
    /// Mirrors web CMP Toggle.jsx `isDisabled` prop: when true the toggle is
    /// non-interactive and rendered with reduced opacity. Defaults to false;
    /// T7 investigation found no concrete isDisabled=true usage on the web
    /// purposes screen, so this is infrastructure-only parity.
    var isDisabled: Bool = false

    @Environment(\.cmpResolvedTheme) private var theme
    /// FRONT-1335 volet 4 — `.offset(x:)` de SwiftUI est ABSOLU : il ne se miroite pas, à
    /// l'inverse de `Modifier.offset` côté Compose, dont le bytecode construit son
    /// `OffsetElement` avec `rtlAware = true`. Le pouce est donc le seul site du toggle qui
    /// demande un signe explicite ici — et Android n'en a pas besoin. C'est l'exact inverse du
    /// chevron, que SF Symbols miroite seul côté iOS et que Compose laisse en place côté
    /// Android : l'asymétrie est réelle, ne pas « harmoniser » les deux plateformes.
    ///
    /// Même famille que la règle web « une `transform` ne se miroite jamais, quel que soit le
    /// `dir` » (FRONT-1323), où le pouce du toggle change de signe explicitement sur trois
    /// règles CSS.
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.cmpToggleStateNames) private var stateNames

    private var isOn: Bool { state == ToggleState.on }
    /// Either form of mixity: both sit at the centre.
    private var isPartial: Bool { ToggleState.isPartial(state) }
    /// A consent is granted (accepted, or partially accepted) — the track axis.
    private var hasConsent: Bool { isOn || state == ToggleState.partiallyAccepted }

    var body: some View {
        // Tap gesture, NOT a Button. Inside a sheet + ScrollView, SwiftUI
        // Buttons intermittently swallow the SESSION'S FIRST tap (the sheet's
        // pan recognizer arbitrates controls differently from gestures) —
        // observed across CI runs as the first toggle tap reaching no code at
        // all ('tap 0' in the HUD) while onTapGesture-based expand headers
        // never missed a single tap. The historical reason for using a Button
        // here (gesture-arbitration freezes in the LazyVStack/re-layout era,
        // PR #104) is void since the structure/toggles split: taps recompute
        // ~1ms of toggle values and never re-lay-out rows.
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(trackColor)
                .frame(width: 51, height: 31)
            Circle()
                .fill(thumbColor)
                .frame(width: 27, height: 27)
                .shadow(color: .black.opacity(0.15), radius: 2, x: 0, y: 1)
                .overlay(glyph)
                .offset(x: (layoutDirection == .rightToLeft ? -1 : 1) * (isOn ? 10 : (isPartial ? 0 : -10)))
        }
        .contentShape(Rectangle())
        .opacity(isDisabled ? 0.5 : 1)
        .onTapGesture {
            guard !isDisabled else { return }
            onToggleChange(!isOn)
        }
        .accessibilityLabel(accessibilityName)
        // Free text, unlike the web's aria-checked (true / false / mixed only):
        // this is where the fourth state becomes audible.
        .accessibilityValue(stateNames.name(for: state))
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }

    /// Web parity (`toggle.module.less`): the track carries the consent axis —
    /// coloured for accepted AND partially accepted, neutral for rejected and
    /// partially rejected. Tinting on plain mixity — as this did before the two
    /// forms were told apart — read as "something is accepted" even when nothing
    /// was (a dual-basis purpose with consent OFF and legitimate interest not
    /// opposed grants no opt-in at all).
    private var trackColor: Color {
        hasConsent ? theme.main : Color.gray.opacity(0.3)
    }

    /// Web parity (`toggle.module.less` `.chip`): the theme's background colour,
    /// not a hardcoded white. The glyphs are drawn in `theme.text`, and
    /// background/text is the pair the publisher theme guarantees to contrast —
    /// white was only ever right for a light theme. Under a dark theme (light
    /// text) a white thumb swallowed the dash and the plus, leaving the rail
    /// colour as the only difference between the two partial states, which is
    /// exactly the colour-only distinction this design refuses (WCAG 1.4.1).
    private var thumbColor: Color {
        theme.background
    }

    /// State glyph carried by the thumb — ✕ / − / + / ✓, as `Toggle.jsx`
    /// `buildChipIcon`. The totals keep a saturated glyph (the ✕ keeps the web's
    /// salmon so refusal never reads as a neutral "nothing here", the ✓ the theme
    /// colour); the two partial glyphs are neutral, drawn in the text colour —
    /// full opacity, not the former 55 %, which weakened a 1.5 pt stroke's
    /// contrast for no benefit (WCAG 1.4.11).
    @ViewBuilder
    private var glyph: some View {
        if isOn {
            Image(systemName: "checkmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(theme.main)
        } else if state == ToggleState.partiallyAccepted {
            // Hand-drawn rather than SF Symbols' plus: the vertical stroke must
            // match the dash exactly, so the + reads as "the dash, one step up".
            ZStack {
                Capsule().fill(theme.text).frame(width: 9, height: 1.5)
                Capsule().fill(theme.text).frame(width: 1.5, height: 9)
            }
        } else if isPartial {
            Capsule()
                .fill(theme.text)
                .frame(width: 9, height: 1.5)
        } else {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(Color(hex: "#F67262", fallback: .red))
        }
    }
}

/// Button style used for CMP row taps (expand rows and the consent toggle).
///
/// It renders the label unchanged — no tint, no default fade — so the row/toggle
/// looks identical to the previous gesture-based implementation. Using a `Button`
/// with this style routes taps through SwiftUI's control system instead of the
/// gesture-arbitration graph, which eliminates the `highPriorityGesture` priority
/// conflicts that caused the expand freeze inside the scrolling `LazyVStack`.
struct CmpRowTapStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1.0)
    }
}
