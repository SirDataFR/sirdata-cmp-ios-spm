import SwiftUI
import SirDataCMP

/// PreferenceKey for measuring the scrollable content's ideal height.
private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// PreferenceKey for measuring the footer's height.
private struct FooterHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Main consent banner: logo, title, description, then a primary decision row
/// (Accept + config-driven no-consent button) and a "set choices" action.
///
/// Mirrors Android's `MainBanner`. Layout positioning and the scrim are
/// handled by the parent `ConsentView`; this view renders the card content.
struct MainBannerView: View {
    let uiState: ConsentUiState
    let localize: Localize
    let onAcceptAll: () -> Void
    let onRejectAll: () -> Void
    /// « Continuer sans accepter » — enregistre le choix courant, clic `continue`.
    ///
    /// Séparée de [onCloseSaving] depuis FRONT-1402 : les deux boutons font le MÊME geste
    /// métier (`ConsentView.save(_:)`) et le web les distingue par leur gestionnaire, donc rien
    /// dans l'état ne peut dire lequel a été pressé. Les réunir sous une fermeture unique
    /// rendait l'un des deux clics inattribuable.
    var onContinueWithoutConsent: (() -> Void)? = nil
    /// La croix sous variante CNIL : elle ENREGISTRE, et le web y émet quand même `close`.
    var onCloseSaving: (() -> Void)? = nil
    /// Remonte un clic d'interface qui n'a pas d'autre effet qu'une modale locale — le lien
    /// « voir les sites » du texte du bandeau. Les trois `BannerTextView` le reçoivent.
    var onUiClick: ((UserActionUi) -> Void)? = nil
    let onCustomize: () -> Void
    let onFinish: () -> Void
    var onNavigate: ((ConsentScreen) -> Void)? = nil
    /// Called when the user taps "Ask me later". Falls back to `onFinish` when nil.
    var onAskLater: (() -> Void)? = nil
    /// Maximum height the banner card may occupy (passed from parent via
    /// GeometryReader). When the content is shorter than this, the card wraps
    /// its content instead of stretching to fill the screen.
    var maxHeight: CGFloat = .infinity

    @Environment(\.cmpResolvedTheme) private var theme
    @State private var contentHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Scrollable content: header, title, descriptions, text blocks.
            // Allows long banner texts to be read in full without truncation.
            // The ScrollView is capped at `contentHeight` (ideal height) so it
            // wraps short content without stretching, but scrolls when content
            // exceeds the available `maxHeight - footerHeight`.
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Header: publisher logo top-left (+ optional close button)
                    HStack(alignment: .center) {
                        CmpLogo(height: 36)
                        Spacer()
                        // GAP-M14: Hide close button in cookiewallModify workflow (web parity).
                        if (theme.closeButton || uiState.workflow == .manualDisplay) && uiState.workflow != .cookiewallModify {
                            // CNIL variant parity: closing the banner counts as an explicit
                            // choice and must persist consent (web CMP handleClose behavior).
                            // Otherwise the close button simply dismisses the UI.
                            let onCloseAction: () -> Void = uiState.isCnilVariant ? (onCloseSaving ?? onFinish) : onFinish
                            Button(action: onCloseAction) {
                                Image(systemName: "xmark")
                                    .foregroundColor(theme.text.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(localize.getText(key: LocaleKey.buttonsClose.key))
                        }
                    }
                    .padding(.bottom, 12)

                    // Title (uses the config titleColor, distinct from body text)
                    Text((uiState.title.isEmpty ? localize.getText(key: LocaleKey.mainTitle.key) : uiState.title)
                        .processConditionalTags(
                            purposeIds: Set(uiState.purposes.map { Int($0.id) }),
                            sirdataPurposeIds: Set(uiState.sirdataPurposes.map { Int($0.id) }),
                            specialFeatureIds: Set(uiState.specialFeatures.map { Int($0.id) }),
                            hasLegitimateInterest: uiState.hasLegitimateInterest,
                            hasCustomPurposes: uiState.hasCustomPurposes,
                            hasUtiq: uiState.hasUtiq
                        ))
                        .font(.title3.weight(.semibold))
                        .foregroundColor(theme.title)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityAddTraits(.isHeader)

                    // Custom description (optional publisher text from config)
                    if !uiState.customDescription.isEmpty {
                        Text(uiState.customDescription)
                            .font(.subheadline)
                            .foregroundColor(theme.text.opacity(0.85))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 8)
                    }

                    // Pre-processed scope reminder for the hostnames sheet.
                    // Full pipeline resolves self-closing tags (<count/>, <maxAge/>,
                    // <scope/>), classname tags, and strips remaining HTML — web parity:
                    // VendorScope.jsx applies buildText(text) then renders as HTML.
                    let processedScopeReminder = localize.getText(key: uiState.scopeReminderKey)
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
                            purposeIds: Set(uiState.purposes.map { Int($0.id) }),
                            sirdataPurposeIds: Set(uiState.sirdataPurposes.map { Int($0.id) }),
                            specialFeatureIds: Set(uiState.specialFeatures.map { Int($0.id) }),
                            hasLegitimateInterest: uiState.hasLegitimateInterest,
                            hasCustomPurposesFlag: uiState.hasCustomPurposes,
                            hasUtiq: uiState.hasUtiq,
                            sirdataStackIds: uiState.sirdataStackIds,
                            setChoicesStyle: uiState.choicesStyle
                        )

