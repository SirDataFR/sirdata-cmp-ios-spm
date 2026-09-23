import SwiftUI
import SirDataCMP

/// Theme ViewModifier that reads CMP config colors and applies them.
/// (Optional `Theme?`: the Kotlin data class has no no-arg init exported
/// to Swift, so callers pass the config theme or nil for defaults.)
struct CmpTheme: ViewModifier {
    let theme: Theme?
    @Environment(\.colorScheme) var colorScheme

    func body(content: Content) -> some View {
        let resolved = ResolvedTheme(theme: theme, colorScheme: colorScheme)
        return content
            .cmpTint(resolved.main)
            // Publish the resolved theme so every nested component reads the
            // same colors / radius / text scale (mirrors Android's
            // CompositionLocalProvider in CmpTheme.kt).
            .environment(\.cmpResolvedTheme, resolved)
    }
}

extension View {
    func cmpTheme(_ theme: Theme?) -> some View {
        modifier(CmpTheme(theme: theme))
    }
}

// MARK: - Environment plumbing

private struct CmpResolvedThemeKey: EnvironmentKey {
    // Default value used before the config loads (and in previews).
    static let defaultValue = ResolvedTheme(theme: nil, colorScheme: .light)
}

extension EnvironmentValues {
    var cmpResolvedTheme: ResolvedTheme {
        get { self[CmpResolvedThemeKey.self] }
        set { self[CmpResolvedThemeKey.self] = newValue }
    }
}

// MARK: - Resolved theme

/// Swift mirror of Android's `SirDataColors` + `CmpTheme` composition locals.
///
/// Resolves the CMP config `Theme` (lightMode/darkMode hex strings + enums)
/// into SwiftUI values once, so every screen and component reads consistent
/// colors, corner radius, text scaling and layout flags. When no config is
/// loaded (`theme == nil`) it falls back to the built-in defaults, matching
/// the Kotlin `Theme()`/`ThemeMode()` defaults.
struct ResolvedTheme {
    // Colors
    let background: Color
    let main: Color
    /// Foreground color that contrasts with `main` (button label color).
    let onMain: Color
    let title: Color
    let text: Color
    let border: Color
    let overlay: Color

    // Layout / typography
    let cornerRadius: CGFloat
    let textScale: CGFloat
    let position: ThemePosition
    let whiteLabel: Bool
    let closeButton: Bool
    let overlayEnabled: Bool

    // No-consent / set-choices button configuration
    let noConsentButton: ThemeNoConsentButton
    let noConsentButtonStyle: ThemeNoConsentButtonStyle
    let setChoicesStyle: ThemeSetChoicesStyle

    // Raw resolved mode values (for logo / watermark data URIs)
    let logoRaw: String
    let watermarkRaw: String

    init(theme: Theme?, colorScheme: ColorScheme) {
        let isDark = colorScheme == .dark
        guard let theme else {
            // Built-in defaults — mirror Kotlin Theme()/ThemeMode() defaults.
            background = Color(hex: "#FFFFFF", fallback: Color(.systemBackground))
            main = Color(hex: "#2563EB", fallback: .blue)
            onMain = .white
            title = Color(hex: "#111827", fallback: .primary)
            text = Color(hex: "#374151", fallback: .secondary)
            border = Color(hex: "#E5E7EB", fallback: Color(.separator))
            overlay = Color.black.opacity(0.5)
            cornerRadius = 12 // Kotlin Theme() default = ThemeBorderRadius.AVERAGE
            textScale = 1.0
            position = .bottom
            whiteLabel = false
            closeButton = false
            overlayEnabled = false
            noConsentButton = .reject
            noConsentButtonStyle = .buttonBigDefault
            setChoicesStyle = .button
            logoRaw = ""
            watermarkRaw = ""
            return
        }

        let mode = ResolvedTheme.resolveMode(theme, isDark: isDark)
        background = Color(hex: mode.backgroundColor, fallback: Color(.systemBackground))
        let mainColor = Color(hex: mode.mainColor, fallback: .blue)
        main = mainColor
        onMain = ResolvedTheme.contrastOn(mainColor)
        title = Color(hex: mode.titleColor, fallback: .primary)
        text = Color(hex: mode.textColor, fallback: .secondary)
        border = Color(hex: mode.borderColor, fallback: Color(.separator))
        overlay = Color(hex: mode.overlayColor, fallback: Color.black.opacity(0.5))
        logoRaw = mode.logo
        watermarkRaw = mode.watermark

        // Kotlin enums export as classes — compare with `==` on case instances.
        // Scale = web's borderRadiusMap (App.jsx:60-65), the CSS `--border-radius`
        // every other radius derives from: containers take it as-is, buttons take
        // half of it (buttons.less `.btnContent`).
        let radius = theme.borderRadius
        if radius == ThemeBorderRadius.none { cornerRadius = 0 }
        else if radius == ThemeBorderRadius.light { cornerRadius = 4 }
        else if radius == ThemeBorderRadius.strong { cornerRadius = 24 }
        else { cornerRadius = 12 } // average / default

        let size = theme.textSize
        if size == ThemeTextSize.small { textScale = 0.85 }
        else if size == ThemeTextSize.big { textScale = 1.15 }
        else { textScale = 1.0 } // medium / default

        position = theme.position
        whiteLabel = theme.whiteLabel
        closeButton = theme.closeButton
        overlayEnabled = theme.overlay
        noConsentButton = theme.noConsentButton
        noConsentButtonStyle = theme.noConsentButtonStyle
        setChoicesStyle = theme.setChoicesStyle
    }

