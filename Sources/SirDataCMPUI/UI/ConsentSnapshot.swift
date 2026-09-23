import Foundation
import SirDataCMP

// MARK: - Pure Swift snapshot of the Kotlin vendor-list data
//
// Built ONCE at load time (ConsentViewModel.buildStaticData). The per-tap
// state derivation then never crosses the Kotlin/Native bridge: reading every
// vendor/name/set through the ObjC interop cost ~100-190 ms per refresh pass
// even on a Mac simulator (thousands of calls per pass, twice per tap) — a
// main-thread stall that swallowed subsequent taps and produced the reported
// "row doesn't expand / one action behind" feel on device. With this snapshot
// a refresh only bridges ~14 small selection sets.
//
// The selection-state logic is ported 1:1 from the shared selector
// (ConsentSelector.kt, "Toggle state queries" region) — the Kotlin function
// name is cited on each function (line numbers were dropped: they went stale
// the first time the Kotlin file grew). The selector remains the single WRITE
// path; only the read/derivation side is mirrored here.

struct SnapLinkedSirdata: Equatable {
    let id: Int
    let hasExtraPurposes: Bool
    let hasLegIntExtraPurposes: Bool
    /// FRONT-1276: a fused partner exposes its STANDARD purposes too, and the carrier row
    /// renders them. Gating the aggregation on the extras alone left a standard-only partner
    /// with a channel displayed but never counted.
    let hasPurposes: Bool
    let hasLegIntPurposes: Bool

    /// Does this partner expose a consent channel at all — through either list?
    var hasConsentChannel: Bool { hasPurposes || hasExtraPurposes }
    /// Same question for legitimate interest.
    var hasLIChannel: Bool { hasLegIntPurposes || hasLegIntExtraPurposes }
}

/// One TCF vendor, with every field the UI derivation reads.
struct SnapTcfVendor {
    let id: Int
    let name: String
    let nameLower: String
    let policyUrl: String?
    /// Cleaned display sets (VendorListProcessor.filteredPurposes / LegInt).
    let filteredPurposesList: [Int]
    let filteredPurposes: Set<Int>
    let filteredLegIntPurposesList: [Int]
    let filteredLegIntPurposes: Set<Int>
    let specialFeatures: Set<Int>
    let specialPurposes: [Int]
    let features: [Int]
    let dataDeclaration: [Int]
    /// ConsentSelector.getVendorState eligibility (FILTERED purpose sets ∩ display lists).
    let combinedConsentEligible: Bool
    let combinedLIEligible: Bool
    let linkedSirdata: SnapLinkedSirdata?
    /// Per-channel presence (mirrors refreshUiState's hasConsent/hasLI).
    let hasConsentChannel: Bool
    let hasLIChannel: Bool
    // Partner-detail data (buildPartnerEntries)
    let spOnly: Bool
    let legIntClaim: String?
    let retentionPurposes: [Int: Int]
    let retentionSpecialPurposes: [Int: Int]
    let usesCookies: Bool
    let cookieMaxAgeSeconds: Int
    let cookieRefresh: Bool
    let usesNonCookieAccess: Bool
    let deviceStorageDisclosureUrl: String?

    /// FRONT-1317 — l'écran a-t-il une décision à proposer pour ce partenaire ?
    ///
    /// Miroir de `ConsentSelector.hasDecidableChannel`. Il n'y a rien à calculer : les deux
    /// drapeaux d'éligibilité portent DÉJÀ l'intersection avec les listes affichées, ce qui est
    /// exactement la question. Écrit en Swift plutôt qu'appelé côté Kotlin pour deux raisons —
    /// l'interop dans une boucle de dérivation coûte cher (cf. « Interop Kotlin/Native » du
    /// CLAUDE.md), et un symbole Kotlin ajouté dans cette PR ne serait pas dans le binaire
    /// committé, donc aucun client SPM ne compilerait (règle FRONT-1274).
    ///
    /// `spOnly` ne répond PAS à cette question : il compte les fonctionnalités spéciales telles
    /// que le vendor les DÉCLARE, sans les intersecter avec la liste affichée. C'est ce qui a
    /// laissé passer un toggle au-dessus de blocs vides.
    var hasDecidableChannel: Bool { combinedConsentEligible || combinedLIEligible }
}