                    // Text 1 (consent text with purpose/device conditional tags)
                    BannerTextView(
                        segments: uiState.text1Segments,
                        fallback: uiState.text1,
                        theme: theme,
                        onNavigate: onNavigate,
                        onUiClick: onUiClick,
                        localize: localize,
                        hostnames: uiState.hostnames,
                        utiqNoticeUrl: uiState.utiqNoticeUrl,
                        workflow: uiState.workflow,
                        utiqController: uiState.dataController,
                        sirdataPurpose5Name: uiState.sirdataPurposeNameMap[5] ?? "",
                        scopeReminder: processedScopeReminder,
                        utiqActive: uiState.utiqActive
                    )
                    .padding(.top, 8)

                    // Text 2 (data processing details)
                    if !uiState.text2.isEmpty {
                        BannerTextView(
                            segments: uiState.text2Segments,
                            fallback: uiState.text2,
                            theme: theme,
                            onNavigate: onNavigate,
                            onUiClick: onUiClick,
                            localize: localize,
                            hostnames: uiState.hostnames,
                            utiqNoticeUrl: uiState.utiqNoticeUrl,
                            workflow: uiState.workflow,
                            utiqController: uiState.dataController,
                            sirdataPurpose5Name: uiState.sirdataPurposeNameMap[5] ?? "",
                            scopeReminder: processedScopeReminder,
                            utiqActive: uiState.utiqActive
                        )
                        .padding(.top, 8)
                    }

