import SwiftUI

/// A single purpose row with name, expandable description and consent toggle.
///
/// Stateless renderer of tap-immutable STRUCTURE (`PurposeRowModel`):
/// - live toggle values come from `toggles` (looked up by `model.id`),
/// - expansion comes from `expandedIds` (key = `model.id`),
/// - interactions are emitted as `ConsentIntent`s through `send`.
/// A row without `toggleIntent` is informational (support section, special
/// purposes, features). Mirrors Android's `PurposeRow`.
struct PurposeRow: View {
    let model: PurposeRowModel
    let toggles: TogglesState
    /// Optional localize closure for labels and illustration text.
    var localizeText: ((String) -> String)? = nil
    let expandedIds: Set<String>
    let send: (ConsentIntent) -> Void

    @State private var showIllustration = false
    @Environment(\.cmpResolvedTheme) private var theme

    private var isExpanded: Bool { expandedIds.contains(model.id) }
    private var consentToggleState: String {
        model.consentToggleIntent != nil ? (toggles.consent[model.id] ?? "") : ""
    }
    private var liToggleState: String {
        model.liToggleIntent != nil ? (toggles.li[model.id] ?? "") : ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                // Two-column deterministic layout: content-hugging clickable
                // (chevron + name) followed by a genuine gesture-less Spacer,
                // then the fixed-width toggle — the leftover row width is
                // provably untappable (web/Android parity).
                HStack(spacing: 4) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundColor(theme.text.opacity(0.5))
                    Text(model.name)
                        .font(.body.weight(.medium))
                        .foregroundColor(theme.text)
                        .lineLimit(isExpanded ? nil : 2)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    send(.toggleExpand(model.id))
                }
                // Stable hooks for UI tests / QA automation.
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("cmp.row.\(model.id).expand")
                Spacer(minLength: 0)
                if let toggleIntent = model.toggleIntent, !model.hideMainToggle {
                    ConsentToggle(state: toggles.row[model.id] ?? ToggleState.off,
                                  onToggleChange: { _ in send(toggleIntent) },
                                  accessibilityName: model.name)
                        .fixedSize()
                        .accessibilityIdentifier("cmp.row.\(model.id).toggle")
                }
            }

            if isExpanded {
                expandedContent
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("cmp.row.\(model.id).description")
            }

            Divider()
                .padding(.top, 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var expandedContent: some View {
                VStack(alignment: .leading, spacing: 6) {
                    if #available(iOS 15, *), let attr = model.description.htmlToAttributedString {
                        Text(attr)
                            .font(.subheadline)
                            .foregroundColor(theme.text.opacity(0.7))
                            .padding(.top, 4)
                    } else {
                        Text(model.description.strippedMarkup)
                            .font(.subheadline)
                            .foregroundColor(theme.text.opacity(0.7))
                            .padding(.top, 4)
                    }

                    // Examples button — opens in-app popup (web parity: PlusBox)
                    let illustrationText = (localizeText?("\(model.labelKey).illustrationText") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !model.labelKey.isEmpty && !illustrationText.isEmpty {
                        Button {
                            showIllustration = true
                        } label: {
                            Text(localizeText?("examples") ?? "Examples")
                                .font(.caption)
                                .underline()
                                .foregroundColor(theme.main)
                        }
                        .sheet(isPresented: $showIllustration) {
                            IllustrationPopup(
                                title: localizeText?("illustrations.title") ?? "Examples",
                                content: localizeText?("\(model.labelKey).illustrationText") ?? "",
                                onClose: { showIllustration = false }
                            )
                            .cmpPresentationDetents()
                        }
                    }

                    // GAP-P04: Publisher standard-purpose legal-basis block (web
                    // parity: Purpose.jsx:69-82 `mBasis`).
                    if model.hasStandardPurpose, let localizeText {
                        let hasConsentBasis = !consentToggleState.isEmpty
                        let hasLIBasis = !liToggleState.isEmpty
                        let showStdToggle = hasConsentBasis || hasLIBasis || model.hideMainToggle
                        HStack(alignment: .center, spacing: 8) {
                            Text(localizeText(model.standardPurposeIsLI ? "purposes.publisherLegitimateInterest" : "purposes.publisherConsent"))
                                .font(.caption)
                                .foregroundColor(theme.text.opacity(0.7))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if showStdToggle, let stdIntent = model.standardPurposeToggleIntent {
                                ConsentToggle(state: toggles.standard[model.id] ?? ToggleState.off,
                                              onToggleChange: { _ in send(stdIntent) },
                                              accessibilityName: "\(model.name) — Publisher")
                            }
                        }
                        .padding(.top, 8)
                    }

                    // Web parity (Purpose.jsx): a sub-toggle for one legal basis
                    // is only shown when the purpose also carries a standard TCF
                    // purpose, the other legal basis, or the main toggle is hidden.
                    let hasConsent = !consentToggleState.isEmpty
                    let hasLI = !liToggleState.isEmpty
                    let showConsentToggle = hasConsent && (model.hasStandardPurpose || hasLI || model.hideMainToggle)
                    let showLIToggle = hasLI && (model.hasStandardPurpose || hasConsent || model.hideMainToggle)

                    // Publisher legal-basis label (web parity: CustomPurpose.jsx).
                    if !model.legalBasisLabel.isEmpty {
                        Text(model.legalBasisLabel)
                            .font(.caption2)
                            .foregroundColor(theme.text.opacity(0.7))
                            .padding(.top, 8)
                    }

                    // Expandable partner (vendor) list per legal basis with
                    // toggles inside the headers (web parity: PurposeVendorsHeader
                    // + PurposeVendors).
                    if !model.consentVendors.isEmpty || !model.liVendors.isEmpty || showConsentToggle || showLIToggle {
                        PurposeVendorList(
                            consentVendors: model.consentVendors,
                            liVendors: model.liVendors,
                            toggles: toggles,
                            localizeText: localizeText,
                            consentVendorCount: model.consentVendorCount,
                            liVendorCount: model.liVendorCount,
                            countWording: model.vendorCountWording,
                            consentToggleState: showConsentToggle ? consentToggleState : "",
                            consentToggleIntent: showConsentToggle ? model.consentToggleIntent : nil,
                            liToggleState: showLIToggle ? liToggleState : "",
                            liToggleIntent: showLIToggle ? model.liToggleIntent : nil,
                            baseId: model.id,
                            expandedIds: expandedIds,
                            send: send
                        )
                        .padding(.top, 4)
                    }
                }
                .transition(.opacity)
    }
}
