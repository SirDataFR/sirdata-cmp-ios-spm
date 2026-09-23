import SwiftUI

/// Shared, expandable partner (vendor) list rendered under a purpose.
///
/// Web CMP parity: `Purpose.jsx` -> `PurposeVendorsHeader` (chevron + label +
/// count + Toggle inside the header) followed by `PurposeVendors` (expandable
/// list). Mirrors Android's `PurposeVendorList`.
///
/// Stateless: expansion is read from the ViewModel-owned `expandedIds` under
/// the keys `"\(baseId)_consentVendors"` / `"\(baseId)_liVendors"`, and every
/// interaction is emitted as a `ConsentIntent` through `send`.
///
/// IMPORTANT — the caller MUST pass **already split** `consentVendors` and
/// `liVendors` lists. This view does NOT re-filter by `VendorSummary.status`
/// (the status string is localized, so literal comparisons never match).
struct PurposeVendorList: View {
    let consentVendors: [VendorSummary]
    let liVendors: [VendorSummary]
    /// Live toggle/acceptance values (vendor acceptance looked up by stateKey).
    let toggles: TogglesState
    /// Optional localize closure for partner-count labels. When nil, labels omitted.
    var localizeText: ((String) -> String)? = nil
    /// Count shown on the consent line (defaults to list size).
    var consentVendorCount: Int? = nil
    /// Count shown on the LI line (defaults to list size).
    var liVendorCount: Int? = nil
    /// Wording of the count lines — web parity: features and special purposes
    /// carry no consent, so they use "<count/> partners use this activity"
    /// instead of the consent phrasing (`Feature.jsx`, `SpecialPurpose.jsx`).
    var countWording: VendorCountWording = .legalBasis
    /// Consent-only toggle state (empty = no consent toggle).
    var consentToggleState: String = ""
    /// Intent emitted by the consent-only toggle (nil = no toggle shown).
    var consentToggleIntent: ConsentIntent? = nil
    /// LI-only toggle state (empty = no LI toggle).
    var liToggleState: String = ""
    /// Intent emitted by the LI-only toggle (nil = no toggle shown).
    var liToggleIntent: ConsentIntent? = nil
    /// Namespace for this list's expand keys (usually the owning row's id).
    let baseId: String
    let expandedIds: Set<String>
    let send: (ConsentIntent) -> Void
    @Environment(\.cmpResolvedTheme) private var theme