                    // Text 3 (user choices/actions)
                    if !uiState.text3.isEmpty {
                        BannerTextView(
                            segments: uiState.text3Segments,
                            fallback: uiState.text3,
                            theme: theme,
                            onNavigate: onNavigate,
                            onUiClick: onUiClick,
                            localize: localize,
                            hostnames: uiState.hostnames,
                            utiqNoticeUrl: uiState.utiqNoticeUrl,
                            workflow: uiState.workflow,
                            utiqController: uiState.dataController,
                            sirdataPurpose5Name: uiState.sirdataPurposeNameMap[5] ?? "",
                            scopeReminder: processedScopeReminder,
                            utiqActive: uiState.utiqActive
                        )
                        .padding(.top, 8)
                    }
                }
                .padding(20)
                .background(GeometryReader { geo in
                    Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
                })
            }
            .frame(height: contentHeight > 0 ? min(contentHeight, max(0, maxHeight - footerHeight)) : nil)
            .frame(maxHeight: max(0, maxHeight - footerHeight))

            // Fixed footer: primary decision buttons, set choices link, watermark.
            // Stays visible and tappable regardless of scroll position.
            VStack(alignment: .leading, spacing: 0) {
                // Primary decision row — Accept and the no-consent button share the
                // same width and visual level (CNIL: refusing must be as easy as
                // accepting).
                // No-consent action resolved once and reused whether it is rendered
                // inline in the decision row or as a full-width link below it.
                // Manual display workflow forces a REJECT no-consent button
                // regardless of the configured theme value (web parity: Main.jsx).
                // GAP-M06: MainApply workflow — use BUTTONS_APPLY instead of
                // BUTTONS_ACCEPT_ALL, and BUTTONS_DO_NOT_APPLY for the no-consent
                // button (web parity: MainApply.jsx).
                // APPLY_CHOICES force REJECT au même titre que MANUAL_DISPLAY : le libellé
                // passait bien à BUTTONS_DO_NOT_APPLY mais l'action restait dérivée du thème,
                // donc « Ne pas appliquer » APPLIQUAIT les modifications en attente dès que
                // theme.noConsentButton valait CONTINUE ou ASK_LATER, sans jamais atteindre
                // la branche discardPendingChanges() de ConsentView. Parité ConsentActivity.
                let isApplyWorkflow = uiState.workflow == .applyChoices
                let btnType: ThemeNoConsentButton =
                    (uiState.workflow == .manualDisplay || isApplyWorkflow) ? .reject : theme.noConsentButton
                let noConsentLabel: String? = {
                    // GAP-B03: In MANUAL_DISPLAY, hide the reject/no-consent button
                    // (web parity: Main.jsx — only close button is shown).
                    // FRONT-1319 — `NONE` se teste ici, en tête, et sur `theme.noConsentButton` et
                    // non sur `btnType` : le forçage à `.reject` ci-dessus a déjà privé ce dernier
                    // de la valeur `none`, donc `resolveLabel` ne peut plus répondre. Sans ce test,
                    // le mode « appliquer les choix » rendait « Ne pas appliquer » alors que
                    // l'éditeur a explicitement désactivé le bouton de refus, là où le web tient
                    // les deux dans la même condition (`MainApply.getNoConsentButton()`).
                    // `ThemeNoConsentButton.none` est écrit en ENTIER : `.none` se résoudrait
                    // contre `Optional` dans ce contexte optionnel, pas contre l'enum.
                    if uiState.workflow == .manualDisplay
                        || theme.noConsentButton == ThemeNoConsentButton.none {
                        return nil
                    }
                    if isApplyWorkflow {
                        return localize.getText(key: LocaleKey.buttonsDoNotApply.key)
                    }
                    return btnType.resolveLabel(localize)
                }()
                let noConsentAction: () -> Void = {
                    if btnType == ThemeNoConsentButton.continue_ {
                        return onContinueWithoutConsent ?? onFinish
                    } else if btnType == ThemeNoConsentButton.askLater {
                        return onAskLater ?? onFinish
                    } else {
                        return onRejectAll
                    }
                }()
                // Web CMP parity: when noConsentButtonStyle == .link, the no-consent
                // action renders as a full-width text link below the main buttons
                // rather than as a button in the primary decision row.
                let noConsentAsLink = theme.noConsentButtonStyle == .link
                let noConsentAsClose = theme.noConsentButtonStyle == .close

                let acceptLabel = isApplyWorkflow
                    ? localize.getText(key: LocaleKey.buttonsApply.key)
                    : localize.getText(key: LocaleKey.buttonsAccept.key)
                // GAP-M06: In apply workflow, accept calls selectMissingVendors.
                // The actual selectMissingVendors call is handled by ConsentView's
                // acceptAll() which checks the workflow — here we just use onAcceptAll.
                let acceptAction: () -> Void = onAcceptAll
                HStack(spacing: 12) {
                    BannerButton(
                        label: acceptLabel,
                        action: acceptAction,
                        style: .primary,
                        isPrimary: true
                    )
                    .frame(maxWidth: .infinity)
                    .frame(height: 63)

                    // No-consent button rendered inline (button styles only).
                    if let noConsentLabel, !noConsentAsLink, !noConsentAsClose {
                        BannerButton(
                            label: noConsentLabel,
                            action: noConsentAction,
                            style: theme.noConsentButtonStyle.consentButtonStyle,
                            isPrimary: false
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: 63)
                    }
                }
                .padding(.top, 20)

                // No-consent action rendered as a full-width text link below the
                // buttons when the configured style is .link.
                if let noConsentLabel, noConsentAsLink, !noConsentAsClose {
                    ConsentButton(
                        label: noConsentLabel,
                        action: noConsentAction,
                        style: .link,
                        isPrimary: false
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
                }
                // No-consent action rendered as a close (X) button when the
                // configured style is .close.
                if let noConsentLabel, noConsentAsClose {
                    Button(action: noConsentAction) {
                        Image(systemName: "xmark")
                            .font(.title3)
                            .foregroundColor(.secondary)
                    }
                    .accessibilityLabel(noConsentLabel)
                }

                // Customize / Set choices — full width, secondary level
                let setChoicesLabel = localize.getText(key: LocaleKey.buttonsSetChoices.key)
                if !setChoicesLabel.isEmpty && theme.setChoicesStyle != .inText {
                    ConsentButton(
                        label: setChoicesLabel,
                        action: {
                            // Cookie wall workflow: navigate to the Purpose 1 screen
                            // instead of the full purposes screen (web parity).
                            if uiState.workflow == .cookiewallModify, let onNavigate {
                                onNavigate(.purposeOne)
                            } else {
                                onCustomize()
                            }
                        },
                        style: theme.setChoicesStyle.consentButtonStyle
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.top, 10)
                    // Stable hook for UI tests / QA automation.
                    .accessibilityIdentifier("cmp.banner.customize")
                }

                // Provider logo / watermark hidden entirely in white-label mode
                // (web parity: ProviderLogo). SirDataWatermark also self-guards,
                // but gating here avoids reserving layout space.
                if !theme.whiteLabel {
                    SirDataWatermark()
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
            .background(GeometryReader { geo in
                Color.clear.preference(key: FooterHeightKey.self, value: geo.size.height)
            })
        }
        .background(theme.background)
        .animation(.default, value: contentHeight)
        .animation(.default, value: footerHeight)
        .onPreferenceChange(ContentHeightKey.self) { newHeight in
            contentHeight = newHeight
        }
        .onPreferenceChange(FooterHeightKey.self) { newHeight in
            footerHeight = newHeight
        }
    }
}