    /// Decoded publisher logo (raster data URI) for the active mode, or nil.
    var logoImage: UIImage? { decodeDataUriImage(logoRaw) }

    /// Decoded watermark image (raster data URI) for the active mode, or nil.
    var watermarkImage: UIImage? { decodeDataUriImage(watermarkRaw) }

    // MARK: - Mode resolution (mirrors SirDataColors.resolveThemeMode)

    /// Picks light vs dark mode. The API sends `darkMode: {}` (all defaults)
    /// when no dark theme is configured; in that case we fall back to light
    /// mode rather than silently overriding the publisher branding — matching
    /// the Android/web CMP behavior. Since `ThemeMode()` cannot be constructed
    /// in Swift (no-arg init not exported), we detect "all defaults" by
    /// comparing the documented Kotlin default values.
    static func resolveMode(_ theme: Theme, isDark: Bool) -> ThemeMode {
        if !isDark { return theme.lightMode }
        let d = theme.darkMode
        let isDefault = d.backgroundColor == "#FFFFFF"
            && d.mainColor == "#2563EB"
            && d.titleColor == "#111827"
            && d.textColor == "#374151"
            && d.borderColor == "#E5E7EB"
            && d.overlayColor == "#00000080"
            && d.logo.isEmpty
            && d.watermark.isEmpty
        return isDefault ? theme.lightMode : d
    }

    // MARK: - WCAG contrast (mirrors SirDataColors.contrastOn)

    /// Returns white or black depending on which contrasts better with the
    /// given color, per WCAG 2.0 relative luminance.
    static func contrastOn(_ color: Color) -> Color {
        let comps = color.rgbComponents()
        func linearize(_ c: Double) -> Double {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let l = 0.2126 * linearize(comps.r) + 0.7152 * linearize(comps.g) + 0.0722 * linearize(comps.b)
        let whiteContrast = 1.05 / (l + 0.05)
        let blackContrast = (l + 0.05) / 0.05
        return whiteContrast > blackContrast ? .white : .black
    }
}

// MARK: - Data-URI logo decoding

/// Decodes a CMP config logo/watermark of the form
/// `url(data:image/png;base64,...)` into a UIImage. Mirrors Android's
/// DataUriDecoder.
///
/// Note: only raster formats (PNG/JPEG/WebP) are decoded. SVG payloads
/// (`data:image/svg+xml;...`) return nil — UIKit has no built-in SVG
/// rasterizer (Android uses AndroidSVG). Callers render nothing in that case,
/// matching the graceful-absence behavior of the Android components.
func decodeDataUriImage(_ raw: String?) -> UIImage? {
    guard let raw, !raw.isEmpty,
          raw.contains("data:image/"),
          let start = raw.range(of: "base64,")?.upperBound else { return nil }
    var b64 = String(raw[start...])
    b64 = b64.trimmingCharacters(in: CharacterSet(charactersIn: "\"' )"))
    guard let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else { return nil }
    return UIImage(data: data)
}

// MARK: - Color helpers

extension Color {
    /// Hex color with explicit fallback when the config value is empty.
    init(hex: String, fallback: Color) {
        if hex.trimmingCharacters(in: .whitespaces).isEmpty {
            self = fallback
        } else {
            self.init(hex: hex)
        }
    }

    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 6: (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            // Kotlin hex strings are #AARRGGBB (alpha first), e.g. "#00000080".
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default: (a, r, g, b) = (255, 0, 122, 255)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }

