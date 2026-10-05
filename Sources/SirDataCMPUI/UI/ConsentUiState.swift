import Foundation
import SirDataCMP

/// Reactive UI state for the consent management screen.
///
/// Mapped from `ConsentStore` data and `ConsentSelector` toggle states.
/// The `ConsentViewModel` rebuilds this on every store update.
///
/// This is the iOS mirror of Android's
/// `com.sirdata.cmp.android.ui.ConsentUiState`. Field order matters: the
/// ViewModel uses the memberwise initializer, so new fields must be appended
/// at the end with a default value.
struct ConsentUiState {
    // TCF data
    var purposes: [TcfPurpose] = []
    var specialFeatures: [TcfPurpose] = []
    var vendors: [TcfVendor] = []
    var stacks: [TcfStack] = []

    // Sirdata data
    var sirdataPurposes: [SirdataListPurpose] = []
    var sirdataVendors: [SirdataListVendor] = []
    var sirdataStacks: [SirdataListStack] = []

    // Google AC providers
    var googleProviders: [GoogleProvider] = []

    // Navigation
    var currentScreen: ConsentScreen = .main
    /// Active CMP workflow (main on first display, cookiewallModify in cookie wall context, applyChoices on re-display).
    var workflow: Workflow = .main
    var disableTcf: Bool = false

    // Loading state
    var isLoading: Bool = true
    var error: String? = nil

    // Consent strings
    var tcString: String = ""
    var gdprApplies: Bool = false

    // NOTE: live toggle VALUES do not live here. They are published separately
    // as `ConsentViewModel.toggles` (TogglesState) so a consent tap updates
    // toggles and NOTHING else — this struct only changes on screen entry,
    // load, navigation or expansion. See PurposesScreenModel.swift.

    // Texts
    var title: String = ""
    var description: String = ""
    /** Custom publisher description from CMP config (optional, rendered above text blocks). */
    var customDescription: String = ""
    /** Processed main banner text block 1 (from locale key "text1"). */
    var text1: String = ""
    /** Processed main banner text block 2 (from locale key "text2"). */
    var text2: String = ""
    /** Processed main banner text block 3 (from locale key "text3"). */
    var text3: String = ""
    /** Structured segments for text block 1, carrying clickable link types. */
    var text1Segments: [(text: String, linkType: String?)] = []
    /** Structured segments for text block 2, carrying clickable link types. */
    var text2Segments: [(text: String, linkType: String?)] = []
    /** Structured segments for text block 3, carrying clickable link types. */
    var text3Segments: [(text: String, linkType: String?)] = []

    // Informational only (no toggle): shown in the "support" section.
    var specialPurposes: [TcfPurpose] = []
    var features: [TcfPurpose] = []

    // Publisher standard & custom purposes (consent/LI toggle by legal basis).
    // Mirrors Android's ConsentUiState.standardPurposes / customPurposes.
    var standardPurposes: [PublisherStandardPurpose] = []
    var customPurposes: [PublisherCustomPurpose] = []

    /// Publisher privacy policy URL from the CMP config (empty when not set).
    var privacyPolicyUrl: String = ""
    /// Locale key for the scope reminder text on the partners screen (vendors.scope.*).
    var scopeReminderKey: String = "vendors.scope.local"
    /// FRONT-1409 — the scope reminder as link segments: `<hostnames>` (GROUP) and
    /// `<websites>` (PROVIDER) each open their own target, as on the web.
    var scopeReminderSegments: [(text: String, linkType: String?)] = []

    /// Hostnames the CMP scope applies to (from config.context.hostnames). Shown in the hostnames modal.
    var hostnames: [String] = []
    /// True when Utiq integration is active (config.cmp.external.utiq.active). Enables the Utiq modal.
    var utiqActive: Bool = false
    /// Utiq notice URL (config.cmp.external.utiq.noticeUrl), linked from the Utiq modal.
    var utiqNoticeUrl: String = ""

    /// True when the CNIL variant applies (config.context.isVariantApplies(VARIANT_CNIL)).
    /// When true, closing the main banner saves consent instead of dismissing without action
    /// (mirrors web CMP handleClose behavior).
    var isCnilVariant: Bool = false
    /// True when the vendor list display mode is EXPANDED (config.cmp.vendorList.displayMode).
    /// When true, stacks are not grouped: all stack purposes are shown at the root level
    /// (mirrors web CMP VendorListDisplayMode.EXPANDED). Default CONDENSED groups purposes in stacks.
    var expandedDisplayMode: Bool = false

