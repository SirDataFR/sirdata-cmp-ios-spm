import Foundation

// MARK: - Purposes screen: STRUCTURE vs TOGGLES separation
//
// The screen is split into two independent states with disjoint update paths:
//
//  1. STRUCTURE (`PurposesScreenModel`, rows below): everything that is fixed
//     for the lifetime of the screen — row lists, names, descriptions,
//     partner lists, counts, intents. Built ONCE when the screen is entered
//     (`ConsentViewModel.navigateTo`) and NEVER rebuilt by a tap.
//  2. TOGGLES (`TogglesState`): the only thing a consent tap may change —
//     small `[String: String]` maps from a row/vendor key to "ON"/"OFF"/""
//     (mixed). Recomputed from the live selector snapshot after each tap and
//     published ONLY when a value actually changed.
//
// Expansion (`ConsentUiState.expandedIds`) is a third, purely visual state:
// an expand tap inserts/removes a key and nothing else.
//
// Views read structure as plain `let` data, look toggle values up in
// `TogglesState` by key, and read expansion from `expandedIds`. A view can
// therefore never observe a tap "rebuilding" the screen — by construction.

/// Summary of a vendor for display in the partner list under a purpose.
/// Static: the acceptance status ("Accepted"/"Not accepted"/…) is NOT stored
/// here — views look it up in `TogglesState.acceptance[stateKey]`.
struct VendorSummary: Identifiable, Equatable {
    var id: String { "\(name)_\(policyUrl ?? "")" }
    let name: String
    let iabBadge: String?
    let status: String?
    var policyUrl: String? = nil
    /// Key into `TogglesState.acceptance` for the live acceptance label
    /// (nil = no acceptance label shown, e.g. custom-purpose single vendor
    /// whose key is provided at build time).
    var stateKey: String? = nil
}

/// Wording used for the partner-count lines under a row.
///
/// Web parity: only `Feature.jsx` and `SpecialPurpose.jsx` use the neutral
/// `purposes.purposeVendorsWithCount` ("<count/> partners use this activity").
/// Every other row — purposes, Sirdata purposes, special features, custom
/// purposes, nested stack items — uses the consent / legitimate-interest
/// wording (`purposes.partnersConsentWithCount`, `purposes.partnersLIWithCount`).
enum VendorCountWording: Equatable {
    /// "For this activity, <count/> partners require your consent" / "… rely on
    /// their legitimate interest".
    case legalBasis
    /// "<count/> partners use this activity" — informational rows with no
    /// consent to give (features, special purposes).
    case activityUse
}

/// One row of the Purposes screen or one nested item inside a stack.
/// Pure structure: toggle VALUES live in `TogglesState`, keyed by `id`.
/// A nil intent means "this row has no such toggle".
struct PurposeRowModel: Identifiable, Equatable {
    /// Namespaced unique id — the expand key in `expandedIds` AND the toggle
    /// key in `TogglesState.row/.consent/.li/.standard`.
    let id: String
    let name: String
    let description: String
    var toggleIntent: ConsentIntent? = nil
    var hideMainToggle: Bool = false
    var hasStandardPurpose: Bool = false
    var labelKey: String = ""
    /// Whether the consent/LI sub-channels exist for this row (their live
    /// value lives in TogglesState; "" there also means absent).
    var consentToggleIntent: ConsentIntent? = nil
    var liToggleIntent: ConsentIntent? = nil
    var consentVendorCount: Int = 0
    var liVendorCount: Int = 0
    /// Wording of the partner-count lines (see `VendorCountWording`).
    var vendorCountWording: VendorCountWording = .legalBasis
    var consentVendors: [VendorSummary] = []
    var liVendors: [VendorSummary] = []
    var legalBasisLabel: String = ""
    var standardPurposeIsLI: Bool = false
    var standardPurposeToggleIntent: ConsentIntent? = nil
}

