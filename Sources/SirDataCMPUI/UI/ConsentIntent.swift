import Foundation

/// A user interaction on the consent screens, carried as pure data.
///
/// Rows and toggles never compute a target value and never hold closures:
/// they emit one of these intents through a single `send` funnel and the
/// `ConsentViewModel` resolves the target from the LIVE selector/store state.
/// This is the iOS mirror of Android's intent-based `toggle*` contract
/// (ConsentViewModel.kt) and eliminates the "one action behind" class of bugs:
/// a stale rendered value can never be used to derive the next state.
///
/// Being `Equatable`/`Hashable` value data, intents can live inside row models
/// without breaking synthesized equality (unlike closures).
enum ConsentIntent: Equatable, Hashable {
    // ─── Purposes screen — main/per-basis toggles ───────────────────────
    case togglePurpose(Int32)
    case togglePurposeConsent(Int32)
    case togglePurposeLI(Int32)
    case toggleSirdataPurpose(Int32)
    case toggleSirdataPurposeConsent(Int32)
    case toggleSirdataPurposeLI(Int32)
    case toggleSpecialFeature(Int32)
    case toggleTcfStack(Int32)
    case toggleSirdataStack(Int32)
    case toggleStandardPurpose(Int32)
    case toggleCustomPurpose(Int32)
    /// Value-based selection — used only by the PURPOSE_ONE "accept cookies"
    /// footer, which explicitly sets purpose 1 = true (web parity).
    case selectPurpose(Int32, Bool)

    // ─── Vendors screen — combined and per-basis toggles ────────────────
    case toggleVendor(Int32)
    case toggleVendorConsent(Int32)
    case toggleVendorLI(Int32)
    case toggleSirdataVendor(Int32)
    case toggleSirdataVendorConsent(Int32)
    case toggleSirdataVendorLI(Int32)
    case toggleACProvider(Int32)

    // ─── Expansion (pure UI state) ──────────────────────────────────────
    /// Toggles the expanded state of the row/zone identified by `key` in
    /// `ConsentUiState.expandedIds`. Routed through the ViewModel so the
    /// rendered screen has exactly ONE state input (`uiState`) — no view-local
    /// expand state that a container could drop or desynchronize.
    case toggleExpand(String)
}