    /// Extracts sRGB components (0...1) for luminance math.
    func rgbComponents() -> (r: Double, g: Double, b: Double, a: Double) {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b), Double(a))
    }
}

// MARK: - Toggle state constants (mirror ConsentSelector.TOGGLE_STATE_*)

enum ToggleState {
    static let on = "ON"
    static let off = "OFF"
    /// Mixed, with at least one consent granted beneath the row.
    static let partiallyAccepted = "PARTIALLY_ACCEPTED"
    /// Mixed, granting no consent at all.
    static let partiallyRejected = "PARTIALLY_REJECTED"

    /// True for either form of mixity — the two states that share the centred thumb.
    static func isPartial(_ state: String) -> Bool {
        state == partiallyAccepted || state == partiallyRejected
    }
}
// There is deliberately no `mixed` constant any more: `""` now means one thing
// only — "this channel does not exist" — as returned by the per-channel state
// queries (purposeConsentState, purposeLIState…), which the rows test with
// `isEmpty` to decide whether to draw a toggle at all.

// MARK: - Toggle state names (accessible value)

/// The four toggle states' localized names.
///
/// `aria-checked`'s mobile equivalents take free text, which is the only reason
/// the fourth state can be expressed for assistive technologies at all: on the
/// web both partial states report `aria-checked="mixed"` and the difference
/// lives in the accessible name (`title` in `Toggle.jsx`). Same here, through
/// `accessibilityValue`.
///
/// Published through the environment so the ~10 `ConsentToggle` call sites need
/// no extra argument. Defaults are English and only cover previews: the real
/// values come from `Localize`, itself falling back to `Localize.FALLBACK_TEXTS`.
struct ToggleStateNames {
    var rejected = "Rejected"
    var partiallyRejected = "Partially rejected"
    var partiallyAccepted = "Partially accepted"
    var accepted = "Accepted"

    func name(for state: String) -> String {
        switch state {
        case ToggleState.on: return accepted
        case ToggleState.off: return rejected
        case ToggleState.partiallyAccepted: return partiallyAccepted
        default: return partiallyRejected
        }
    }

    /// Reads the four texts from the CMP locales. Called once per structure
    /// rebuild (never per render), so it costs four bridged calls in total.
    static func localized(_ localize: Localize) -> ToggleStateNames {
        let defaults = ToggleStateNames()
        // A missing key resolves to an empty string; an empty accessible value
        // would be worse than English, so keep the default in that case.
        func text(_ key: String, or fallback: String) -> String {
            let value = localize.getText(key: key)
            return value.isEmpty ? fallback : value
        }
        // The two newest keys are named as literals, not through `LocaleKey`, and
        // this is the ONLY place that spells them out. `Package.swift` points SPM
        // and CocoaPods consumers at the checked-in `SirDataCMP.xcframework`,
        // which predates them (#185) and is regenerated only at release
        // (docs/RELEASING.md step 1). `LocaleKey.partiallyRejected` would break
        // every integrator with "type 'LocaleKey' has no member …" — a failure no
        // CI here can surface, since testflight.yml rebuilds the framework before
        // compiling. Values are exactly LocaleKey.PARTIALLY_{REJECTED,ACCEPTED}
        // .key; route both back through `LocaleKey` once the binary ships them.
        return ToggleStateNames(
            rejected: text(LocaleKey.rejected.key, or: defaults.rejected),
            partiallyRejected: text("partiallyRejected", or: defaults.partiallyRejected),
            partiallyAccepted: text("partiallyAccepted", or: defaults.partiallyAccepted),
            accepted: text(LocaleKey.accepted.key, or: defaults.accepted)
        )
    }
}

private struct CmpToggleStateNamesKey: EnvironmentKey {
    static let defaultValue = ToggleStateNames()
}

extension EnvironmentValues {
    var cmpToggleStateNames: ToggleStateNames {
        get { self[CmpToggleStateNamesKey.self] }
        set { self[CmpToggleStateNamesKey.self] = newValue }
    }
}