/// An expandable "activity" (stack) row. Toggle value: `TogglesState.row[id]`.
struct StackRowModel: Identifiable, Equatable {
    let id: String
    let name: String
    let description: String
    let toggleIntent: ConsentIntent
    var labelKey: String = ""
    var isSirdata: Bool = false
    var showDivider: Bool = true
    var nestedItems: [PurposeRowModel] = []
}

/// The fully-built, tap-immutable content of the Purposes screen.
struct PurposesScreenModel: Equatable {
    var publisherPurposeRows: [PurposeRowModel] = []
    var stackRows: [StackRowModel] = []
    var freePurposeRows: [PurposeRowModel] = []
    var specialFeatureRows: [PurposeRowModel] = []
    var supportRows: [PurposeRowModel] = []
    var specialPurposeRows: [PurposeRowModel] = []
    var featureRows: [PurposeRowModel] = []
    var showActivitiesHeader: Bool = false
}

// MARK: - Toggles state (the ONLY thing a consent tap updates)

/// Live toggle values, keyed by row id / vendor state-key. Small, Equatable,
/// recomputed in a few ms from the bridged selection sets; published only on
/// actual change. Values are the four `ToggleState` constants; `""` (or absent)
/// means "no such channel" for the sub-toggles — never "mixed", which has its
/// own two states since the two forms of mixity were told apart.
struct TogglesState: Equatable {
    /// Main (combined) toggle per row id — purposes, stacks, special features,
    /// publisher rows, nested stack items, partner rows (`partner_<id>`).
    var row: [String: String] = [:]
    /// Consent-only sub-toggle per row id ("" or absent = no consent basis).
    var consent: [String: String] = [:]
    /// LI-only sub-toggle per row id.
    var li: [String: String] = [:]
    /// Publisher standard-purpose overlay toggle per row id.
    var standard: [String: String] = [:]
    /// Acceptance labels per vendor/purpose state-key (see ToggleKey).
    var acceptance: [String: String] = [:]
}

/// Canonical state-key builders shared by the ViewModel (writer) and the
/// views (readers). One place, no string drift.
enum ToggleKey {
    /// TCF vendor acceptance under consent / LI.
    static func tcfVendor(_ id: Int) -> String { "t\(id)" }
    static func tcfVendorLI(_ id: Int) -> String { "tl\(id)" }
    /// Sirdata vendor acceptance under consent / LI.
    static func sirdataVendor(_ id: Int) -> String { "s\(id)" }
    static func sirdataVendorLI(_ id: Int) -> String { "sl\(id)" }
    /// Google provider acceptance (consent only).
    static func googleProvider(_ id: Int) -> String { "g\(id)" }
    /// TCF purpose status inside a partner's section (consent / LI wording).
    static func tcfPurposeStatus(_ id: Int) -> String { "pc\(id)" }
    static func tcfPurposeStatusLI(_ id: Int) -> String { "pl\(id)" }
    /// Special feature status inside a partner's consent section (opt-in).
    static func specialFeatureStatus(_ id: Int) -> String { "sfs\(id)" }
    /// Sirdata purpose status inside a partner's section.
    static func sirdataPurposeStatus(_ id: Int) -> String { "sc\(id)" }
    static func sirdataPurposeStatusLI(_ id: Int) -> String { "scl\(id)" }
    /// FRONT-1276 — the same purpose read under a GIVEN partner. A status must reflect the
    /// purpose AND the partner: the purpose-scoped keys above answer "was this purpose
    /// granted?", which showed « accepté » on a partner whose own bit was false. `owner` is
    /// the partner channel's key, so one entry exists per (purpose, channel of a partner).
    static func owned(_ base: String, _ owner: String) -> String { "\(base)#\(owner)" }
    /// Custom purpose acceptance (single-partner list on the purposes screen).
    static func customPurpose(_ id: Int) -> String { "cp\(id)" }
    /// Partner row (vendors screen) combined toggle key.
    static func partnerRow(_ partnerId: String) -> String { "partner_\(partnerId)" }
    /// Partner section toggle keys (vendors screen).
    static func partnerSection(_ partnerId: String, _ section: String) -> String { "\(partnerId).\(section)" }
}
