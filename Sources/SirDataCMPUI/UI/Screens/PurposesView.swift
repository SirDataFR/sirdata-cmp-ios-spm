import SwiftUI
import SirDataCMP

// NOTE: the historical `delaysContentTouches = false` ScrollView hack is
// deliberately GONE. Its rationale (content re-layout during UIKit's ~150ms
// touch hold, cancelling the held tap) died with the structure/toggles split:
// a consent tap now recomputes ~1ms of toggle values and republishes nothing
// that re-lays-out rows. With the hold disabled, the scroll pan recognizer
// could instead CANCEL a button's touch on micro-movement — observed in CI
// as intermittent first taps reaching no control at all (`tap 0` in the HUD,
// consistently on the first Mixed stack toggle). Standard UIKit arbitration
// is the correct behavior now. Do not reintroduce without HUD evidence.

/// Preferences screen: a unified "activities" list (TCF + Sirdata stacks, each
/// expanding to its nested purposes), then free purposes, special features and
/// an informational "support" section. Mirrors Android's `PurposesView` and the
/// web CMP `Purposes.jsx`.
///
/// Pure rendering: every row, list, count and toggle state comes pre-derived
/// from `uiState.purposesScreen` (built in `ConsentViewModel.refreshUiState()`
/// from the live selector snapshot). Expansion lives in `uiState.expandedIds`.
/// The view performs NO filtering, NO vendor computation and holds NO caches —
/// interactions are emitted as `ConsentIntent`s through the single `send`
/// funnel, and the screen re-renders from the one published state.
struct PurposesView: View {
    let uiState: ConsentUiState
    /// Live toggle values — the ONLY state a consent tap changes.
    let toggles: TogglesState
    let localize: Localize
    let send: (ConsentIntent) -> Void
    let onBack: () -> Void
    let onViewPartners: () -> Void
    let onAcceptAll: () -> Void
    let onRejectAll: () -> Void
    let onSave: () -> Void

    @Environment(\.cmpResolvedTheme) private var theme
    @State private var showActivitiesHelp = false
    /// GAP-05: Hostnames modal state (web parity: Text2.jsx hostnames link).
    @State private var showHostnamesSheet = false

    private var screen: PurposesScreenModel { uiState.purposesScreen }

    // Cookie wall workflow (COOKIEWALL_MODIFY): the PURPOSE_ONE screen shows
    // ONLY Purpose 1 with a toggle (web parity: togglePurposeOneShowing).
    // Section filtering for this mode is done in the ViewModel builder; the
    // view only adapts the footer.
    private var isPurposeOne: Bool { uiState.currentScreen == .purposeOne }

    var body: some View {
        VStack(spacing: 0) {
            CmpTopBar(title: localize.getText(key: LocaleKey.detailsTitle.key), onBack: onBack) {
                // GAP-P06: Close button in Purposes header (web parity).
                // CNIL variant: closing saves consent. Otherwise: dismiss.
                let closeAction = uiState.isCnilVariant ? onSave : onBack
                Button(action: closeAction) {
                    Image(systemName: "xmark")
                        .foregroundColor(theme.title.opacity(0.6))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(localize.getText(key: LocaleKey.buttonsClose.key))
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    // Web parity (Purposes.jsx): publisher standard/custom purposes
                    // are rendered FIRST in the activities list, before stacks and
                    // free purposes.
                    ForEach(screen.publisherPurposeRows) { purposeRow($0) }
                    activities
                    ForEach(screen.freePurposeRows) { purposeRow($0) }
                    ForEach(screen.specialFeatureRows) { purposeRow($0) }
                    supportSection
                    // GAP-06: Web parity — Special Purposes and Features in
                    // separate sections after the support section (spec §1).
                    ForEach(screen.specialPurposeRows) { purposeRow($0) }
                    ForEach(screen.featureRows) { purposeRow($0) }
                    Divider().padding(.vertical, 4)
                    // Consent storage mention (web parity: ConsentStorageMention).
                    // Web renders buildText(text, { maxAge: getDurationFromDays(...) });
                    // resolve the `<maxAge/>` placeholder here so the cookie
                    // max-age duration replaces the literal tag.
                    Text(
                        localize.getText(key: uiState.consentStorageKey)
                            .replacingOccurrences(
                                of: "<maxAge/>",
                                with: getDurationFromDays(uiState.maxAgeDays, localize: localize)
                            )
                    )
                        .font(.caption2)
                        .foregroundColor(theme.text.opacity(0.5))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                    // GAP-07: Web parity (ProviderLogo) — hide watermark in white-label mode.
                    if !uiState.whiteLabel {
                        SirDataWatermark().padding(.top, 8)
                    }
                }
                .padding(.bottom, 12)
            }

            footer
        }
        .background(theme.background.ignoresSafeArea())
    }

