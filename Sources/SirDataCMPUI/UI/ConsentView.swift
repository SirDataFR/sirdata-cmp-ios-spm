import SwiftUI
import UIKit
// `@preconcurrency`: SirDataCMP is a Kotlin/Native framework whose exported
// types (e.g. ThemePosition) don't carry Sendable conformance. Without this,
// SwiftUI's implicitly-Sendable Shape (BannerCardShape) warns about its
// non-Sendable `position` property under strict concurrency checking.
@preconcurrency import SirDataCMP

/// Root SwiftUI view for the consent management UI.
///
/// Uses simple state-based navigation between MAIN, PURPOSES, and VENDORS
/// screens, mirroring Android's `ConsentActivity` screen routing. The MAIN
/// banner renders as a compact card over a scrim, positioned per the config
/// theme (top / center / bottom / bottom-left / bottom-right); the
/// purposes/vendors screens are full-height list screens.
///
/// ## Usage
/// ```swift
/// .sheet(isPresented: $showConsent) {
///     ConsentView(onFinish: { showConsent = false })
/// }
/// ```
///
/// **Important**: Call `IosCMPApi.shared.notifyBannerShown()` before presenting
/// to fire the `cmpuishown` event per IAB TCF spec. `notifyBannerClosed()` is
/// fired automatically when this view finishes.
public struct ConsentView: View {
    @StateObject private var viewModel: ConsentViewModel
    @Environment(\.colorScheme) private var colorScheme
    let onFinish: () -> Void
    /// Optional screen to open once the CMP is loaded (e.g. `.purposes` to
    /// deep-link straight into the preferences screen). nil = main banner.
    let initialScreen: ConsentScreen?
    @State private var didApplyInitialScreen = false
    /// Set by `finish()`, the exit every gesture of ours goes through (FRONT-1408).
    @State private var didExit = false

    /// - Parameters:
    ///   - onFinish: called when the user is done with the banner.
    ///   - initialScreen: screen to open once the CMP is loaded. nil = main banner.
    ///   - workflow: how to present the banner. nil (the default) asks the shared
    ///     decision cascade — a partially answered consent then opens in "apply
    ///     choices" mode, which only asks about what is left to decide. Pass
    ///     `.manualDisplay` when re-opening from a settings screen.
    public init(
        onFinish: @escaping () -> Void,
        initialScreen: ConsentScreen? = nil,
        workflow: Workflow? = nil
    ) {
        self.onFinish = onFinish
        self.initialScreen = initialScreen
        _viewModel = StateObject(wrappedValue: ConsentViewModel(workflow: workflow))
    }

    private var resolvedTheme: ResolvedTheme {
        ResolvedTheme(theme: viewModel.theme, colorScheme: colorScheme)
    }