    private var resolvedConsentCount: Int { consentVendorCount ?? consentVendors.count }
    private var resolvedLICount: Int { liVendorCount ?? liVendors.count }
    private var consentExpandKey: String { "\(baseId)_consentVendors" }
    private var liExpandKey: String { "\(baseId)_liVendors" }
    private var isConsentExpanded: Bool { expandedIds.contains(consentExpandKey) }
    private var isLIExpanded: Bool { expandedIds.contains(liExpandKey) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Consent partner-count line (expandable) with optional toggle.
            let hasConsentToggle = !consentToggleState.isEmpty && consentToggleIntent != nil
            if resolvedConsentCount > 0 || hasConsentToggle, let localizeText {
                let base = countWording == .activityUse
                    ? "purposes.purposeVendorsWithCount"
                    : "purposes.partnersConsentWithCount"
                let label = localizeText(pluralized(base, count: resolvedConsentCount))
                    .replacingOccurrences(of: "{count}", with: "\(resolvedConsentCount)")
                    .replacingOccurrences(of: "<count/>", with: "\(resolvedConsentCount)")
                headerLine(label: label,
                           isExpandable: !consentVendors.isEmpty,
                           isExpanded: isConsentExpanded,
                           expandKey: consentExpandKey,
                           toggleState: hasConsentToggle ? consentToggleState : "",
                           toggleIntent: hasConsentToggle ? consentToggleIntent : nil,
                           toggleAccessibilityName: "Consent",
                           toggleIdentifier: "cmp.row.\(baseId).consentToggle")
            }

            // Consent vendor list (name + status + IAB badge)
            if isConsentExpanded && !consentVendors.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(consentVendors) { vendor in
                        vendorRow(vendor)
                    }
                }
                .padding(.leading, 8)
                .transition(.opacity)
            }

            // LI partner-count line (expandable) with optional toggle.
            let hasLIToggle = !liToggleState.isEmpty && liToggleIntent != nil
            if resolvedLICount > 0 || hasLIToggle, let localizeText {
                let label = localizeText(pluralized("purposes.partnersLIWithCount", count: resolvedLICount))
                    .replacingOccurrences(of: "{count}", with: "\(resolvedLICount)")
                    .replacingOccurrences(of: "<count/>", with: "\(resolvedLICount)")
                headerLine(label: label,
                           isExpandable: !liVendors.isEmpty,
                           isExpanded: isLIExpanded,
                           expandKey: liExpandKey,
                           toggleState: hasLIToggle ? liToggleState : "",
                           toggleIntent: hasLIToggle ? liToggleIntent : nil,
                           toggleAccessibilityName: "Legitimate Interest",
                           toggleIdentifier: "cmp.row.\(baseId).liToggle")
            }

            // LI vendor list (name + status + IAB badge)
            if isLIExpanded && !liVendors.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(liVendors) { vendor in
                        vendorRow(vendor)
                    }
                }
                .padding(.leading, 8)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Locale key for `count`, following the web's `getLocaleKey`: the plural
    /// form is used ONLY above 1, so count = 0 takes the singular key.
    private func pluralized(_ baseKey: String, count: Int) -> String {
        count > 1 ? "\(baseKey)_plural" : baseKey
    }

    /// Two-column header: content-hugging clickable (chevron + label) followed
    /// by a gesture-less Spacer, then the fixed-width toggle. Mirrors the web
    /// CMP RowBlockHeader layout and Android's Spacer(weight(1f)) — the space
    /// between the label and the toggle is provably untappable.
    @ViewBuilder
    private func headerLine(label: String, isExpandable: Bool, isExpanded: Bool,
                            expandKey: String, toggleState: String,
                            toggleIntent: ConsentIntent?, toggleAccessibilityName: String,
                            toggleIdentifier: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            if isExpandable {
                HStack(spacing: 4) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundColor(theme.text.opacity(0.6))
                    Text(label)
                        .font(.caption)
                        .foregroundColor(theme.text.opacity(0.7))
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    send(.toggleExpand(expandKey))
                }
                Spacer(minLength: 0)
            } else {
                Text(label)
                    .font(.caption)
                    .foregroundColor(theme.text.opacity(0.7))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !toggleState.isEmpty, let toggleIntent {
                ConsentToggle(state: toggleState, onToggleChange: { _ in send(toggleIntent) },
                              accessibilityName: toggleAccessibilityName)
                    .fixedSize()
                    // Stable hook for UI tests / QA automation.
                    .accessibilityIdentifier(toggleIdentifier)
            }
        }
    }

    /// A single partner line: name (clickable link when policyUrl present) +
    /// optional acceptance status + optional IAB TCF badge.
    /// Web parity: PurposeVendors.jsx `<Link url={policyUrl}>{name}</Link>` +
    /// `withState` acceptance label. Mirrors Android's `VendorSummaryRow`.
    @ViewBuilder
    private func vendorRow(_ vendor: VendorSummary) -> some View {
        HStack(spacing: 6) {
            // GAP-P18: render name as clickable link when policyUrl is present
            if let policyUrl = vendor.policyUrl, let url = URL(string: policyUrl) {
                Link(destination: url) {
                    Text(vendor.name)
                        .font(.caption2)
                        .underline()
                        .foregroundColor(theme.main)
                        .lineLimit(1)
                }
            } else {
                Text(vendor.name)
                    .font(.caption2)
                    .foregroundColor(theme.text.opacity(0.6))
                    .lineLimit(1)
            }
            // GAP-P19: acceptance status text (web parity: PurposeVendors.jsx
            // withState) — live value looked up in TogglesState by stateKey.
            if let stateKey = vendor.stateKey, let acceptanceStatus = toggles.acceptance[stateKey] {
                Text(acceptanceStatus)
                    .font(.caption2)
                    .foregroundColor(theme.text.opacity(0.5))
            }
            if let badge = vendor.iabBadge {
                Text(badge)
                    .font(.caption2)
                    .foregroundColor(theme.text.opacity(0.5))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(theme.text.opacity(0.08))
                    .cornerRadius(4)
            }
        }
    }
}