    /// True when any legitimate interest purpose exists (TCF or Sirdata).
    /// Determined in ConsentViewModel.refreshUiState() and used by
    /// processConditionalTags() to resolve <legitimateInterest> blocks.
    var hasLegitimateInterest: Bool = false
    /// True when publisher custom purposes are present.
    /// Determined in ConsentViewModel.refreshUiState() and used by
    /// processConditionalTags() to resolve <customPurposes> blocks.
    var hasCustomPurposes: Bool = false
    /// True when Sirdata purpose 5 (Utiq) is in the available set.
    /// Determined in ConsentViewModel.refreshUiState() and used by
    /// processConditionalTags() to resolve <utiq> blocks.
    var hasUtiq: Bool = false
    /// Set of TCF purpose IDs that carry a Consent legal basis
    /// (for rendering legal basis labels in stack nested items).
    var purposeConsentIds: Set<Int> = []
    /// Set of TCF purpose IDs that carry a Legitimate Interest legal basis
    /// (for rendering legal basis labels in stack nested items).
    var purposeLIIds: Set<Int> = []
    /// Set of Sirdata purpose IDs that carry a Consent legal basis.
    var sirdataPurposeConsentIds: Set<Int> = []
    /// Set of Sirdata purpose IDs that carry a Legitimate Interest legal basis.
    var sirdataPurposeLIIds: Set<Int> = []

    // ─── Description Pipeline Params ──────────────────────────────────────
    // These fields provide the context needed to run the placeholder pipeline
    // (processConditionalTags → buildText → processConditionalTags →
    // processClassnameTags) on purpose/stack/vendor descriptions, not just
    // banner text. Populated in ConsentViewModel.refreshUiState().

    /// Total partner count (deduplicated, publisher-configured vendors only).
    var partnerCount: Int = 0
    /// Locale key for the scope text (e.g. "scope.local", "scope.domain").
    var scopeTextKey: String = "scope.local"
    /// Locale key for the consent storage mention (FRONT-1286).
    ///
    /// En portée APP c'est `consentStorage.app` : il n'y a pas de cookie dans une app.
    /// Décidé par le ViewModel et non lu dans la vue, comme le reste de la structure —
    /// une vue qui interroge `cmp.config` repose la question à chaque rendu.
    var consentStorageKey: String = "consentStorage"
    /// Cookie max age in days from config (for <maxAge/> placeholder).
    var maxAgeDays: Int = 0
    /// True when geolocation special feature is active (for <location/>).
    var hasGeolocation: Bool = false
    /// Data controller name from config.cmp.external.utiq.controller (for <dataController/>).
    var dataController: String = ""
    /// Cookie duration in seconds (for <duration/> placeholder).
    var cookieDurationSeconds: Int = 0
    /// Sirdata stack IDs from config (for <sirdataStack:N> conditional tags).
    var sirdataStackIds: Set<Int> = []
    /// Set of all available TCF purpose IDs (consent + LI).
    var availablePurposeIds: Set<Int> = []
    /// Set of all available Sirdata purpose IDs (consent + LI).
    var availableSirdataPurposeIds: Set<Int> = []
    /// Set of all available special feature IDs.
    var availableSpecialFeatureIds: Set<Int> = []
    /// Theme setChoicesStyle (determines whether <purposes> tags are clickable).
    var choicesStyle: ThemeSetChoicesStyle = .button
    /// No-consent button config string ("REJECT", "CONTINUE", or "").
    var noConsentButton: String = ""
    /// Close button enabled from theme config.
    var closeButton: Bool = false
    /// Custom purpose names (for <purposes/> placeholder).
    var customPurposeNames: [String] = []
    /// Raw purpose name maps built from unfiltered vendorList data (all purposes).
    /// Used by tcfPurposeName()/sirdataPurposeName() helpers so nested stack
    /// purposes always resolve even when excluded from the filtered uiState.purposes list.
    var tcfPurposeNameMap: [Int: String] = [:]
    var sirdataPurposeNameMap: [Int: String] = [:]
    var tcfDataCategoryNameMap: [Int: String] = [:]
    /// Pre-computed Sirdata purpose IDs that belong to a Sirdata stack.
    /// Used to filter these purposes out of the free purposes list (dedup).
    var stackSirdataPurposeIds: Set<Int> = []
    /// Google TCF purposes from configuration (GoogleProviderList.purposes).
    /// Replaces hardcoded [1, 3, 4] (T-V15).
    var googlePurposes: [Int] = []
    /// True when white-label mode is active (config.cmp.theme.whiteLabel).
    /// When true, the SirData watermark is hidden (web parity: ProviderLogo).
    var whiteLabel: Bool = false
    /// Fully-derived Purposes screen content (rows, stacks, sections), built
    /// once per consent state change in `ConsentViewModel.refreshUiState()`.
    /// The view renders this verbatim — no filtering or caching in `body`.
    var purposesScreen: PurposesScreenModel = PurposesScreenModel()