struct SnapSirdataVendor {
    let id: Int
    let name: String
    let nameLower: String
    let policyUrl: String?
    let purposesList: [Int]
    let purposes: Set<Int>
    let extraPurposesList: [Int]
    let extraPurposes: Set<Int>
    let legIntPurposesList: [Int]
    let legIntPurposes: Set<Int>
    let legIntExtraPurposesList: [Int]
    let legIntExtraPurposes: Set<Int>
    let tcfVendorId: Int?
    let googleProviderId: Int?
    /// ConsentSelector.getSirdataVendorState eligibility.
    let combinedConsentEligible: Bool
    let combinedLIEligible: Bool
    /// Per-basis, not mere existence: `selectVendorConsent` writes the consent set
    /// even for an LI-only vendor, so a stale id must not count as a granted opt-in.
    let linkedTcfConsentEligible: Bool
    let linkedTcfLIEligible: Bool
    /// Mere presence of a linked TCF parent, used to hide a linked Google provider
    /// (T-V09). Deliberately separate from the two eligibility flags: a restricted
    /// parent with no exposed basis still exists, and must still hide the provider.
    let linkedTcfExists: Bool
    let linkedGoogleExists: Bool
    /// Per-channel presence (mirrors refreshUiState's hasConsent/hasLI).
    let hasConsentChannel: Bool
    let hasLIChannel: Bool
}

struct SnapGoogleProvider {
    let id: Int
    let name: String
    let nameLower: String
    let policyUrl: String?
    let linkedSirdata: SnapLinkedSirdata?
}

/// A purpose-like display entity (TCF purpose, special feature, special
/// purpose, feature, or Sirdata purpose).
struct SnapPurpose {
    let id: Int
    let name: String
    /// Raw description (partners screen shows it unprocessed).
    let descriptionRaw: String
    /// Description with the full placeholder pipeline applied (purposes screen).
    let descriptionProcessed: String
}

struct SnapStack {
    let id: Int32
    let name: String
    let descriptionProcessed: String
    let purposes: [Int]
    let specialFeatures: [Int]
    /// Sirdata stacks only (empty for TCF stacks).
    let extraPurposes: [Int]
}

struct SnapStandardPurpose {
    let id: Int32
    let isLI: Bool
}

struct SnapCustomPurpose {
    let id: Int32
    let name: String
    let descriptionRaw: String
    let descriptionProcessed: String
    let isLI: Bool
    let vendorName: String?
    let vendorPolicyUrl: String?
}

/// The full load-time snapshot. Value type; never mutated after build.
struct ConsentSnapshot {
    var vendors: [SnapTcfVendor] = []
    var sirdataVendors: [SnapSirdataVendor] = []
    var googleProviders: [SnapGoogleProvider] = []
    /// Pre-sorted by lowercase name (several call sites need sorted output).
    var googleProvidersSortedByName: [SnapGoogleProvider] = []
    var purposes: [SnapPurpose] = []
    var specialFeatures: [SnapPurpose] = []
    var specialPurposes: [SnapPurpose] = []
    var features: [SnapPurpose] = []
    var sirdataPurposes: [SnapPurpose] = []
    var stacks: [SnapStack] = []
    var sirdataStacks: [SnapStack] = []
    var standardPurposes: [SnapStandardPurpose] = []
    var customPurposes: [SnapCustomPurpose] = []
    var purposeById: [Int: SnapPurpose] = [:]
    var sirdataPurposeById: [Int: SnapPurpose] = [:]
    var specialFeatureById: [Int: SnapPurpose] = [:]
    /// Membership of the DISPLAY lists — the Kotlin state logic intersects
    /// vendor sets with vendorList.purposes / .specialFeatures / sirdataList.purposes.
    var tcfListPurposeIds: Set<Int> = []
    var tcfListSpecialFeatureIds: Set<Int> = []
    var sirdataListPurposeIds: Set<Int> = []
}

// MARK: - Bridged selection sets (one interop pass per refresh)