/// Renders banner text with optional clickable links built from structured segments.
/// Falls back to plain `Text` when no segments are available.
private struct BannerTextView: View {
    let segments: [(text: String, linkType: String?)]
    let fallback: String
    let theme: ResolvedTheme
    let onNavigate: ((ConsentScreen) -> Void)?
    /// FRONT-1402 — le lien « voir les sites » ouvre une modale locale, donc il ne passe pas
    /// par [onNavigate] : sans cette fermeture, son clic `ui:sites` n'était émis nulle part.
    var onUiClick: ((UserActionUi) -> Void)? = nil
    var localize: Localize? = nil
    var hostnames: [String] = []
    var utiqNoticeUrl: String = ""
    var workflow: Workflow = .main
    /// GAP-M07: Utiq data controller name (config.cmp.external.utiq.controller).
    var utiqController: String = ""
    /// GAP-M07: Sirdata purpose 5 name for the Utiq modal title.
    var sirdataPurpose5Name: String = ""
    /// GAP-M17: Pre-processed scope reminder text for the hostnames sheet.
    /// Computed in MainBannerView via processDescriptionPipeline so that
    /// self-closing tags (<count/>, <maxAge/>, <scope/>) and HTML tags are
    /// resolved before display — web parity: VendorScope.jsx buildText(text).
    var scopeReminder: String = ""
    /// GAP-B14: Utiq availability flag passed from MainBannerView to resolve scope error.
    var utiqActive: Bool = false