    /// Expanded row/zone keys across ALL consent screens (purposes rows, stack
    /// nested items, vendor lists, partner rows). Owned here — not as view
    /// `@State` — so the rendered screen has a single state input and lazy
    /// containers can never drop or desynchronize expansion. Mutated only via
    /// `ConsentIntent.toggleExpand` and carried over by `refreshUiState()`.
    var expandedIds: Set<String> = []

    /// R6: Pre-computed partner entries (data-only, no closures).
    /// Built in `ConsentViewModel.refreshUiState()` so VendorsView doesn't
    /// rebuild ~175 PartnerEntry objects on every body evaluation.
    /// The View converts these to PartnerEntry with closures attached at render time.
    /// Mirrors Android's `partnerEntries` in ConsentUiState.
    var partnerEntries: [PartnerEntryData] = []

    /// FRONT-1342 — l'écran US « Privacy Choices », ou `nil` hors juridiction US.
    ///
    /// Pure STRUCTURE : les libellés sont résolus une fois par `buildUsNatData()`, jamais
    /// dans un `body`. Un `nil` route vers la cascade TCF habituelle — cf. `screenContent`.
    var usNat: UsNatScreenData?
}


/// L'écran US « Privacy Choices », prêt à peindre.
///
/// Miroir du porteur `@Immutable` d'Android (`UsNatScreenData`), et pour la même raison de
/// fond : **la vue ne dérive rien**. Les onze libellés et la liste d'États sortent de la
/// règle PARTAGÉE (`UsNatScreen.build`) puis d'autant d'appels à `getUsNatText` — tous
/// bridgés vers Kotlin, donc à payer une fois par reconstruction de structure et jamais par
/// rendu (cf. « Interop Kotlin/Native coûteuse » dans le CLAUDE.md).
struct UsNatScreenData {
    var title: String = ""
    var subtitle: String = ""
    /// Vide quand aucune opposition n'est offerte : la notice reste, le contrôle disparaît.
    var intro: String = ""
    var states: String = ""
    /// « Use the control below to opt out. » — n'a de sens qu'au-dessus d'un contrôle.
    var para: String = ""
    var toggleLabel: String = ""
    var more: String = ""
    var saveLabel: String = ""
    var statesTitle: String = ""
    /// Libellé accessible des deux boutons de fermeture, lu depuis le jeu **US**.
    ///
    /// `buttons.close` existe dans les DEUX jeux de libellés : c'est celui du fichier CCPA
    /// qu'il faut, sinon les deux cartes se contrediraient le jour où une traduction les fait
    /// diverger. Les autres écrans lisent `LocaleKey.buttonsClose` dans le jeu du RGPD — c'est
    /// correct pour eux, et hors périmètre ici.
    var closeLabel: String = ""
    var coveredStates: [String] = []
    var anyOffered: Bool = false
    var showsSave: Bool = false
    var showsPara: Bool = false
    var optedOut: Bool = false
}

/// One consent channel (consent / LI / non-TCF consent / non-TCF LI) inside a
/// partner's expanded detail. Pure STRUCTURE: the live toggle value is looked
/// up in `TogglesState.row[stateKey]` by the view — a consent tap never
/// rebuilds this. Mirrors Android's `VendorPurposeSectionData`.
struct VendorPurposeSectionData {
    let label: String
    /// Key into `TogglesState.row` for this section's live toggle value.
    let stateKey: String
    let purposes: [VendorPurposeItem]
    var showToggle: Bool = true
    var vendorName: String? = nil
    var vendorPolicyUrl: String? = nil
    /// Intent emitted by this section's toggle (nil when showToggle is false).
    var toggleIntent: ConsentIntent? = nil
}