/// Snapshot of every selected-id set, bridged from Kotlin ONCE per refresh.
struct SelectedSets {
    var purposeIds: Set<Int> = []
    var purposeLIIds: Set<Int> = []
    var specialFeatureIds: Set<Int> = []
    var vendorIds: Set<Int> = []
    var vendorLIIds: Set<Int> = []
    var sirdataPurposeIds: Set<Int> = []
    var sirdataPurposeLIIds: Set<Int> = []
    var sirdataVendorIds: Set<Int> = []
    var sirdataVendorLIIds: Set<Int> = []
    var providerIds: Set<Int> = []
    var standardPurposeIds: Set<Int> = []
    var standardPurposeLIIds: Set<Int> = []
    var customPurposeIds: Set<Int> = []
    var customPurposeLIIds: Set<Int> = []

    static func bridge(consentData: ConsentData) -> SelectedSets {
        // Iterate through NSSet WITHOUT the typed bridge: the Kotlin Set<Int>
        // is declared Set<KotlinInt> in the ObjC export but may hold plain
        // NSNumber instances at runtime — a typed Swift iteration would
        // force-bridge each element and crash (swift_dynamicCastFailure, as
        // the CI crash reports showed for the analogous Map conversion).
        func ints(_ set: Set<KotlinInt>) -> Set<Int> {
            var out = Set<Int>(minimumCapacity: set.count)
            for element in (set as NSSet) {
                if let n = element as? NSNumber { out.insert(n.intValue) }
            }
            return out
        }
        var s = SelectedSets()
        let core = consentData.coreData
        let custom = consentData.customData
        let publisher = consentData.publisherTCData
        s.purposeIds = ints(core.selectedPurposeIds)
        s.purposeLIIds = ints(core.selectedPurposeLIIds)
        s.specialFeatureIds = ints(core.selectedSpecialFeatureIds)
        s.vendorIds = ints(core.selectedVendorIds)
        s.vendorLIIds = ints(core.selectedVendorLIIds)
        s.sirdataPurposeIds = ints(custom.selectedSirdataPurposeIds)
        s.sirdataPurposeLIIds = ints(custom.selectedSirdataPurposeLIIds)
        s.sirdataVendorIds = ints(custom.selectedSirdataVendorIds)
        s.sirdataVendorLIIds = ints(custom.selectedSirdataVendorLIIds)
        s.providerIds = ints(custom.selectedProviderIds)
        s.standardPurposeIds = ints(publisher.selectedStandardPurposeIds)
        s.standardPurposeLIIds = ints(publisher.selectedStandardPurposeLIIds)
        s.customPurposeIds = ints(publisher.selectedCustomPurposeIds)
        s.customPurposeLIIds = ints(publisher.selectedCustomPurposeLIIds)
        return s
    }
}

// MARK: - Pure state computation (ConsentSelector.kt port)

/// A row's toggle state plus what a PARENT row needs to aggregate it.
private struct ToggleStateInfo {
    let state: String
    /// True when a consent (opt-in) channel is ON anywhere beneath the row.
    let grantsConsent: Bool
}

/// Read-side mirror of the shared selector's `ToggleStateAggregator`
/// (ConsentSelector.kt) — the rule is DEFINED there, and in the web selector;
/// this is the same aggregation in pure Swift so a toggle pass never crosses the
/// Kotlin bridge. No view may re-derive it.
///
/// A row aggregates one or more *channels*: consent (opt-in) and/or legitimate
/// interest (opt-out). Channels all agreeing give ON or OFF; otherwise the row is
/// mixed, and one question separates the two mixed states: does anything beneath
/// it grant a consent? A legitimate interest left un-opposed is NOT a consent —
/// a dual-basis purpose with consent OFF and LI ON grants no opt-in and reads
/// `partiallyRejected`. Hence `addChild`: an ON child cannot be counted blindly,
/// its own consent flag has to travel with its state.
private struct ToggleStateAggregator {
    private var states = Set<String>()
    private var consentGranted = false

    /// A consent (opt-in) channel: selected means a consent IS granted.
    mutating func addConsent(_ isSelected: Bool) {
        states.insert(isSelected ? ToggleState.on : ToggleState.off)
        if isSelected { consentGranted = true }
    }

    /// A legitimate-interest channel: selected means "not opposed", never a consent.
    mutating func addLegitimateInterest(_ isSelected: Bool) {
        states.insert(isSelected ? ToggleState.on : ToggleState.off)
    }

