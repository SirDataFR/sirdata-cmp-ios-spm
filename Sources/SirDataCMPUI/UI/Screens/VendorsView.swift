import SwiftUI
import SirDataCMP

/// Partners screen: a single alphabetical list of TCF vendors, Sirdata vendors
/// and Google AC providers, each with one combined toggle and per-channel
/// detail when expanded. Includes search, a scope reminder and an IAB legend.
///
/// Pure rendering: rows come pre-derived from `uiState.partnerEntries`
/// (closure-free, intents attached in `ConsentViewModel.refreshUiState()`),
/// expansion lives in `uiState.expandedIds` so LazyVStack recycling can never
/// drop it, and every toggle emits a `ConsentIntent` through `send`.
/// Mirrors Android's `VendorsView`.
struct VendorsView: View {
    let uiState: ConsentUiState
    /// Live toggle values — the ONLY state a consent tap changes.
    let toggles: TogglesState
    let localize: Localize
    let send: (ConsentIntent) -> Void
    let onBack: () -> Void
    let onAcceptAll: () -> Void
    let onRejectAll: () -> Void
    let onSave: () -> Void

    /// T-V11 (GAP-V16): Close action. In CNIL mode, saves consent before closing.
    /// Non-CNIL: simply dismisses the UI without saving.
    let onClose: () -> Void
    /// FRONT-1409 — the `ui:sites` click of the « voir les sites » link of the scope reminder.
    var onUiClick: ((UserActionUi) -> Void)? = nil

    @State private var searchQuery = ""
    @State private var showHelp = false
    @Environment(\.cmpResolvedTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            // T-V10 (GAP-V20+V21): Contextual navigation header
            CmpTopBar(
                title: localize.getText(key: LocaleKey.detailsTitle.key),
                subtitle: "\(allPartners.count)",
                onBack: onBack,
                trailing: {
                    HStack(spacing: 8) {
                        // VENDORS screen: View Purposes pill button (web parity)
                        if uiState.currentScreen == .vendors {
                            Button {
                                onBack()
                            } label: {
                                Text(localize.getText(key: LocaleKey.buttonsViewPurposes.key))
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundColor(theme.main)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 50)
                                            .stroke(theme.main, lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(localize.getText(key: LocaleKey.buttonsViewPurposes.key))
                        }
                        // T-V11 (GAP-V16): Close button — saves consent in CNIL mode
                        let closeAction = uiState.isCnilVariant ? onSave : onClose
                        Button(action: closeAction) {
                            Image(systemName: "xmark")
                                .foregroundColor(theme.title.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(localize.getText(key: LocaleKey.buttonsClose.key))
                    }
                }
            )

            searchField

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // T-V12 (web parity): OUR_PARTNERS list header, help icon included
                    partnersHeader
                    intro
                    ForEach(filteredPartners) { partner in
                        VendorRow(
                            entry: partner,
                            toggles: toggles,
                            privacyPolicyLabel: localize.getText(key: LocaleKey.privacyPolicy.key),
                            localize: localize,
                            expandedIds: uiState.expandedIds,
                            send: send
                        )
                    }
                    legend
                    SirDataWatermark().padding(.top, 8)
                }
                .padding(.bottom, 12)
            }

            footer
        }
        .background(theme.background.ignoresSafeArea())
    }

    // MARK: - Help (GAP-016)