/// One row of the partners list. Pure STRUCTURE (built on screen entry):
/// the combined toggle's live value is `TogglesState.row[ToggleKey.partnerRow(id)]`.
/// Mirrors Android's `PartnerEntryData`.
struct PartnerEntryData: Identifiable {
    let id: String
    let name: String
    let policyUrl: String
    let isIabTcf: Bool
    let consentSection: VendorPurposeSectionData?
    let liSection: VendorPurposeSectionData?
    let nonTcConsentSection: VendorPurposeSectionData?
    let nonTcLISection: VendorPurposeSectionData?
    let specialPurposesSection: VendorInfoSection?
    let dataCategoriesSection: VendorInfoSection?
    let storageDisclosure: VendorStorageDisclosure?
    var spOnly: Bool = false
    var legIntClaimUrl: String? = nil
    var legIntClaimLabel: String = ""
    /// Intent emitted by the combined (whole-partner) toggle.
    var combinedIntent: ConsentIntent? = nil
}

/// Immutable static data computed once at load time (and on language/config change).
/// Contains lists, texts, config, and name maps that don't change on toggle.
struct ConsentStaticData {
    // TCF data lists
    var purposes: [TcfPurpose] = []
    var specialFeatures: [TcfPurpose] = []
    var vendors: [TcfVendor] = []
    var stacks: [TcfStack] = []
    // Sirdata data lists
    var sirdataPurposes: [SirdataListPurpose] = []
    var sirdataVendors: [SirdataListVendor] = []
    var sirdataStacks: [SirdataListStack] = []
    // Google AC providers
    var googleProviders: [GoogleProvider] = []
    var googlePurposes: [Int] = []
    // Informational only
    var specialPurposes: [TcfPurpose] = []
    var features: [TcfPurpose] = []
    // Publisher purposes
    var standardPurposes: [PublisherStandardPurpose] = []
    var customPurposes: [PublisherCustomPurpose] = []
    // Texts
    var title: String = ""
    var description: String = ""
    var customDescription: String = ""
    var text1: String = ""
    var text2: String = ""
    var text3: String = ""
    var text1Segments: [(text: String, linkType: String?)] = []
    var text2Segments: [(text: String, linkType: String?)] = []
    var text3Segments: [(text: String, linkType: String?)] = []
    // Name maps
    var tcfPurposeNameMap: [Int: String] = [:]
    var sirdataPurposeNameMap: [Int: String] = [:]
    var tcfDataCategoryNameMap: [Int: String] = [:]
    var tcfDataCategoryDescriptionMap: [Int: String] = [:]
    // Config
    var scopeTextKey: String = "scope.local"
    var consentStorageKey: String = "consentStorage"
    var maxAgeDays: Int = 0
    var hasLegitimateInterest: Bool = false
    var hasCustomPurposes: Bool = false
    var hasUtiq: Bool = false
    var hasGeolocation: Bool = false
    var dataController: String = ""
    var cookieDurationSeconds: Int = 0
    var sirdataStackIds: Set<Int> = []
    var availablePurposeIds: Set<Int> = []
    var availableSirdataPurposeIds: Set<Int> = []
    var availableSpecialFeatureIds: Set<Int> = []
    var choicesStyle: ThemeSetChoicesStyle = .button
    var noConsentButton: String = ""
    var closeButton: Bool = false
    var customPurposeNames: [String] = []
    var whiteLabel: Bool = false
    var disableTcf: Bool = false
    var privacyPolicyUrl: String = ""
    var scopeReminderKey: String = "vendors.scope.local"
    /// FRONT-1409 — the scope reminder as link segments: `<hostnames>` (GROUP) and
    /// `<websites>` (PROVIDER) each open their own target, as on the web.
    var scopeReminderSegments: [(text: String, linkType: String?)] = []
    var hostnames: [String] = []
    var utiqActive: Bool = false
    var utiqNoticeUrl: String = ""
    var isCnilVariant: Bool = false
    var expandedDisplayMode: Bool = false
    var partnerCount: Int = 0
    var stackSirdataPurposeIds: Set<Int> = []
    var purposeConsentIds: Set<Int> = []
    var purposeLIIds: Set<Int> = []
    var sirdataPurposeConsentIds: Set<Int> = []
    var sirdataPurposeLIIds: Set<Int> = []
    // Workflow snapshot for cache invalidation (texts depend on workflow)
    var workflow: Workflow = .main
    /// Pure Swift snapshot of the Kotlin lists — built once at load so the
    /// per-tap derivation never crosses the Kotlin/Native bridge (the measured
    /// ~100-190ms main-thread stall per refresh). See ConsentSnapshot.swift.
    var snap: ConsentSnapshot = ConsentSnapshot()
}