    public var body: some View {
        Group {
            // `theme == nil` means the publisher config hasn't loaded yet — show
            // a neutral spinner rather than the default-blue banner, so the UI
            // never flashes an unbranded placeholder before the real CMP appears.
            if viewModel.uiState.isLoading || viewModel.theme == nil {
                ProgressView()
                    .cmpTint(.secondary)
                    .accessibilityLabel("Loading consent options")
            } else if let error = viewModel.uiState.error, viewModel.uiState.currentScreen == ConsentScreen.main {
                errorView(message: error)
            } else {
                screenContent
            }
        }
        // FRONT-1435 — la banniere est une MODALE : VoiceOver ne doit pas atteindre
        // la page de l'editeur derriere elle. Presentee en `.sheet` iOS le fait deja ;
        // presentee en surimpression — ce que la carte compacte sur voile EST — il n'y
        // a rien qui le dise, et le trait est alors le seul canal. Redondant dans un
        // cas, load-bearing dans l'autre.
        .accessibilityAddTraits(.isModal)
        // Applies the config theme's colors/radius/text-scale to all screens.
        .cmpTheme(viewModel.theme)
        // Publishes the four localized toggle-state names so every ConsentToggle
        // can name its state for assistive technologies without threading a
        // parameter through ten call sites. Recomputed only when the screen
        // structure is rebuilt, never per render.
        .environment(\.cmpToggleStateNames, viewModel.toggleStateNames)
        // FRONT-1335 volet 4 — le sens de lecture de la BANNIÈRE, jamais celui de
        // l'application hôte. `.leftToRight` est aussi load-bearing que `.rightToLeft` :
        // c'est lui qui ferme l'héritage pour les 48 langues gauche-droite.
        .environment(\.layoutDirection, viewModel.isRightToLeft ? .rightToLeft : .leftToRight)
        // Observe askLater dismissal — mirrors Android Channel<_consentSubmitted>
        .onChange(of: viewModel.shouldDismiss) { newValue in
            if newValue { finish() }
        }
        // Deep-link to the requested screen once loading settles.
        .onChange(of: viewModel.uiState.isLoading) { isLoading in
            applyInitialScreenIfNeeded(isLoading: isLoading)
        }
        .onAppear {
            applyInitialScreenIfNeeded(isLoading: viewModel.uiState.isLoading)
            // FRONT-1280 — the manual-reopen prompt is recorded when the banner
            // actually appears, not when the view model is built. SwiftUI constructs a
            // `StateObject` as soon as the view is installed in a hierarchy — an
            // eagerly created tab, a navigation destination, a hidden overlay — so
            // doing it in `init` restarted the `cappingInDays` window for a banner the
            // user never saw, and could suppress a later automatic prompt because a
            // settings screen had merely been constructed (Codex, P2).
            viewModel.recordManualPromptIfNeeded()
        }
        // FRONT-1408 — the host owns the presentation (`.sheet`), so a swipe-down
        // never goes through our code. The only thing the SDK can see is the view
        // leaving the screen without having taken one of its own exits.
        .onDisappear { reportHostDismissalIfNeeded() }
    }

    private func applyInitialScreenIfNeeded(isLoading: Bool) {
        guard !isLoading, !didApplyInitialScreen, let screen = initialScreen else { return }
        didApplyInitialScreen = true
        viewModel.navigateTo(screen: screen)
    }

    // MARK: - Screen Routing (mirrors Android ConsentActivity)