    /// Partners list header + help button — web parity (`Vendors.jsx:147-151`):
    /// the `Help` component sits in the `listHeader`, next to `ourPartners`, and
    /// reveals the same `HelpBox` legend as the purposes screen.
    @ViewBuilder
    private var partnersHeader: some View {
        HStack(spacing: 4) {
            Text(localize.getText(key: LocaleKey.ourPartners.key))
                .font(.headline)
                .foregroundColor(theme.text)
                // FRONT-1435 — meme intertitre que `ourActivities` cote activites.
                .accessibilityAddTraits(.isHeader)
            Button {
                showHelp.toggle()
            } label: {
                Image(systemName: "info.circle")
                    .foregroundColor(theme.main)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(localize.getText(key: LocaleKey.buttonsHelp.key))
            .accessibilityIdentifier("cmp.partners.help")
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
        if showHelp {
            ToggleStateLegend()
        }
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundColor(theme.text.opacity(0.6))
            TextField(localize.getText(key: LocaleKey.search.key), text: $searchQuery)
                .cmpNoAutocapitalization()
                .autocorrectionDisabled()
            if !searchQuery.isEmpty {
                Button(action: { searchQuery = "" }) {
                    Image(systemName: "xmark.circle.fill").foregroundColor(theme.text.opacity(0.4))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius).stroke(theme.border, lineWidth: 1))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Intro (description + scope reminder)

    private var intro: some View {
        let pIds = Set(uiState.purposes.map { Int($0.id) })
        let sdIds = Set(uiState.sirdataPurposes.map { Int($0.id) })
        let sfIds = Set(uiState.specialFeatures.map { Int($0.id) })
        return VStack(alignment: .leading, spacing: 8) {
            Text(localize.getText(key: LocaleKey.vendorsDescription.key)
                .processConditionalTags(purposeIds: pIds, sirdataPurposeIds: sdIds, specialFeatureIds: sfIds,
                                        hasLegitimateInterest: uiState.hasLegitimateInterest,
                                        hasCustomPurposes: uiState.hasCustomPurposes,
                                        hasUtiq: uiState.hasUtiq))
                .font(.subheadline)
                .foregroundColor(theme.text.opacity(0.85))
            // Full pipeline (processConditionalTags → buildText → processConditionalTags →
            // processClassnameTags) to resolve self-closing tags (<count/>, <maxAge/>, <scope/>),
            // classname tags (<hostnames>...</hostnames>), and strip remaining HTML — web parity:
            // VendorScope.jsx applies buildText(text) then renders as HTML.
            let rawScope = localize.getText(key: uiState.scopeReminderKey)
            let scope = rawScope
                .processDescriptionPipeline(
                    localize: localize,
                    partnerCount: uiState.partnerCount,
                    scopeKey: uiState.scopeTextKey,
                    maxAgeDays: uiState.maxAgeDays,
                    isApplyWorkflow: uiState.workflow == .applyChoices,
                    noConsentButton: uiState.noConsentButton,
                    closeButton: uiState.closeButton,
                    hasCustomPurposes: uiState.hasCustomPurposes,
                    customPurposeNames: uiState.customPurposeNames,
                    hasGeolocation: uiState.hasGeolocation,
                    dataController: uiState.dataController,
                    cookieDurationSeconds: uiState.cookieDurationSeconds,
                    purposeIds: pIds,
                    sirdataPurposeIds: sdIds,
                    specialFeatureIds: sfIds,
                    hasLegitimateInterest: uiState.hasLegitimateInterest,
                    hasCustomPurposesFlag: uiState.hasCustomPurposes,
                    hasUtiq: uiState.hasUtiq,
                    sirdataStackIds: uiState.sirdataStackIds,
                    setChoicesStyle: uiState.choicesStyle
                )
            if !scope.isEmpty {
                // FRONT-1409 — web parity (`VendorScope.jsx`): each link opens its own
                // target, `<hostnames>` (GROUP) the scope sites and `<websites>`
                // (PROVIDER) the Consent Framework site with its `ui:sites` click. A
                // text without a link (LOCAL, DOMAIN, APP) has nothing tappable — what
                // FRONT-1286 ensured, now carried by the segments themselves.
                BannerTextView(
                    segments: uiState.scopeReminderSegments,
                    fallback: scope,
                    theme: theme,
                    onNavigate: nil,
                    onUiClick: onUiClick,
                    localize: localize,
                    hostnames: uiState.hostnames
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: - Legend

    @ViewBuilder
    private var legend: some View {
        if !uiState.disableTcf {
            let pIds = Set(uiState.purposes.map { Int($0.id) })
            let sdIds = Set(uiState.sirdataPurposes.map { Int($0.id) })
            let sfIds = Set(uiState.specialFeatures.map { Int($0.id) })
            HStack(spacing: 8) {
                Text("IAB TCF")
                    .font(.caption2)
                    .foregroundColor(theme.text.opacity(0.8))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(theme.text.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                Text(localize.getText(key: LocaleKey.iabTcf.key)
                    .processConditionalTags(purposeIds: pIds, sirdataPurposeIds: sdIds, specialFeatureIds: sfIds,
                                            hasLegitimateInterest: uiState.hasLegitimateInterest,
                                            hasCustomPurposes: uiState.hasCustomPurposes,
                                            hasUtiq: uiState.hasUtiq))
                    .font(.caption)
                    .foregroundColor(theme.main)
                    .onTapGesture {
                        if let url = URL(string: "https://iabeurope.eu/transparency-consent-framework/") {
                            UIApplication.shared.open(url)
                        }
                    }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Footer (Reject | Accept | Save)

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                ConsentButton(label: localize.getText(key: LocaleKey.buttonsRejectAll.key), action: onRejectAll, style: .link)
                    .frame(maxWidth: .infinity)
                ConsentButton(label: localize.getText(key: LocaleKey.buttonsAcceptAll.key), action: onAcceptAll, style: .link)
                    .frame(maxWidth: .infinity)
                ConsentButton(label: localize.getText(key: LocaleKey.buttonsSave.key), action: onSave, style: .primary, isPrimary: true)
                    .frame(maxWidth: .infinity)
            }
            .padding(16)
        }
        .background(theme.background)
    }

    // MARK: - Partner list assembly

    private var filteredPartners: [PartnerEntryData] {
        // GAP-V36: Custom vendors first, then other partners sorted alphabetically
        // (web parity: Vendors.jsx:152-161).
        let filtered = allPartners
            .filter { searchQuery.isEmpty || $0.name.localizedCaseInsensitiveContains(searchQuery) }
        let custom = filtered.filter { $0.id.hasPrefix("custom_") }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
        let others = filtered.filter { !$0.id.hasPrefix("custom_") }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
        return custom + others
    }

    // T-V05 / FRONT-1276: the apply screen lists what the view model decided when the screen
    // was entered (ConsentViewModel.ApplyRowPlan, a port of the web's buildPartnerRows), so
    // uiState.partnerEntries is already the list to render.
    //
    // The filter used to live HERE, re-derived per frame from the live toggle values, which
    // cost two bugs the web paid before us: the row vanished the instant its toggle went to
    // accepted — no way to change one's mind — and a click on a fused row passes through
    // intermediate states where the pair looks divergent, which duplicated the partner.
    // Deciding once, in the view model, is also what allows a divergent pair to be split.
    private var allPartners: [PartnerEntryData] { uiState.partnerEntries }
}