    /// A nested row (e.g. a stack's purpose): its consent flag propagates up.
    mutating func addChild(_ child: ToggleStateInfo) {
        states.insert(child.state)
        if child.grantsConsent { consentGranted = true }
    }

    var info: ToggleStateInfo {
        // No channel at all grants nothing either, hence partiallyRejected —
        // which renders exactly as the former empty "mixed" state did.
        let state: String
        if states.count == 1 {
            state = states.first!
        } else {
            state = consentGranted ? ToggleState.partiallyAccepted : ToggleState.partiallyRejected
        }
        return ToggleStateInfo(state: state, grantsConsent: consentGranted)
    }
}

/// Computes every toggle state in pure Swift from the load-time snapshot, the
/// legal-basis id sets, and the bridged selection sets. Each function is a
/// 1:1 port of the corresponding ConsentSelector query (cited by name).
struct ConsentStateComputer {
    let snap: ConsentSnapshot
    /// vendorList.getConsentPurpose(id) != null ⇔ purposeConsentIds.contains(id)
    let purposeConsentIds: Set<Int>
    let purposeLIIds: Set<Int>
    let sirdataPurposeConsentIds: Set<Int>
    let sirdataPurposeLIIds: Set<Int>
    let sel: SelectedSets

    private func on(_ selected: Bool) -> String {
        selected ? ToggleState.on : ToggleState.off
    }

    /// ConsentSelector.kt getPurposeInfo
    private func purposeInfo(_ id: Int) -> ToggleStateInfo {
        var aggregator = ToggleStateAggregator()
        for sp in snap.standardPurposes where Int(sp.id) == id {
            if sp.isLI {
                aggregator.addLegitimateInterest(sel.standardPurposeLIIds.contains(id))
            } else {
                aggregator.addConsent(sel.standardPurposeIds.contains(id))
            }
        }
        if purposeConsentIds.contains(id) { aggregator.addConsent(sel.purposeIds.contains(id)) }
        if purposeLIIds.contains(id) { aggregator.addLegitimateInterest(sel.purposeLIIds.contains(id)) }
        return aggregator.info
    }

    /// ConsentSelector.kt getPurposeState
    func purposeState(_ id: Int) -> String { purposeInfo(id).state }

    /// ConsentSelector.kt getPurposeConsentState
    func purposeConsentState(_ id: Int) -> String {
        guard purposeConsentIds.contains(id) else { return "" }
        return on(sel.purposeIds.contains(id))
    }

    /// ConsentSelector.kt getPurposeLIState
    func purposeLIState(_ id: Int) -> String {
        guard purposeLIIds.contains(id) else { return "" }
        return on(sel.purposeLIIds.contains(id))
    }

    /// ConsentSelector.kt getStandardPurposeState
    func standardPurposeState(_ id: Int) -> String {
        guard let sp = snap.standardPurposes.first(where: { Int($0.id) == id }) else { return "" }
        return on(sp.isLI ? sel.standardPurposeLIIds.contains(id)
                          : sel.standardPurposeIds.contains(id))
    }

    /// ConsentSelector.kt getCustomPurposeState
    func customPurposeState(_ id: Int) -> String {
        guard let cp = snap.customPurposes.first(where: { Int($0.id) == id }) else { return "" }
        return on(cp.isLI ? sel.customPurposeLIIds.contains(id)
                          : sel.customPurposeIds.contains(id))
    }

    /// ConsentSelector.kt getSirdataPurposeInfo
    private func sirdataPurposeInfo(_ id: Int) -> ToggleStateInfo {
        var aggregator = ToggleStateAggregator()
        if sirdataPurposeConsentIds.contains(id) { aggregator.addConsent(sel.sirdataPurposeIds.contains(id)) }
        if sirdataPurposeLIIds.contains(id) { aggregator.addLegitimateInterest(sel.sirdataPurposeLIIds.contains(id)) }
        return aggregator.info
    }

    /// ConsentSelector.kt getSirdataPurposeState
    func sirdataPurposeState(_ id: Int) -> String { sirdataPurposeInfo(id).state }

    /// ConsentSelector.kt getSirdataPurposeConsentState
    func sirdataPurposeConsentState(_ id: Int) -> String {
        guard sirdataPurposeConsentIds.contains(id) else { return "" }
        return on(sel.sirdataPurposeIds.contains(id))
    }