    @ViewBuilder
    private var screenContent: some View {
        let screen = viewModel.uiState.currentScreen
        // FRONT-1342 — l'écran US remplace la cascade TCF en entier, comme le web où
        // `resolveJsVersion` ne sert le bundle CCPA qu'aux visiteurs des États-Unis.
        //
        // Routé par une CONDITION, jamais par une valeur de `ConsentScreen` : cet enum est
        // encodé dans le champ `consentScreen` de la TC string (6 bits, unités 1 à 6), donc
        // un septième écran y fuirait. Même patron que le cookiewall juste en dessous.
        if let usNat = viewModel.uiState.usNat {
            UsNatView(
                data: usNat,
                privacyPolicyUrl: viewModel.uiState.privacyPolicyUrl,
                onToggle: { viewModel.toggleUsNatOptOut() },
                onSave: {
                    viewModel.commitUsNatOptOut()
                    finish()
                },
                // `closeUsNat()` NU, jamais `onSave` : refermer sans enregistrer ne persiste
                // rien (parité web, son fix I1). Le seul geste qui écrit est le bouton — la
                // fermeture, elle, est rapportée depuis FRONT-1404.
                onClose: { closeUsNat() }
            )
        // GAP-M01: Cookiewall screen — shown when workflow is .cookiewall on the
        // main screen (web parity: MainCookiewall.jsx).
        } else if screen == ConsentScreen.main && viewModel.uiState.workflow == .cookiewall {
            CookiewallView(
                uiState: viewModel.uiState,
                localize: viewModel.getLocalize(),
                onModify: {
                    // FRONT-1402 — ce bouton émet `cw_modify_choices` et NON une navigation :
                    // le web ne navigue même pas dessus, l'UI mobile a réuni deux temps en un
                    // geste. D'où `navigateTo` nu juste en dessous, jamais `navigateReported`.
                    viewModel.reportUiClick(UserActionUi.cookiewallModifyChoices)
                    // Web parity: set workflow to COOKIEWALL_MODIFY and navigate
                    // to the PurposeOne screen. Through `setWorkflow` so the
                    // transition also settles the workflow — the decision cascade
                    // must not re-derive it on the next save (Codex, P1).
                    viewModel.setWorkflow(.cookiewallModify)
                    viewModel.navigateTo(screen: .purposeOne)
                }
            )
        } else if screen == ConsentScreen.purposeOne {
            // GAP-M02: PurposeOne dedicated UI (web parity: PurposeOne.jsx).
            PurposeOneView(
                uiState: viewModel.uiState,
                localize: viewModel.getLocalize(),
                onAccept: {
                    // FRONT-1402 — `cw_accept_cookies` est une action de NAVIGATION et non un
                    // clic terminal : le web persiste puis ouvre les finalités, donc la réponse
                    // arrive bien, mais d'un geste ultérieur. L'y ranger parmi les six clics
                    // terminaux ferait apparaître un écart permanent dans le détecteur de perte
                    // de hits de BACK-960 chez tout partenaire à cookiewall.
                    viewModel.reportUiClick(UserActionUi.cookiewallAcceptCookies)
                    viewModel.selectPurpose(id: 1, isSelected: true)
                    // GAP-CW-01/02/03/05: Use submitPurposeOneConsent for proper
                    // consentScreen tracking, lastPrompt update, ACCEPT action,
                    // and navigation without finishing the activity.
                    viewModel.submitPurposeOneConsent()
                },
                onClose: {
                    // Web parity: dismiss without saving.
                    navigateReported(to: ConsentScreen.main)
                }
            )
        } else if screen == ConsentScreen.purposes {
            // All row/toggle interactions flow through the single intent
            // funnel: the ViewModel resolves targets from the LIVE selector
            // state, never from a rendered (possibly stale) value.
            PurposesView(
                uiState: viewModel.uiState,
                toggles: viewModel.toggles,
                localize: viewModel.getLocalize(),
                send: { viewModel.send($0) },
                onBack: { navigateReported(to: ConsentScreen.main) },
                onViewPartners: { navigateReported(to: ConsentScreen.vendors) },
                onAcceptAll: { acceptAll() },
                onRejectAll: { rejectAll() },
                onSave: { save(UserActionUi.save) },
                onUiClick: { viewModel.reportUiClick($0) }
            )
        } else if screen == ConsentScreen.vendors || screen == ConsentScreen.vendorsMissing {
            VendorsView(
                uiState: viewModel.uiState,
                toggles: viewModel.toggles,
                localize: viewModel.getLocalize(),
                send: { viewModel.send($0) },
                onBack: { navigateReported(to: ConsentScreen.purposes) },
                onAcceptAll: { acceptAll() },
                onRejectAll: { rejectAll() },
                onSave: { save(UserActionUi.save) },
                onClose: { closeDismissing() },
                onUiClick: { viewModel.reportUiClick($0) }
            )
        } else {
            // MAIN and MAIN_MISSING (and any unknown screen): banner over scrim.
            bannerContainer
        }
    }

    // MARK: - Positioned banner + scrim (mirrors Android ConsentScreen)