    // Modal visibility for the informational hostnames / Utiq / Websites links in the banner text.
    @State private var showHostnames = false
    @State private var showUtiq = false
    @State private var showWebsites = false

    var body: some View {
        if segments.isEmpty {
            Text(fallback)
                .font(.subheadline)
                .foregroundColor(theme.text.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if #available(iOS 15, *) {
            linkedText
        } else {
            // iOS 14 fallback: AttributedString/OpenURLAction require iOS 15 —
            // render the segments as plain text (inline links degrade to text;
            // navigation stays available through the banner buttons).
            Text(segments.map { $0.text }.joined())
                .font(.subheadline)
                .foregroundColor(theme.text.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @available(iOS 15, *)
    private var linkedText: some View {
            Text(attributedText)
                .font(.subheadline)
                .foregroundColor(theme.text.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .leading)
                .environment(\.openURL, OpenURLAction { url in
                    guard url.scheme == "cmp-nav" else {
                        return .systemAction
                    }
                    if url.host == "vendors" {
                        // FRONT-1280 — parité web `MainApply.handleLink` : depuis le
                        // bandeau « appliquer les choix », le lien partenaires ouvre la
                        // liste RESTREINTE à ce qui reste à décider, pas la liste
                        // complète. Sans ça le mode « appliquer » annonçait N
                        // partenaires restants et en affichait plusieurs centaines.
                        onNavigate?(workflow == .applyChoices ? .vendorsMissing : .vendors)
                        return .handled
                    } else if url.host == "purposes" {
                        if workflow == .cookiewallModify {
                            onNavigate?(.purposeOne)
                        } else {
                            onNavigate?(.purposes)
                        }
                        return .handled
                    } else if url.host == "hostnames" {
                        showHostnames = true
                        return .handled
                    } else if url.host == "utiq" {
                        showUtiq = true
                        return .handled
                    } else if url.host == "websites" {
                        onUiClick?(UserActionUi.sites)
                        showWebsites = true
                        return .handled
                    }
                    return .handled
                })
                // Hostnames modal — lists the hostnames the CMP scope applies to.
                // GAP-M17: Include scope reminder text in the hostnames sheet.
                .sheet(isPresented: $showHostnames) {
                    HostnamesSheet(
                        hostnames: hostnames,
                        utiqNoticeUrl: nil,
                        localize: localize,
                        theme: theme,
                        scopeReminder: scopeReminder
                    )
                }
                // Utiq modal — GAP-M07: data controller PlusBox with controller name
                // and clickable notice URL (web parity: Text5.jsx).
                .sheet(isPresented: Binding(get: { showUtiq && utiqActive }, set: { showUtiq = $0 })) {
                    HostnamesSheet(
                        hostnames: nil,
                        utiqNoticeUrl: utiqNoticeUrl,
                        localize: localize,
                        theme: theme,
                        utiqController: utiqController,
                        sirdataPurpose5Name: sirdataPurpose5Name
                    )
                }
                // Websites modal — lists the consent framework websites.
                .sheet(isPresented: $showWebsites) {
                    WebsitesSheet(theme: theme, localize: localize)
                }
    }

    @available(iOS 15, *)
    private var attributedText: AttributedString {
        var result = AttributedString()
        for segment in segments {
            var attr = AttributedString(segment.text)
            if let linkType = segment.linkType {
                let linkKey = "cmp-nav://\(linkType.lowercased())"
                if let url = URL(string: linkKey) {
                    attr.link = url
                    attr.foregroundColor = theme.main
                    attr.underlineStyle = .single
                }
            }
            result += attr
        }
        return result
    }
}

/// Informational sheet used for the banner "hostnames" and "utiq" links.
/// When `hostnames` is non-nil it lists the CMP scope hostnames; when
/// `utiqNoticeUrl` is non-nil it shows the Utiq notice link. Mirrors the
/// Android `AlertDialog` blocks in `MainBanner`.
struct HostnamesSheet: View {
    let hostnames: [String]?
    let utiqNoticeUrl: String?
    let localize: Localize?
    let theme: ResolvedTheme
    /// GAP-M07: Utiq data controller name and sirdata purpose 5 name for the
    /// PlusBox-style expandable section (web parity: Text5.jsx).
    var utiqController: String = ""
    var sirdataPurpose5Name: String = ""
    /// GAP-M17: Scope reminder text shown at the top of the hostnames sheet.
    var scopeReminder: String = ""

    // iOS 14 compat: \.dismiss requires iOS 15.
    @Environment(\.presentationMode) private var presentationMode
    @State private var utiqExpanded = false

    var body: some View {
        let isUtiq = utiqNoticeUrl != nil
        let closeLabel = localize?.getText(key: LocaleKey.buttonsClose.key) ?? "Close"
        let title = isUtiq
            ? (sirdataPurpose5Name.isEmpty ? "Utiq" : sirdataPurpose5Name)
            : (localize?.getText(key: LocaleKey.hostnamesTitle.key) ?? "")
        let description = isUtiq
            ? ""
            : (localize?.getText(key: LocaleKey.hostnamesDescription.key) ?? "")

        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    // GAP-M17: Scope reminder text at the top of the hostnames sheet.
                    if !scopeReminder.isEmpty {
                        Text(scopeReminder)
                            .font(.subheadline)
                            .foregroundColor(theme.main)
                    }
                    // `hostnames.description` carries real HTML (`<br/><br/>`
                    // between its three paragraphs) — web parity:
                    // Hostnames.jsx renders it via dangerouslySetInnerHTML.
                    if !description.isEmpty {
                        Group {
                            if #available(iOS 15, *), let attr = description.htmlToAttributedString {
                                Text(attr)
                            } else {
                                Text(description.htmlToPlainText)
                            }
                        }
                        .font(.body)
                        .foregroundColor(theme.text)
                    }
                    if let hosts = hostnames {
                        ForEach(Array(hosts.enumerated()), id: \.offset) { _, host in
                            Text(host)
                                .font(.caption)
                                .foregroundColor(theme.text.opacity(0.85))
                        }
                    }
                    // GAP-M07: Utiq data controller PlusBox (web parity: Text5.jsx).
                    // Shows the data controller name and a clickable link to the
                    // Utiq notice URL in an expandable section.
                    if isUtiq {
                        if !utiqController.isEmpty {
                            Text(utiqController)
                                .font(.body)
                                .foregroundColor(theme.text)
                                .padding(.top, 4)
                        }
                        if let url = utiqNoticeUrl, !url.isEmpty, let link = URL(string: url) {
                            // Underline lives on the inner Text (iOS 13+); the View-level
                            // .underline() modifier requires iOS 16 and broke the iOS 14 target.
                            Link(destination: link) {
                                Text(localize?.getText(key: "buttons.moreInfo") ?? url)
                                    .font(.body)
                                    .foregroundColor(theme.main)
                                    .underline()
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .navigationTitle(title.isEmpty ? " " : title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(closeLabel) { presentationMode.wrappedValue.dismiss() }
                }
            }
        }
    }
}

/// Informational sheet listing the consent framework websites.
private struct WebsitesSheet: View {
    let theme: ResolvedTheme
    var localize: Localize? = nil

    // iOS 14 compat: \.dismiss requires iOS 15.
    @Environment(\.presentationMode) private var presentationMode
    @Environment(\.openURL) private var openURL

    private let websites = [
        "https://www.consentframework.com/"
    ]

    var body: some View {
        let closeLabel = localize?.getText(key: LocaleKey.buttonsClose.key) ?? "Close"
        let title = localize?.getText(key: LocaleKey.websitesTitle.key) ?? ""
        NavigationView {
            VStack(spacing: 16) {
                ForEach(websites, id: \.self) { website in
                    Text(website)
                        .font(.subheadline)
                        .foregroundColor(theme.main)
                        .underline()
                        .onTapGesture {
                            if let url = URL(string: website) {
                                openURL(url)
                            }
                        }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(title.isEmpty ? " " : title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(closeLabel) { presentationMode.wrappedValue.dismiss() }
                }
            }
        }
    }
}