    /// ConsentSelector.kt getSirdataPurposeLIState
    func sirdataPurposeLIState(_ id: Int) -> String {
        guard sirdataPurposeLIIds.contains(id) else { return "" }
        return on(sel.sirdataPurposeLIIds.contains(id))
    }

    /// ConsentSelector.kt (special feature branch of getStackState)
    func specialFeatureState(_ id: Int) -> String {
        on(sel.specialFeatureIds.contains(id))
    }

    /// ConsentSelector.kt getStackState
    func stackState(purposes: [Int], specialFeatures: [Int], extraPurposes: [Int]) -> String {
        var aggregator = ToggleStateAggregator()
        for pid in purposes where snap.tcfListPurposeIds.contains(pid) {
            aggregator.addChild(purposeInfo(pid))
        }
        for sfId in specialFeatures where snap.tcfListSpecialFeatureIds.contains(sfId) {
            // Special features are consent-only (opt-in).
            aggregator.addConsent(sel.specialFeatureIds.contains(sfId))
        }
        for pid in extraPurposes where snap.sirdataListPurposeIds.contains(pid) {
            aggregator.addChild(sirdataPurposeInfo(pid))
        }
        return aggregator.info.state
    }

    /// ConsentSelector.kt getVendorState (combined state)
    ///
    /// FRONT-1276 — `unlinked` presents the partner on its own: the fused Sirdata partner's
    /// channels are NOT aggregated here, because the apply screen gives it a row of its own
    /// with its own state.
    func vendorCombinedState(_ v: SnapTcfVendor, unlinked: Bool = false) -> String {
        var aggregator = ToggleStateAggregator()
        if v.combinedConsentEligible { aggregator.addConsent(sel.vendorIds.contains(v.id)) }
        if v.combinedLIEligible { aggregator.addLegitimateInterest(sel.vendorLIIds.contains(v.id)) }
        if let linked = v.linkedSirdata, !unlinked {
            if linked.hasConsentChannel { aggregator.addConsent(sel.sirdataVendorIds.contains(linked.id)) }
            if linked.hasLIChannel {
                aggregator.addLegitimateInterest(sel.sirdataVendorLIIds.contains(linked.id))
            }
        }
        return aggregator.info.state
    }

    /// ConsentSelector.kt getSirdataVendorState (combined state)
    /// FRONT-1276 — see `vendorCombinedState` for `unlinked`.
    func sirdataVendorCombinedState(_ v: SnapSirdataVendor, unlinked: Bool = false) -> String {
        var aggregator = ToggleStateAggregator()
        if v.combinedConsentEligible { aggregator.addConsent(sel.sirdataVendorIds.contains(v.id)) }
        if v.combinedLIEligible { aggregator.addLegitimateInterest(sel.sirdataVendorLIIds.contains(v.id)) }
        if let tcfId = v.tcfVendorId, !unlinked {
            if v.linkedTcfConsentEligible { aggregator.addConsent(sel.vendorIds.contains(tcfId)) }
            if v.linkedTcfLIEligible { aggregator.addLegitimateInterest(sel.vendorLIIds.contains(tcfId)) }
        }
        if !unlinked, v.linkedGoogleExists, let gpId = v.googleProviderId {
            aggregator.addConsent(sel.providerIds.contains(gpId))
        }
        return aggregator.info.state
    }

    /// ConsentSelector.kt getACProviderState (combined state)
    /// FRONT-1276 — see `vendorCombinedState` for `unlinked`.
    func acProviderState(_ p: SnapGoogleProvider, unlinked: Bool = false) -> String {
        var aggregator = ToggleStateAggregator()
        // AC providers are consent-only (opt-in).
        aggregator.addConsent(sel.providerIds.contains(p.id))
        if let linked = p.linkedSirdata, !unlinked {
            if linked.hasConsentChannel { aggregator.addConsent(sel.sirdataVendorIds.contains(linked.id)) }
            if linked.hasLIChannel {
                aggregator.addLegitimateInterest(sel.sirdataVendorLIIds.contains(linked.id))
            }
        }
        return aggregator.info.state
    }
}