    private var bannerContainer: some View {
        let theme = resolvedTheme
        return GeometryReader { geo in
            ZStack(alignment: bannerAlignment(theme.position)) {
                theme.overlay
                    .ignoresSafeArea()

                MainBannerView(
                    uiState: viewModel.uiState,
                    localize: viewModel.getLocalize(),
                    onAcceptAll: { acceptAll() },
                    onRejectAll: { rejectAll() },
                    onContinueWithoutConsent: { save(UserActionUi.continue_) },
                    onCloseSaving: { save(UserActionUi.close) },
                    onUiClick: { viewModel.reportUiClick($0) },
                    onCustomize: { navigateReported(to: ConsentScreen.purposes) },
                    onFinish: { closeDismissing() },
                    onNavigate: { navigateReported(to: $0) },
                    onAskLater: {
                        viewModel.reportUiClick(UserActionUi.askLater)
                        viewModel.askLater()
                    },
                    maxHeight: geo.size.height * 0.9
                )
                // Web parity: the banner card takes the configured radius as-is
                // (layout.less `.wrapper { border-radius: var(--border-radius) }`).
                .clipShape(BannerCardShape(position: theme.position, radius: theme.cornerRadius))
                // Feuille du bas : le fond de la carte descend sous la barre d'accueil, le contenu
                // reste au-dessus. Sans ça, la carte s'arrêtait au bord de la zone sûre et
                // laissait voir le voile sur ~34 pt : une carte qui paraissait coupée net. Même
                // forme que la carte, sinon ses coins arrondis du haut seraient comblés. Parité
                // Android, où la feuille touche la barre de navigation ; le web, lui, laisse une
                // marge tout autour de la carte (`layout.less`, `@modal-margin-mobile`).
                .background(alignment: .bottom) {
                    if isBottomSheet(theme.position) {
                        BannerCardShape(position: theme.position, radius: theme.cornerRadius)
                            .fill(theme.background)
                            .ignoresSafeArea(.container, edges: .bottom)
                    }
                }
                .padding(bannerPadding(theme.position))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(.default, value: viewModel.uiState.currentScreen)
    }

    private func bannerAlignment(_ position: ThemePosition) -> Alignment {
        if position == ThemePosition.top { return .top }
        if position == ThemePosition.center { return .center }
        if position == ThemePosition.bottomLeft { return .bottomLeading }
        if position == ThemePosition.bottomRight { return .bottomTrailing }
        return .bottom
    }

    /// Les positions où la carte est une feuille collée au bas de l'écran : celles dont
    /// `BannerCardShape` arrondit les coins du haut.
    private func isBottomSheet(_ position: ThemePosition) -> Bool {
        position != ThemePosition.center && position != ThemePosition.top
    }

    private func bannerPadding(_ position: ThemePosition) -> EdgeInsets {
        if position == ThemePosition.center {
            return EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
        }
        return EdgeInsets()
    }

    // MARK: - Error State

    private func errorView(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundColor(.secondary)
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button("Close") { finish() }
        }
        .padding()
    }

    // MARK: - Actions

    private func acceptAll() {
        viewModel.reportUiClick(UserActionUi.accept)
        // T-V05: In VENDORS_MISSING, Accept selects only missing vendors (web parity)
        // GAP-M06: In APPLY_CHOICES workflow, Accept also calls selectMissingVendors (web parity: MainApply.jsx)
        if viewModel.uiState.currentScreen == .vendorsMissing || viewModel.uiState.workflow == .applyChoices {
            viewModel.selectMissingVendors()
        } else {
            viewModel.selectAll(isSelected: true)
        }
        // GAP-B07: Set consentScreen before saving (web parity: Main.jsx handleAccept)
        //
        // FRONT-1284 — in the "apply choices" workflow this records MAIN_MISSING, not
        // MAIN: that is what `MainApply.jsx:36` does, where `Main.jsx` sets MAIN on all
        // three of its buttons. Reject and save keep MAIN — see the KDoc on Android's
        // `markMainScreen` for why the web's own reject path is not copied.
        if viewModel.uiState.currentScreen == .main || viewModel.uiState.currentScreen == .mainMissing {
            viewModel.setConsentScreenForSave(isAccept: true)
        }
        Task {
            await viewModel.submitConsent(action: UserActionResponse.accept)
            if viewModel.uiState.error == nil { finish() }
        }
    }

    private func rejectAll() {
        viewModel.reportUiClick(UserActionUi.reject)
        // T-V05: In VENDORS_MISSING, Reject saves without modifying selections (web parity)
        //
        // FRONT-1280 — same exemption in the "apply choices" workflow, and it is
        // mandatory there: the refusal button reads "Do not apply"
        // (`BUTTONS_DO_NOT_APPLY`), which a user takes to mean "do not add these new
        // partners". `selectAll(false)` destroyed the **already stored** consent —
        // every purpose and vendor off in the TC string, forwarded to the adapters.
        // The web does the opposite: `MainApply.handleReject` calls
        // `onSave(..., true)`, and `ignoreUpdate` persists `persistedConsentData`,
        // i.e. the stored choice untouched (`store.js:434`).
        if viewModel.uiState.workflow == .applyChoices {
            // Not merely skipping `selectAll(false)`: submission encodes the **live**
            // selections, so the button applied exactly the changes it promises to
            // discard (Codex, P1). Return to the stored choice first — what
            // `ignoreUpdate` does on the web.
            IosCMPApi.shared.discardPendingChanges()
        } else if viewModel.uiState.currentScreen != .vendorsMissing {
            viewModel.selectAll(isSelected: false)
        }
        // GAP-B07: Set consentScreen = MAIN before saving (web parity: Main.jsx handleReject)
        if viewModel.uiState.currentScreen == .main || viewModel.uiState.currentScreen == .mainMissing {
            viewModel.setConsentScreenForSave()
        }
        Task {
            await viewModel.submitConsent(action: UserActionResponse.reject)
            if viewModel.uiState.error == nil { finish() }
        }
    }

    /// Le corps commun des TROIS boutons qui enregistrent le choix courant — FRONT-1402.
    ///
    /// « Enregistrer » du pied de page des écrans de détail, « Continuer sans accepter » quand
    /// `theme.noConsentButton` vaut `CONTINUE`, et la croix sous variante CNIL passent tous par
    /// `submitConsent(getActionResponse())` : rien dans l'état ne peut dire lequel a été pressé,
    /// alors que le web émet `save`, `continue` et `close` depuis trois gestionnaires distincts.
    /// D'où le clic en PARAMÈTRE — c'est une propriété du site d'appel, pas de l'état.
    ///
    /// Le clic est rapporté AVANT l'enregistrement, et ce n'est **PAS** la parité web —
    /// vérifié plutôt que supposé, à la demande de la revue : `Main.jsx` et `Details.jsx`
    /// appellent `onSave(...)` **puis** `onUIClick(...)`. Leur émission étant synchrone,
    /// l'ordre y est sans conséquence.
    ///
    /// Ici il en a une : `submitConsent` referme l'écran en cas de succès, donc rapporter
    /// après ferait partir le hit pendant le démontage. Android fait pareil, pour la même
    /// raison.
    private func save(_ click: UserActionUi) {
        viewModel.reportUiClick(click)
        // GAP-B07: Set consentScreen = MAIN before saving (web parity: Main.jsx handleContinue)
        if viewModel.uiState.currentScreen == .main || viewModel.uiState.currentScreen == .mainMissing {
            viewModel.setConsentScreenForSave()
        }
        Task {
            await viewModel.submitConsent(action: viewModel.getActionResponse())
            if viewModel.uiState.error == nil { finish() }
        }
    }

    /// La croix qui ne persiste RIEN, et qui rapporte quand même son clic.
    ///
    /// `Main.handleClose` du web émet `CLOSE` dans ses DEUX branches. Le report ne peut pas
    /// vivre dans [finish], qui est aussi le point de sortie d'un enregistrement réussi : y
    /// poser le hit ferait suivre chaque « Tout accepter » d'un `ui:close` fantôme.
    ///
    /// Comme le web, la réponse `response:close` est appelée avant le clic (sur le web, elle ne
    /// part qu'après `yieldToPaint()`, donc après le clic sur le réseau) — FRONT-1480.
    private func closeDismissing() {
        viewModel.reportCloseResponse()
        viewModel.reportUiClick(UserActionUi.close)
        finish()
    }

    /// La croix de l'écran US — `ccpa_response:close` et jamais un `ui` (FRONT-1404).
    ///
    /// `finish()` reste NU derrière le report : refermer sans valider ne persiste rien, c'est
    /// l'arbitrage du fix I1 de FRONT-1342 et il ne bouge pas ici.
    private func closeUsNat() {
        viewModel.reportCcpaClose()
        finish()
    }

    /// Navigue en rapportant le geste — FRONT-1402.
    ///
    /// L'ordre est load-bearing : le report lit l'écran d'ORIGINE, que `navigateTo` écrase. Le
    /// résolveur de `SirDataCMP.postUiNavigation` décide seul de ce qui sort (`purposes` depuis
    /// le bandeau, `see_purposes` depuis un écran de détail, RIEN pour un retour au bandeau),
    /// donc ce site n'a aucune règle à connaître.
    ///
    /// Deux navigations n'y passent PAS, délibérément : l'application de l'écran initial, qui
    /// n'est le clic de personne, et le « Modifier mes choix » du cookiewall, qui émet son
    /// propre `cw_modify_choices` — le web ne navigue même pas sur ce bouton-là.
    private func navigateReported(to screen: ConsentScreen) {
        viewModel.reportUiNavigation(to: screen)
        viewModel.navigateTo(screen: screen)
    }

    private func finish() {
        // A swipe-down may have closed the banner while a save was in flight: the
        // UI-closed event has then already been fired.
        if !didExit { IosCMPManager.shared.notifyBannerClosed() }
        didExit = true
        onFinish()
    }

    /// The host closed the banner (swipe-down on its sheet) — FRONT-1408.
    ///
    /// Same report as the cross that persists NOTHING (`response:close` then `ui:close`,
    /// or `ccpa_response:close` on the US screen), never the CNIL saving cross: a
    /// dismissal gesture is not a recognised way of refusing (FRONT-1355). Nothing is
    /// persisted, so the banner shows again on the next launch — exactly as before, only
    /// now it is counted.
    ///
    /// Chosen over `interactiveDismissDisabled()`, which would change the host's sheet.
    /// Known limit: any removal of `ConsentView` from the screen without one of our exits
    /// counts as a close — e.g. a host that pushes another view over it.
    private func reportHostDismissalIfNeeded() {
        guard !didExit, !viewModel.uiState.isLoading, viewModel.theme != nil else { return }
        didExit = true
        if viewModel.uiState.usNat != nil {
            viewModel.reportCcpaClose()
        } else {
            // FRONT-1480 — the same pair as the cross (`closeDismissing`), Android's system back
            // and the web's Escape key (`App.onEscape`), called in the same order as those
            // handlers. This is not a network order: the web posts `response:close` after
            // `yieldToPaint()`, so after the click.
            viewModel.reportCloseResponse()
            viewModel.reportUiClick(UserActionUi.close)
        }
        IosCMPManager.shared.notifyBannerClosed()
    }
}

/// Card shape for the main banner: rounds the corners facing the screen
/// interior based on the banner position (top → bottom corners, bottom → top
/// corners, center → all corners). Mirrors Android's `cardShape`.
private struct BannerCardShape: Shape {
    let position: ThemePosition
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let corners: UIRectCorner
        if position == ThemePosition.center {
            corners = .allCorners
        } else if position == ThemePosition.top {
            corners = [.bottomLeft, .bottomRight]
        } else {
            corners = [.topLeft, .topRight]
        }
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}