    // MARK: - Row rendering

    private func purposeRow(_ model: PurposeRowModel) -> some View {
        PurposeRow(
            model: model,
            toggles: toggles,
            localizeText: { key in localize.getText(key: key) },
            expandedIds: uiState.expandedIds,
            send: send
        )
    }

    // MARK: - Header (partners pill, intro texts, policy link)

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            // FRONT-1284 — parité web : `purposes/Text1.jsx:17` compte
            // `googleProviders.length` SANS condition. `disableTcf` n'apparaît nulle part
            // dans les tests de présence du web, donc le gater ici faisait disparaître le
            // bouton d'entrée aux partenaires dans une configuration où le web l'affiche.
            let hasNoPartner = uiState.vendors.isEmpty && uiState.sirdataVendors.isEmpty && uiState.googleProviders.isEmpty
            // Web parity (GAP-P13): View Partners button only shown when vendors are present.
            if !hasNoPartner {
                Button(action: onViewPartners) {
                    Text(localize.getText(key: LocaleKey.buttonsViewPartners.key))
                        .font(.caption.weight(.semibold))
                        .foregroundColor(theme.main)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .overlay(
                            Capsule()
                                .stroke(theme.main, lineWidth: 1.5)
                        )
                        // Whole capsule (not just the glyphs) is tappable.
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            let text1Key = hasNoPartner ? LocaleKey.purposesText1NoPartner.key : LocaleKey.purposesText1.key
            Text(processPurposesText1(localize.getText(key: text1Key)))
                .font(.subheadline)
                .foregroundColor(theme.text.opacity(0.85))

            // GAP-05: Web parity — render Text2 with clickable hostnames links.
            let text2Segments = processPurposesText2Segments(localize.getText(key: LocaleKey.purposesText2.key))
            if !text2Segments.isEmpty {
                text2View(text2Segments)
            }

            if !uiState.privacyPolicyUrl.isEmpty, let url = URL(string: uiState.privacyPolicyUrl) {
                // Underline on the inner Text (iOS 13+); the View-level
                // .underline() requires iOS 16.
                Link(destination: url) {
                    Text(localize.getText(key: LocaleKey.accessOurPrivacyPolicy.key))
                        .font(.subheadline)
                        .underline()
                        .foregroundColor(theme.title)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    // MARK: - Activities (TCF + Sirdata stacks)

    @ViewBuilder
    private var activities: some View {
        if screen.showActivitiesHeader {
            HStack(spacing: 4) {
                sectionHeader(localize.getText(key: LocaleKey.ourActivities.key))
                Button {
                    showActivitiesHelp.toggle()
                } label: {
                    Image(systemName: "info.circle")
                        .foregroundColor(theme.main)
                }
                .padding(.trailing, 16)
                .accessibilityLabel(localize.getText(key: LocaleKey.purposesStack.key))
            }
            // Web parity (GAP-P15): Help shows the toggle state legend
            // (Rejected/Mixed/Accepted), matching HelpBox.jsx.
            if showActivitiesHelp {
                ToggleStateLegend()
            }
        }

        ForEach(screen.stackRows) { stack in
            StackRow(
                model: stack,
                toggles: toggles,
                whatItMeansLabel: localize.getText(key: LocaleKey.purposesStack.key),
                localizeText: { key in localize.getText(key: key) },
                expandedIds: uiState.expandedIds,
                send: send
            )
        }
    }

    // MARK: - Support section (informational, no main toggles)

    @ViewBuilder
    private var supportSection: some View {
        if !screen.supportRows.isEmpty {
            Divider().padding(.vertical, 8)
            sectionHeader(localize.getText(key: LocaleKey.purposesSupportActivities.key))
            ForEach(screen.supportRows) { purposeRow($0) }
        }
    }

    // MARK: - Footer (T5/GAP-P14: web-parity order Reject / Accept / Save, equal weight Reject/Accept)

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            // Purpose One screen (web parity): single "Accept cookies" button only
            if isPurposeOne {
                VStack(spacing: 10) {
                    ConsentButton(label: localize.getText(key: LocaleKey.buttonsAcceptCookies.key),
                                  action: {
                        send(.selectPurpose(1, true))
                        onSave()
                    }, style: .primary, isPrimary: true)
                        .frame(maxWidth: .infinity)
                }
                .padding(16)
            } else {
                // T5 (GAP-P14): Vertical button layout — Reject All, then Accept
                // All (same TONAL weight, so Reject is never demoted vs Accept),
                // then Save full width (web order: Reject / Accept / Save).
                VStack(spacing: 10) {
                    ConsentButton(label: localize.getText(key: LocaleKey.buttonsRejectAll.key), action: onRejectAll, style: .tonal)
                        .frame(maxWidth: .infinity)
                        // Stable, locale-independent hooks for UI tests / QA.
                        .accessibilityIdentifier("cmp.purposes.rejectAll")

                    ConsentButton(label: localize.getText(key: LocaleKey.buttonsAcceptAll.key), action: onAcceptAll, style: .tonal)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("cmp.purposes.acceptAll")

                    ConsentButton(label: localize.getText(key: LocaleKey.buttonsSave.key), action: onSave, style: .primary, isPrimary: true)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("cmp.purposes.save")
                }
                .padding(16)
            }
        }
        .background(theme.background)
    }

    // MARK: - Helpers

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundColor(theme.main)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            // FRONT-1435 — un intertitre, pas du texte en gras (RGAA 9.1).
            .accessibilityAddTraits(.isHeader)
    }

    // ─── Purposes screen intro texts (Web CMP parity) ─────────────────
    /// Web CMP purposes/Text1.jsx: `buildText(text)` — NO self-closing tags.
    /// Only conditional tags and classname tags are resolved.
    private func processPurposesText1(_ text: String) -> String {
        text
            .processConditionalTags(
                purposeIds: uiState.availablePurposeIds,
                sirdataPurposeIds: uiState.availableSirdataPurposeIds,
                specialFeatureIds: uiState.availableSpecialFeatureIds,
                hasLegitimateInterest: uiState.hasLegitimateInterest,
                hasCustomPurposes: uiState.hasCustomPurposes,
                hasUtiq: uiState.hasUtiq,
                sirdataStackIds: uiState.sirdataStackIds
            )
            .processClassnameTags(setChoicesStyle: uiState.choicesStyle)
    }

    /// GAP-05: Web parity — Text2.jsx hostnames links. Returns structured
    /// segments so the view can render HOSTNAMES segments as clickable links.
    private func processPurposesText2Segments(_ text: String) -> [(text: String, linkType: String?)] {
        let firstPass = text.processConditionalTags(
            purposeIds: uiState.availablePurposeIds,
            sirdataPurposeIds: uiState.availableSirdataPurposeIds,
            specialFeatureIds: uiState.availableSpecialFeatureIds,
            hasLegitimateInterest: uiState.hasLegitimateInterest,
            hasCustomPurposes: uiState.hasCustomPurposes,
            hasUtiq: uiState.hasUtiq,
            sirdataStackIds: uiState.sirdataStackIds
        )
        // Resolve only <scope/> and <maxAge/> — mirrors Web CMP purposes/Text2.jsx
        let scopeText = localize.getText(key: uiState.scopeTextKey)
        let withScope = firstPass.replacingOccurrences(of: "<scope/>", with: scopeText)
        let maxAgeText = getDurationFromDays(uiState.maxAgeDays, localize: localize)
        let withMaxAge = withScope.replacingOccurrences(of: "<maxAge/>", with: maxAgeText)
        return withMaxAge.processClassnameTagsStructured(setChoicesStyle: uiState.choicesStyle)
    }

    /// GAP-05: Renders Text2 segments with clickable hostnames links.
    /// HOSTNAMES segments open a modal sheet listing uiState.hostnames.
    @ViewBuilder
    private func text2View(_ segments: [(text: String, linkType: String?)]) -> some View {
        let hasHostnamesLink = segments.contains { $0.linkType == "HOSTNAMES" }
        let plainText = segments.map { $0.text }.joined()
        if hasHostnamesLink {
            Text(plainText)
                .font(.subheadline)
                .foregroundColor(theme.text.opacity(0.85))
                .onTapGesture {
                    showHostnamesSheet = true
                }
                .sheet(isPresented: $showHostnamesSheet) {
                    HostnamesSheet(
                        hostnames: uiState.hostnames,
                        utiqNoticeUrl: nil,
                        localize: localize,
                        theme: theme
                    )
                    .cmpPresentationDetents(medium: true)
                }
        } else {
            Text(plainText)
                .font(.subheadline)
                .foregroundColor(theme.text.opacity(0.85))
        }
    }
}
