import Foundation
import Combine
import SirDataCMP

/// ViewModel driving the consent management SwiftUI UI.
///
/// Observes `ConsentStore.updateCounter` and `ConsentStore.state` to rebuild
/// `ConsentUiState` on every selection change, then publishes it for SwiftUI views.
@MainActor
class ConsentViewModel: ObservableObject {

    /// Screen STRUCTURE + navigation + expansion. Changes on load, navigation,
    /// workflow changes and expand taps — NEVER on a consent tap.
    @Published var uiState: ConsentUiState = ConsentUiState()

    /// Live toggle values (small key→"ON"/"OFF"/"" maps). The ONLY state a
    /// consent tap updates; published once per tap, only when a value changed.
    @Published var toggles: TogglesState = TogglesState()

    @Published var shouldDismiss = false

    private let cmp: SirDataCMP
    private let store: ConsentStore
    private let selector: ConsentSelector
    private let localize: Localize

    /// The CMP theme configuration from the shared core settings.
    /// Optional: the Kotlin Theme data class has no no-arg init exported to
    /// Swift (defaults are not exported), so nil = use built-in defaults.
    /// Computed (not stored): the config is fetched asynchronously, so the
    /// theme may only become available after this ViewModel is created.
    var theme: Theme? { cmp.config?.cmp.theme }

    /// Was a workflow explicitly requested at presentation time?
    private let workflowWasExplicit: Bool

    /// Is the workflow settled? One-way latch, set by the first adoption of the
    /// decision and by any in-UI transition (`setWorkflow`). See
    /// `adoptDecidedWorkflowIfUnset` for what it prevents.
    private var workflowSettled = false

    /// Has the manual-reopen prompt already been recorded? See
    /// `recordManualPromptIfNeeded()`.
    private var didRecordManualPrompt = false

    /// FRONT-1342 — le choix US en attente, `nil` tant que personne n'a touché au contrôle.
    ///
    /// Le seul geste qui PERSISTE est le bouton d'enregistrement : la bascule n'écrit que ce
    /// champ, et la croix n'écrit rien. C'est la parité web, que le web a payée en quatre
    /// cycles de revue — `store.setUsNatOptOut` « ne fait QUE l'état », seul `onSubmit`
    /// appelle `collectUsNatChoices()` puis `persist()`, et son fix I1 dit mot pour mot
    /// « la croix ne persiste RIEN ». Persister à chaque tap ferait enregistrer une
    /// opposition à qui bascule puis referme, et un « non opposé » à qui bascule deux fois —
    /// pire, la §7 codant `2` « Did Not Opt Out » et la spec y couplant une notice fournie.
    private var usNatPendingOptOut: Bool?

    private var stateWatcher: ConsentStateWatcher?
    private var counterWatcher: UpdateCounterWatcher?

    /// Static data computed once at load (lists, texts, config, name maps).
    /// Invalidated and rebuilt when language/config changes.
    private var staticData: ConsentStaticData?

    /// The four localized toggle-state names, published to the views through the
    /// `cmpToggleStateNames` environment value. Structure, not value: refreshed
    /// with the screen structure (which is where the locales settle), never on a
    /// consent tap — so it costs four bridged calls per rebuild, not per render.
    private(set) var toggleStateNames = ToggleStateNames()

    /// FRONT-1335 volet 4 — sens de lecture de la BANNIÈRE, que `ConsentView` traduit en
    /// l'environnement `layoutDirection` de SwiftUI.
    ///
    /// Sans lui, `layoutDirection` vaut celui de l'APPLICATION HÔTE : une application arabe
    /// affichant une bannière française la miroitait, et une application française affichant
    /// une bannière arabe ne la miroitait pas. C'est le défaut que FRONT-1323 a fermé sur le
    /// web, où `div#abconsentcmp` héritait du `dir` de la page de l'éditeur — d'où `.leftToRight`
    /// posé aussi explicitement que `.rightToLeft`.
    ///
    /// Structure, pas valeur : rafraîchi avec `rebuildStructure()`, qui est aussi l'endroit où
    /// les locales se fixent — jamais sur un tap de consentement, jamais dans un `body`.
    ///
    /// La règle elle-même vit en Kotlin partagé (`Language.getTextDirection`,
    /// `shared/src/commonMain/.../settings/Language.kt`, testée dans `commonTest`), et Android
    /// la lit là. Ici elle est **mirroitée en Swift** délibérément : nommer le symbole Kotlin
    /// neuf empêcherait tout client SPM de compiler jusqu'à la régénération du binaire
    /// (règle FRONT-1274, gardée par `scripts/check-ios-abi.sh --consumers`). Ce miroir lit
    /// `Language.code`, qui est déjà dans le binaire committé. À faire converger sur le Kotlin
    /// dès qu'une PR ultérieure part d'un binaire qui porte `getTextDirection`.
    ///
    /// Publié en **`Bool`** et non en `LayoutDirection` : ce fichier n'importe que `Foundation`,
    /// `Combine` et `SirDataCMP`, jamais SwiftUI. Y nommer un type SwiftUI a cassé l'archive du
    /// run 255 (`cannot find type 'LayoutDirection' in scope`) — une classe d'erreur que ni
    /// `ci.yml` ni aucun contrôle local ne voit, seul `testflight.yml` compilant le Swift. Le
    /// type SwiftUI vit donc dans `ConsentView`, qui l'importe.
    private(set) var isRightToLeft: Bool = false

    /// Miroir Swift de `Language.getTextDirection` (cf. `isRightToLeft` ci-dessus).
    ///
    /// Teste les DEUX PREMIÈRES LETTRES en minuscules, jamais l'égalité, à l'identique du
    /// Kotlin et du web : `he-IL`, `ar-EG` et `AR` doivent répondre droite-à-gauche. Sûr parce
    /// que l'entrée est canonique — `localize.getLanguage()` rend un `Language`, donc `.code`
    /// est l'une des 50 valeurs déclarées.
    ///
    /// Cet ensemble ne SUIT PAS l'élargissement aux 50 langues : aucune des 32 ajoutées n'est
    /// de droite à gauche, et le persan comme l'ourdou ne sont pas servis par l'API.
    private static let rtlCodes: Set<String> = ["ar", "he"]

    private static func resolveIsRightToLeft(_ languageCode: String) -> Bool {
        rtlCodes.contains(String(languageCode.prefix(2)).lowercased())
    }

    /// - Parameter workflow: the workflow to present in. `nil` asks the shared
    ///   decision cascade (`WorkflowEngine`), which is what a startup presentation
    ///   wants. Pass `.manualDisplay` explicitly when re-opening from a settings
    ///   screen: the decision cascade answers "what is left to ask?", a different
    ///   question from "the user asked to review their choices".
    init(workflow: Workflow? = nil) {
        let cmpInstance = IosCMPManager.shared.get()
        self.cmp = cmpInstance
        self.store = cmpInstance.getStore()
        self.selector = cmpInstance.getSelector()
        self.localize = cmpInstance.getLocalize()

        // FRONT-1280 — posé AVANT la première construction de structure : les textes
        // du bandeau en dépendent (`isApplyWorkflow` choisit TEXT4 au lieu de TEXT3)
        // et `rebuildStructure()` ne se rejoue pas sur un tap de consentement.
        self.workflowWasExplicit = workflow != nil
        self.uiState.workflow = workflow ?? IosCMPApi.shared.getConsentDisplayDecision().workflow

        // FRONT-1280 — the `cappingInDays` window restarts ONLY on a user-requested
        // re-open, never on an automatic display: on the web `updateLastPrompt()` is
        // called by `displayUI()` and the toolbar (manual re-opens), by save and by
        // purpose-one accept — not by the three display branches of `checkConsent()`.
        // And writing it at display time poisoned the cascade, which reads that field
        // back: see the KDoc on `IosCMPManager.notifyBannerShown`.
        //
        // Recorded from `ConsentView.onAppear`, not here: building a `StateObject` is
        // not showing a banner. See `recordManualPromptIfNeeded()`.

        // Observe state changes. Watchers collect the Kotlin StateFlows on the
        // main dispatcher (see FlowWatcher.kt in iosMain).
        // Kotlin enums are exported as classes: compare with `==` instead of
        // Swift pattern matching.
        // Hop to the main actor explicitly: the closures are invoked from
        // Kotlin, outside Swift concurrency, so @MainActor isolation is not
        // enforced — without this, publishing from a background thread is
        // possible (SwiftUI runtime warning).
        let stateWatcher = ConsentStateWatcher(flow: store.state)
        stateWatcher.watch { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if state == ConsentState.loading {
                    self.uiState.isLoading = true
                } else {
                    self.adoptDecidedWorkflowIfUnset()
                    // Load / language / list changes: rebuild the STRUCTURE
                    // (which also refreshes the toggles).
                    self.rebuildStructure()
                }
            }
        }
        self.stateWatcher = stateWatcher

        // Observe updateCounter — every selection change bumps this counter.
        // COALESCING: handled in FlowWatcher.kt via `drop(1).conflate()` with NO
        // delay — identical to Android's `updateCounter.drop(1).conflate()`. The
        // conflated channel batches a stack tap's ~20× cascade into a SINGLE
        // refresh on the settled value, and — crucially — without the old
        // `delay(16)` that surfaced a tap's result a frame late (the "one action
        // behind" bug, PR #189). The callback is already on the main thread
        // (Dispatchers.Main = main queue on iOS), so no DispatchQueue.main.async
        // hop is needed.
        //
        // Row taps ALSO refresh synchronously (see `applyImmediately`) so the
        // tapped zone updates instantly; this watcher then fires for the same
        // change and recomputes identical state — a cheap, invisible no-op diff
        // (SwiftUI skips the re-render, the memo re-derives the same lists). It
        // is intentionally NOT suppressed: a suppress-next flag could also drop a
        // DIFFERENT change that `conflate()` merged into the same callback,
        // leaving the UI stale. Refreshing unconditionally is always correct.
        let counterWatcher = UpdateCounterWatcher(flow: store.updateCounter)
        counterWatcher.watch { [weak self] _ in
            guard let self else { return }
            // Selection changed (tap cascade or external): TOGGLES ONLY.
            // Structure is tap-immutable by design; rebuildToggles() skips
            // publishing when nothing changed (the usual case right after a
            // tap's synchronous rebuild).
            self.rebuildToggles()
        }
        self.counterWatcher = counterWatcher
    }

    deinit {
        stateWatcher?.close()
        counterWatcher?.close()
    }

    // MARK: - Static Data Build

    /// La clé de portée du PREMIER ÉCRAN, calquée sur le `switch` de `main/Text1.jsx`
    /// (FRONT-1293). Jumelle de `Utils.bannerScopeKey` côté Kotlin.
    ///
    /// Cette famille (`site` / `sites` / `hostnames` / `app`) n'est pas dérivable du nom de
    /// la portée, contrairement à `scope.*` : `LOCAL` et `DOMAIN` partagent `site`. Elle
    /// porte la préposition, parce que `text1` dit « qu'elles soient collectées `<scope/>` ».
    ///
    /// Deux raisons pour un `switch` sur la CHAÎNE plutôt que sur `Scope` :
    /// `Scope.app` n'existe pas encore dans le xcframework committé, donc le nommer ici
    /// casserait tout intégrateur SPM (règle payée sur FRONT-1274) ; et un `switch` Swift
    /// sur une chaîne exige de toute façon un `default`, donc il ne pourrait pas jouer le
    /// rôle de garde. Ce garde-là vit dans le `when` exhaustif du Kotlin : une portée
    /// ajoutée y casse la compilation, ce qui ramène forcément ici.
    /// Miroir Swift de `Settings.effectiveCookieMaxAgeInDays` (FRONT-1292) : plafond 390,
    /// défaut 180 quand la valeur est absente ou négative.
    ///
    /// `<= 0` et non `< 0` comme le web : le champ est `omitempty` côté API, donc l'API
    /// n'émet jamais 0 et le 0 reçu ici signifie « absent » — le cas que le constructeur de
    /// `CmpSettings` traite avec son défaut de 180. Voir la KDoc côté Kotlin pour le détail.
    ///
    /// À basculer sur la propriété Kotlin dès qu'elle sera dans le binaire committé, ce qui
    /// supprimerait ce miroir. En attendant, l'écart de comportement serait invisible : les
    /// deux formules sont identiques, et c'est justement pourquoi le seul garde est de les
    /// écrire côte à côte.
    private static func effectiveMaxAgeDays(_ raw: Int) -> Int {
        let maxDays = 390
        let defaultDays = 180
        if raw > maxDays { return maxDays }
        if raw <= 0 { return defaultDays }
        return raw
    }

    private static func bannerScopeKey(_ scopeName: String) -> String {
        switch scopeName {
        case "group": return "hostnames"
        case "provider": return "sites"
        case "app": return "app"
        default: return "site"
        }
    }

    private func buildStaticData() -> ConsentStaticData {
        let vl = store.vendorList
        let sl = store.sirdataList
        let gp = store.googleProviderList
        let standardPurposes = store.publisherPurposeList.standardPurposes ?? []
        let customPurposes = store.publisherPurposeList.customPurposes ?? []

        let purposeIds = Set((vl.purposesConsent + vl.purposesLI).map { Int($0.id) })
        let sirdataPurposeIds = Set((sl.purposesConsent + sl.purposesLI).map { Int($0.id) })
        let specialFeatureIds = Set(vl.specialFeatures.map { Int($0.id) })
        let hasLI = !vl.purposesLI.isEmpty || !sl.purposesLI.isEmpty
        let hasCustomPurposes = !customPurposes.isEmpty
        let hasUtiq = sirdataPurposeIds.contains(5) && (cmp.config?.cmp.external.utiq?.active ?? false)
        let hasGeolocation = specialFeatureIds.contains(1) || sirdataPurposeIds.contains(6)
        let purposeConsentIds = Set(vl.purposesConsent.map { Int($0.id) })
        let purposeLIIds = Set(vl.purposesLI.map { Int($0.id) })
        let sirdataPurposeConsentIds = Set(sl.purposesConsent.map { Int($0.id) })
        let sirdataPurposeLIIds = Set(sl.purposesLI.map { Int($0.id) })

        // FRONT-1317 — les vendors auxquels l'écran a quelque chose à demander, et eux seuls.
        //
        // Troisième exemplaire de la règle, et c'est assumé : `ConsentSelector` la porte pour
        // Android, `SnapTcfVendor.hasDecidableChannel` pour le rendu iOS, et celui-ci travaille
        // sur les objets Kotlin BRUTS, avant que le snapshot n'existe (`buildSnapshot` a besoin
        // de `data.purposes`, peuplé plus bas). Appeler le Kotlin ici demanderait un symbole
        // absent du binaire committé, donc aucun client SPM ne compilerait — règle FRONT-1274.
        // Les trois copies disent la même chose : les listes FILTRÉES, intersectées avec les
        // listes AFFICHÉES.
        let displayedPurposeIds = Set(vl.purposes.map { Int($0.id) })
        let decidableVendors = vl.vendors.filter { v in
            !Set(v.filteredPurposes.toIntArray()).isDisjoint(with: displayedPurposeIds)
                || !Set(v.filteredLegIntPurposes.toIntArray()).isDisjoint(with: displayedPurposeIds)
                || !Set(v.specialFeatures.toIntArray()).isDisjoint(with: specialFeatureIds)
        }

        // FRONT-1276: a Sirdata vendor linked to BOTH an active TCF vendor and a Google
        // provider also makes the partners screen hide that provider (TCF wins). Three
        // records then render as a single row, so the provider is deducted here too —
        // otherwise the banner announces more partners than the screen ever lists.
        //
        // FRONT-1317 — `decidableVendors` et non `vl.vendors` : un porteur que l'écran n'affiche
        // pas ne masque plus le provider de son jumeau Sirdata, qui redevient une ligne.
        let countedHiddenProviderIds: Set<Int> = Set(sl.vendors.compactMap { sv -> Int? in
            guard sv.googleProviderId != nil, sv.tcfVendorId != nil else { return nil }
            let googleId = Int(truncating: sv.googleProviderId!)
            let tcfId = Int(truncating: sv.tcfVendorId!)
            guard decidableVendors.contains(where: { Int($0.id) == tcfId && $0.deletedDate == nil }),
                  gp.providers.contains(where: { Int($0.id) == googleId })
            else { return nil }
            return googleId
        })

        var partnerCount = decidableVendors.count + (gp.providers.count - countedHiddenProviderIds.count) + sl.vendors.count
            - sl.vendors.filter { sv in
                let hasTcfMatch: Bool = sv.tcfVendorId != nil && decidableVendors.contains { Int($0.id) == Int(truncating: sv.tcfVendorId!) && $0.deletedDate == nil }
                let hasGoogleMatch: Bool = sv.googleProviderId != nil && gp.providers.contains { Int($0.id) == Int(truncating: sv.googleProviderId!) }
                return hasTcfMatch || hasGoogleMatch
            }.count
            + customPurposes.filter { !($0.vendor?.name.isEmpty ?? true) }.count

        // FRONT-1286 — clé dérivée du nom de la portée, comme `Utils.buildText` côté Kotlin.
        //
        // À noter : le ticket donnait ce site-ci pour « déjà évolutif », en s'appuyant sur
        // `Utils.kt:309`. C'est vrai d'Android, qui passe par le pipeline partagé — mais
        // iOS en a son propre portage Swift (`CmpHelpers.swift`), qui reçoit `scopeKey` en
        // paramètre. La chaîne de `if` vivait donc ici, et une portée non énumérée tombait
        // sur « ce site ». C'est l'illustration exacte de la règle du CLAUDE.md : une vue
        // dupliquée est l'endroit où un correctif de parité meurt.
        //
        // `name` vient de `KotlinEnum` et EST déjà exporté par le binaire committé
        // (`@property (readonly) NSString *name`) : cette dérivation compile donc sans
        // attendre une régénération, contrairement à un `Scope.app` qui nommerait un
        // symbole neuf et casserait tout intégrateur SPM.
        let scopeName = cmp.config?.cmp.scope.name.lowercased() ?? "local"
        let scopeTextKey = "scope." + scopeName

        // FRONT-1293 — le `<scope/>` du BANDEAU lit une autre famille de clés que celui de
        // l'écran finalités, et le mobile ne lisait que la seconde. Voir la KDoc de
        // `Utils.resolveScopeTag` côté Kotlin : les clés du premier écran portent la
        // préposition (`text1` dit « collectées <scope/> »), celles de `scope.*` non
        // (`purposes.text2` dit déjà « valable sur <scope/> »).
        let bannerScopeTextKey = Self.bannerScopeKey(scopeName)

        // La mention de stockage n'est PAS dérivable de la même façon, et c'est la seule
        // asymétrie de ce ticket : l'API sert une clé de base plus une variante app, pas
        // une clé par portée. Dériver `consentStorage.<portée>` chercherait
        // `consentStorage.local`, qui n'existe pas — donc un texte vide.
        //
        // La comparaison porte sur le NOM et non sur `Scope.app` : ce symbole est ajouté
        // par cette PR et n'existe pas encore dans le xcframework committé, donc le nommer
        // ici empêcherait tout intégrateur SPM de compiler (règle payée sur FRONT-1274).
        // `name` vient de `KotlinEnum` et est déjà exporté.
        let consentStorageKey =
            scopeName == "app" ? "consentStorage.app" : LocaleKey.consentStorage.key

        // FRONT-1292 — plafond 390, défaut 180, comme `settings.js` l. 8 et 43-46. Le champ
        // brut vaut 0 quand la config ne le déclare pas (il est `omitempty` côté API), et le
        // bandeau annonçait alors « 0 jour » là où le web annonce 180.
        //
        // La règle est reportée en Swift plutôt que lue sur le modèle Kotlin :
        // `Settings.effectiveCookieMaxAgeInDays` est ajouté par cette PR et n'est donc PAS
        // dans le xcframework committé — le nommer ici empêcherait tout intégrateur SPM de
        // compiler (règle payée sur FRONT-1274). Même situation que `CmpLiteHtml` ou
        // `ConsentSnapshot`, qui portent déjà un miroir Swift d'une règle Kotlin ; et il n'y a
        // qu'UN site de lecture côté iOS, donc un seul miroir, pas une règle éparpillée.
        let maxAgeDays = Self.effectiveMaxAgeDays(Int(cmp.config?.cmp.cookieMaxAgeInDays ?? 0))
        let noConsentButtonStr: String = {
            let btn = theme?.noConsentButton
            if btn == ThemeNoConsentButton.reject { return "REJECT" }
            if btn == ThemeNoConsentButton.continue_ { return "CONTINUE" }
            return ""
        }()
        let closeButton = theme?.closeButton ?? false
        let customPurposeNames: [String] = customPurposes.map { $0.name }

        var tcfPurposeNameMap: [Int: String] = [:]
        for p in (vl.purposesConsent + vl.purposesLI) {
            tcfPurposeNameMap[Int(p.id)] = p.name
        }
        var sirdataPurposeNameMap: [Int: String] = [:]
        for p in (sl.purposesConsent + sl.purposesLI) {
            sirdataPurposeNameMap[Int(p.id)] = p.name
        }
        var tcfDataCategoryNameMap: [Int: String] = [:]
        var tcfDataCategoryDescriptionMap: [Int: String] = [:]
        for dc in vl.dataCategories {
            tcfDataCategoryNameMap[Int(dc.id)] = dc.name
            tcfDataCategoryDescriptionMap[Int(dc.id)] = dc.description_
        }

        let choicesStyle = theme?.setChoicesStyle ?? .button
        let toolbarStyleIsIcon = theme?.toolbar.active == true && theme?.toolbar.style == ThemeToolbarStyle.icon

        func processText(_ key: LocaleKey) -> String {
            let raw = localize.getText(key: key.key)
            return raw
                .processConditionalTags(
                    purposeIds: purposeIds,
                    sirdataPurposeIds: sirdataPurposeIds,
                    specialFeatureIds: specialFeatureIds,
                    hasLegitimateInterest: hasLI,
                    hasCustomPurposes: hasCustomPurposes,
                    hasUtiq: hasUtiq
                )
                .buildText(
                    localize: localize,
                    partnerCount: partnerCount,
                    // FRONT-1293 : le bandeau (`text1`) lit la famille qui porte la
                    // préposition, tout le reste lit `scope.*`. Cf. `Self.bannerScopeKey`.
                    scopeKey: key == .text1 ? bannerScopeTextKey : scopeTextKey,
                    maxAgeDays: maxAgeDays,
                    isApplyWorkflow: uiState.workflow == .applyChoices,
                    noConsentButton: noConsentButtonStr,
                    closeButton: closeButton,
                    hasCustomPurposes: hasCustomPurposes,
                    customPurposeNames: customPurposeNames,
                    hasGeolocation: hasGeolocation,
                    toolbarStyleIsIcon: toolbarStyleIsIcon,
                    isManualDisplay: uiState.workflow == .manualDisplay,
                    // FRONT-1283 : TEXT4 résout `<actors/>` depuis `text4.partner*`,
                    // les autres textes depuis `mode.*.partner*`.
                    isText4Mode: key == .text4
                )
                .processConditionalTags(
                    purposeIds: purposeIds,
                    sirdataPurposeIds: sirdataPurposeIds,
                    specialFeatureIds: specialFeatureIds,
                    hasLegitimateInterest: hasLI,
                    hasCustomPurposes: hasCustomPurposes,
                    hasUtiq: hasUtiq
                )
                .processClassnameTags(setChoicesStyle: choicesStyle)
        }

        // `key` only steers the two banner-specific branches below (`text1`, `text4`):
        // any other text — e.g. the partners screen scope reminder (FRONT-1409) — goes
        // through the banner pipeline unchanged.
        func processRawTextSegments(_ raw: String, key: LocaleKey?) -> [(text: String, linkType: String?)] {
            let isText1 = key.map { $0 == LocaleKey.text1 } ?? false
            let isText4 = key.map { $0 == LocaleKey.text4 } ?? false
            return raw
                .processConditionalTags(
                    purposeIds: purposeIds,
                    sirdataPurposeIds: sirdataPurposeIds,
                    specialFeatureIds: specialFeatureIds,
                    hasLegitimateInterest: hasLI,
                    hasCustomPurposes: hasCustomPurposes,
                    hasUtiq: hasUtiq
                )
                .buildText(
                    localize: localize,
                    partnerCount: partnerCount,
                    // FRONT-1293 — même arbitrage que dans `processText` juste au-dessus, et
                    // il faut les DEUX : `text1` traverse les deux pipelines (`data.text1` et
                    // `data.text1Segments`), donc n'en corriger qu'un laisserait le bandeau
                    // faux dans la moitié des rendus, selon qu'il porte un lien ou non.
                    scopeKey: isText1 ? bannerScopeTextKey : scopeTextKey,
                    maxAgeDays: maxAgeDays,
                    isApplyWorkflow: uiState.workflow == .applyChoices,
                    noConsentButton: noConsentButtonStr,
                    closeButton: closeButton,
                    hasCustomPurposes: hasCustomPurposes,
                    customPurposeNames: customPurposeNames,
                    hasGeolocation: hasGeolocation,
                    toolbarStyleIsIcon: toolbarStyleIsIcon,
                    isManualDisplay: uiState.workflow == .manualDisplay,
                    // FRONT-1283 : TEXT4 résout `<actors/>` depuis `text4.partner*`,
                    // les autres textes depuis `mode.*.partner*`.
                    isText4Mode: isText4
                )
                .processConditionalTags(
                    purposeIds: purposeIds,
                    sirdataPurposeIds: sirdataPurposeIds,
                    specialFeatureIds: specialFeatureIds,
                    hasLegitimateInterest: hasLI,
                    hasCustomPurposes: hasCustomPurposes,
                    hasUtiq: hasUtiq
                )
                .processClassnameTagsStructured(setChoicesStyle: choicesStyle)
        }

        func processTextSegments(_ key: LocaleKey) -> [(text: String, linkType: String?)] {
            processRawTextSegments(localize.getText(key: key.key), key: key)
        }

        let isApplyWorkflow = uiState.workflow == .applyChoices
        let text3Key: LocaleKey = isApplyWorkflow ? .text4 : .text3

        // FRONT-1286 — même dérivation que pour le `<scope/>` du bandeau plus haut, et le
        // même `scopeName` : les deux clés décrivent la même portée, les faire diverger
        // serait un bug silencieux.
        let scopeKey = "vendors.scope." + scopeName

        var data = ConsentStaticData()
        data.purposes = vl.purposes
        data.specialFeatures = vl.specialFeatures
        data.vendors = vl.vendors
        data.stacks = vl.stacks
        data.sirdataPurposes = sl.purposes
        data.sirdataVendors = sl.vendors
        data.sirdataStacks = sl.stacks
        data.googleProviders = gp.providers
        data.googlePurposes = gp.purposes.map { $0.intValue }
        data.specialPurposes = vl.specialPurposes
        data.features = vl.features
        data.standardPurposes = standardPurposes
        data.customPurposes = customPurposes
        data.title = localize.getText(key: LocaleKey.mainTitle.key)
        data.description = localize.getText(key: LocaleKey.purposesText1.key)
        data.customDescription = processText(.mainCustomDescription)
        data.tcfPurposeNameMap = tcfPurposeNameMap
        data.sirdataPurposeNameMap = sirdataPurposeNameMap
        data.tcfDataCategoryNameMap = tcfDataCategoryNameMap
        data.tcfDataCategoryDescriptionMap = tcfDataCategoryDescriptionMap
        data.scopeTextKey = scopeTextKey
        data.consentStorageKey = consentStorageKey
        data.maxAgeDays = maxAgeDays
        data.hasLegitimateInterest = hasLI
        data.hasCustomPurposes = hasCustomPurposes
        data.hasUtiq = hasUtiq
        data.hasGeolocation = hasGeolocation
        data.dataController = cmp.config?.cmp.external.utiq?.controller ?? ""
        data.cookieDurationSeconds = 0
        data.sirdataStackIds = Set(cmp.config?.cmp.vendorList.sirdataStacks.compactMap { $0.intValue } ?? [])
        data.availablePurposeIds = purposeIds
        data.availableSirdataPurposeIds = sirdataPurposeIds
        data.availableSpecialFeatureIds = specialFeatureIds
        data.choicesStyle = choicesStyle
        data.noConsentButton = noConsentButtonStr
        data.closeButton = closeButton
        data.customPurposeNames = customPurposeNames
        data.whiteLabel = theme?.whiteLabel ?? false
        data.disableTcf = cmp.config?.cmp.disableTcf ?? false
        data.privacyPolicyUrl = cmp.config?.cmp.privacyPolicy ?? ""
        data.scopeReminderKey = scopeKey
        data.hostnames = cmp.config?.context.hostnames ?? []
        data.utiqActive = cmp.config?.cmp.external.utiq?.active ?? false
        data.utiqNoticeUrl = cmp.config?.cmp.external.utiq?.noticeUrl ?? ""
        data.isCnilVariant = cmp.config?.context.isVariantApplies(
            variants: KotlinArray<NSString>(size: 1) { _ in CmpConstants.shared.VARIANT_CNIL as NSString }
        ) ?? false
        data.expandedDisplayMode = cmp.config?.cmp.vendorList.displayMode == VendorListDisplayMode.expanded
        data.stackSirdataPurposeIds = Set(sl.stackSirdataPurposes.map { $0.intValue })
        data.purposeConsentIds = purposeConsentIds
        data.purposeLIIds = purposeLIIds
        data.sirdataPurposeConsentIds = sirdataPurposeConsentIds
        data.sirdataPurposeLIIds = sirdataPurposeLIIds
        data.workflow = uiState.workflow
        // Snapshot every Kotlin object the derivation reads into pure Swift
        // (one interop pass, at load) — see ConsentSnapshot.swift.
        data.snap = buildSnapshot(data: data,
                                  standardPurposes: standardPurposes,
                                  customPurposes: customPurposes)
        // FRONT-1280 — in "apply choices" mode the web announces the number of
        // partners LEFT to decide, not the total: `Text1.jsx` passes
        // `missingOnly: isApplyWorkflow` to the same row builder the partners screen
        // uses, precisely so the count and the list cannot drift apart. Here that
        // builder is `computeApplyRowPlan`, which needs the snapshot — hence the
        // override after it rather than beside the total above. Custom publisher
        // vendors are never filtered out, on either side, so they count in both modes.
        //
        // FRONT-1285 — cette décision ajuste le compte LOCAL, et les textes du bandeau sont
        // bâtis juste après. Elle écrasait auparavant `data.partnerCount` seul, alors que les
        // textes avaient déjà été construits une centaine de lignes plus haut avec le TOTAL :
        // le bandeau annonçait donc tous les partenaires de la configuration. Le défaut
        // était invisible jusqu'à FRONT-1283, qui a rendu ce compte visible dans le
        // troisième paragraphe. Android ne l'a jamais eu, sa valeur étant décidée avant les
        // textes (`ConsentViewModel.kt:303`).
        //
        // L'ordre est contraint : `computeApplyRowPlan` a besoin de `data.snap`, que
        // `buildSnapshot` ne peut produire qu'une fois `data.purposes`, `data.stacks` et
        // leurs voisins peuplés. Ce sont donc les textes qui descendent, pas le snapshot qui
        // remonte — ils sont les seuls consommateurs du compte.
        if uiState.workflow == .applyChoices {
            partnerCount = computeApplyRowPlan(snap: data.snap).visibleKeys.count
                + customPurposes.filter { !($0.vendor?.name.isEmpty ?? true) }.count
        }
        data.partnerCount = partnerCount

        // Bâtis en DERNIER : `processText` capture `partnerCount`, qui vient d'être arrêté.
        data.text1 = processText(.text1)
        data.text2 = processText(.text2)
        data.text3 = processText(text3Key)
        data.text1Segments = processTextSegments(.text1)
        data.text2Segments = processTextSegments(.text2)
        data.text3Segments = processTextSegments(text3Key)
        // FRONT-1409 — the partners screen scope reminder with its links, so each one
        // opens its own target (web parity: `VendorScope.jsx` renders it through `buildText`).
        data.scopeReminderSegments = processRawTextSegments(localize.getText(key: scopeKey), key: nil)
        return data
    }

    // MARK: - Load-Time Swift Snapshot

    private func buildSnapshot(data: ConsentStaticData,
                               standardPurposes: [PublisherStandardPurpose],
                               customPurposes: [PublisherCustomPurpose]) -> ConsentSnapshot {
        let vl = store.vendorList
        let sl = store.sirdataList
        let gp = store.googleProviderList
        var snap = ConsentSnapshot()

        snap.tcfListPurposeIds = Set(vl.purposes.map { Int($0.id) })
        snap.tcfListSpecialFeatureIds = Set(vl.specialFeatures.map { Int($0.id) })
        snap.sirdataListPurposeIds = Set(sl.purposes.map { Int($0.id) })

        // Iterate through NSDictionary WITHOUT the typed bridge: the Kotlin
        // Map<Int, Int> is declared [KotlinInt: KotlinInt] in the ObjC export
        // but holds plain NSNumber instances at runtime — a typed Swift
        // iteration force-bridges each element and dies in
        // swift_dynamicCastFailure (SIGABRT seen in the CI crash reports).
        // NSNumber is the common superclass of both worlds.
        func intMap(_ map: [KotlinInt: KotlinInt]) -> [Int: Int] {
            var out: [Int: Int] = [:]
            (map as NSDictionary).forEach { key, value in
                if let k = key as? NSNumber, let v = value as? NSNumber {
                    out[k.intValue] = v.intValue
                }
            }
            return out
        }

        // Sirdata vendors first (TCF/Google snapshots reference them as links).
        snap.sirdataVendors = sl.vendors.map { v in
            let purposes = v.purposes.toIntArray()
            let extraPurposes = v.extraPurposes.toIntArray()
            let legIntPurposes = v.legIntPurposes.toIntArray()
            let legIntExtraPurposes = v.legIntExtraPurposes.toIntArray()
            let purposeSet = Set(purposes)
            let extraSet = Set(extraPurposes)
            let liSet = Set(legIntPurposes)
            let liExtraSet = Set(legIntExtraPurposes)
            let tcfVendorId = v.tcfVendorId.map { Int(truncating: $0) }
            let googleProviderId = v.googleProviderId.map { Int(truncating: $0) }
            // Resolved once, not once per flag: this scan is the only Kotlin read
            // in the loop, and it used to run just for a "does it exist" answer.
            let linkedTcf = tcfVendorId.flatMap { tid in vl.vendors.first { Int($0.id) == tid } }
            return SnapSirdataVendor(
                id: Int(v.id),
                name: v.name,
                nameLower: v.name.lowercased(),
                policyUrl: v.policyUrl.isEmpty ? nil : v.policyUrl,
                purposesList: purposes, purposes: purposeSet,
                extraPurposesList: extraPurposes, extraPurposes: extraSet,
                legIntPurposesList: legIntPurposes, legIntPurposes: liSet,
                legIntExtraPurposesList: legIntExtraPurposes, legIntExtraPurposes: liExtraSet,
                tcfVendorId: tcfVendorId,
                googleProviderId: googleProviderId,
                // ConsentSelector.kt:722-728 eligibility
                combinedConsentEligible: !purposeSet.isDisjoint(with: snap.tcfListPurposeIds)
                    || !extraSet.isDisjoint(with: snap.sirdataListPurposeIds),
                combinedLIEligible: !liSet.isDisjoint(with: snap.tcfListPurposeIds)
                    || !liExtraSet.isDisjoint(with: snap.sirdataListPurposeIds),
                // Per-basis eligibility, not mere existence: a linked TCF vendor
                // contributes a channel only where it actually has one (web parity,
                // Selector.ts getSirdataVendorState). See ConsentSelector.kt.
                // Filtered, not raw: publisher restrictions decide what is actually
                // exposed, and the rest of this snapshot already reads the filtered
                // lists (see hasConsentChannel for TCF vendors below). Both default
                // to the raw list when no restriction applies. specialFeatures stays
                // raw — no restriction filters it. See ConsentSelector.kt.
                linkedTcfConsentEligible: linkedTcf.map {
                    !$0.filteredPurposes.isEmpty || !$0.specialFeatures.isEmpty
                } ?? false,
                linkedTcfLIEligible: linkedTcf.map { !$0.filteredLegIntPurposes.isEmpty } ?? false,
                // Existence, distinct from the two eligibility flags above and NOT
                // derivable from them: hiding a linked Google provider (T-V09) asks
                // whether a TCF parent is present in the list at all, which stays
                // true even when publisher restrictions leave it no exposed basis.
                // Deriving it from the eligibility flags would un-hide the provider
                // in exactly that case.
                linkedTcfExists: linkedTcf != nil,
                linkedGoogleExists: googleProviderId.map { gid in gp.providers.contains { Int($0.id) == gid } } ?? false,
                // refreshUiState per-channel presence parity
                hasConsentChannel: !purposes.isEmpty || !extraPurposes.isEmpty,
                hasLIChannel: !legIntPurposes.isEmpty || !legIntExtraPurposes.isEmpty
            )
        }

        func linkedSirdata(where predicate: (SnapSirdataVendor) -> Bool) -> SnapLinkedSirdata? {
            snap.sirdataVendors.first(where: predicate).map {
                SnapLinkedSirdata(id: $0.id,
                                  hasExtraPurposes: !$0.extraPurposes.isEmpty,
                                  hasLegIntExtraPurposes: !$0.legIntExtraPurposes.isEmpty,
                                  hasPurposes: !$0.purposes.isEmpty,
                                  hasLegIntPurposes: !$0.legIntPurposes.isEmpty)
            }
        }

        snap.vendors = vl.vendors.map { v in
            let vid = Int(v.id)
            let filteredPurposes = v.filteredPurposes.toIntArray()
            let filteredLegInt = v.filteredLegIntPurposes.toIntArray()
            let filteredPurposeSet = Set(filteredPurposes)
            let filteredLegIntSet = Set(filteredLegInt)
            let specialFeatures = Set(v.specialFeatures.toIntArray())
            return SnapTcfVendor(
                id: vid,
                name: v.name,
                nameLower: v.name.lowercased(),
                policyUrl: v.policyUrl.isEmpty ? nil : v.policyUrl,
                filteredPurposesList: filteredPurposes,
                filteredPurposes: filteredPurposeSet,
                filteredLegIntPurposesList: filteredLegInt,
                filteredLegIntPurposes: filteredLegIntSet,
                specialFeatures: specialFeatures,
                specialPurposes: v.specialPurposes.toIntArray(),
                features: v.features.toIntArray(),
                dataDeclaration: v.dataDeclaration.toIntArray(),
                // ConsentSelector.getVendorState eligibility: FILTERED sets ∩ display
                // lists. Publisher restrictions decide whether a basis is exposed at
                // all, so the raw declaration would credit a consent channel the row
                // does not display. Both sets equal the raw ones absent restrictions.
                combinedConsentEligible: !filteredPurposeSet.isDisjoint(with: snap.tcfListPurposeIds)
                    || !specialFeatures.isDisjoint(with: snap.tcfListSpecialFeatureIds),
                combinedLIEligible: !filteredLegIntSet.isDisjoint(with: snap.tcfListPurposeIds),
                linkedSirdata: linkedSirdata { $0.tcfVendorId == vid },
                hasConsentChannel: !filteredPurposes.isEmpty || !specialFeatures.isEmpty,
                hasLIChannel: !filteredLegInt.isEmpty,
                spOnly: v.spOnly,
                legIntClaim: v.legIntClaim,
                retentionPurposes: intMap(v.dataRetention.purposes),
                retentionSpecialPurposes: intMap(v.dataRetention.specialPurposes),
                usesCookies: v.usesCookies,
                cookieMaxAgeSeconds: Int(v.cookieMaxAgeSeconds),
                cookieRefresh: v.cookieRefresh,
                usesNonCookieAccess: v.usesNonCookieAccess,
                deviceStorageDisclosureUrl: v.deviceStorageDisclosureUrl
            )
        }

        snap.googleProviders = gp.providers.map { p in
            let pid = Int(p.id)
            return SnapGoogleProvider(
                id: pid,
                name: p.name,
                nameLower: p.name.lowercased(),
                policyUrl: p.policyUrl.isEmpty ? nil : p.policyUrl,
                linkedSirdata: linkedSirdata { $0.googleProviderId == pid }
            )
        }
        snap.googleProvidersSortedByName = snap.googleProviders.sorted { $0.nameLower < $1.nameLower }

        func snapPurposes(_ list: [TcfPurpose]) -> [SnapPurpose] {
            list.map {
                SnapPurpose(id: Int($0.id), name: $0.name,
                            descriptionRaw: $0.description_,
                            descriptionProcessed: processDescriptionStatic(data: data, text: $0.description_))
            }
        }
        snap.purposes = snapPurposes(data.purposes)
        snap.specialFeatures = snapPurposes(data.specialFeatures)
        snap.specialPurposes = snapPurposes(data.specialPurposes)
        snap.features = snapPurposes(data.features)
        snap.sirdataPurposes = data.sirdataPurposes.map {
            SnapPurpose(id: Int($0.id), name: $0.name,
                        descriptionRaw: $0.description_,
                        descriptionProcessed: processDescriptionStatic(data: data, text: $0.description_))
        }
        snap.purposeById = Dictionary(uniqueKeysWithValues: snap.purposes.map { ($0.id, $0) })
        snap.sirdataPurposeById = Dictionary(uniqueKeysWithValues: snap.sirdataPurposes.map { ($0.id, $0) })
        snap.specialFeatureById = Dictionary(uniqueKeysWithValues: snap.specialFeatures.map { ($0.id, $0) })

        snap.stacks = data.stacks.map {
            SnapStack(id: $0.id, name: $0.name,
                      descriptionProcessed: processDescriptionStatic(data: data, text: $0.description_),
                      purposes: $0.purposes.toIntArray(),
                      specialFeatures: $0.specialFeatures.toIntArray(),
                      extraPurposes: [])
        }
        snap.sirdataStacks = data.sirdataStacks.map {
            SnapStack(id: $0.id, name: $0.name,
                      descriptionProcessed: processDescriptionStatic(data: data, text: $0.description_),
                      purposes: $0.purposes.toIntArray(),
                      specialFeatures: $0.specialFeatures.toIntArray(),
                      extraPurposes: $0.extraPurposes.toIntArray())
        }
        snap.standardPurposes = standardPurposes.map {
            SnapStandardPurpose(id: $0.id, isLI: $0.legalBasis == .legitimateInterest)
        }
        snap.customPurposes = customPurposes.map {
            SnapCustomPurpose(id: $0.id, name: $0.name,
                              descriptionRaw: $0.description_,
                              descriptionProcessed: processDescriptionStatic(data: data, text: $0.description_),
                              isLI: $0.legalBasis == .legitimateInterest,
                              vendorName: $0.vendor?.name,
                              vendorPolicyUrl: ($0.vendor?.policyUrl).flatMap { $0.isEmpty ? nil : $0 })
        }
        return snap
    }

    // MARK: - Description / Legal-Basis Helpers

    /// Processes description text using static data params (mirrors PurposesView.processDescription).
    private func processDescriptionStatic(data: ConsentStaticData, text: String) -> String {
        text.processDescriptionPipeline(
            localize: localize,
            partnerCount: data.partnerCount,
            scopeKey: data.scopeTextKey,
            maxAgeDays: data.maxAgeDays,
            isApplyWorkflow: data.workflow == .applyChoices,
            noConsentButton: data.noConsentButton,
            closeButton: data.closeButton,
            hasCustomPurposes: data.hasCustomPurposes,
            customPurposeNames: data.customPurposeNames,
            hasGeolocation: data.hasGeolocation,
            dataController: data.dataController,
            cookieDurationSeconds: data.cookieDurationSeconds,
            purposeIds: data.availablePurposeIds,
            sirdataPurposeIds: data.availableSirdataPurposeIds,
            specialFeatureIds: data.availableSpecialFeatureIds,
            hasLegitimateInterest: data.hasLegitimateInterest,
            hasCustomPurposesFlag: data.hasCustomPurposes,
            hasUtiq: data.hasUtiq,
            sirdataStackIds: data.sirdataStackIds,
            setChoicesStyle: data.choicesStyle
        )
    }

    private func tcfLegalBasisLabelStatic(data: ConsentStaticData, id: Int) -> String {
        if data.purposeConsentIds.contains(id) { return localize.getText(key: LocaleKey.vendorsConsent.key) }
        if data.purposeLIIds.contains(id) { return localize.getText(key: LocaleKey.vendorsLi.key) }
        return ""
    }

    private func sirdataLegalBasisLabelStatic(data: ConsentStaticData, id: Int) -> String {
        if data.sirdataPurposeConsentIds.contains(id) { return localize.getText(key: LocaleKey.vendorsConsent.key) }
        if data.sirdataPurposeLIIds.contains(id) { return localize.getText(key: LocaleKey.vendorsLi.key) }
        return ""
    }

    // MARK: - Purposes Screen STRUCTURE (built on entry, tap-immutable)

    /// Localized labels reused across all vendor-summary builders.
    private struct StatusLabels {
        let consent: String
        let li: String
        let accepted: String
        let notAccepted: String
        let notRejected: String
        let rejected: String
    }

    private func makeStatusLabels() -> StatusLabels {
        StatusLabels(
            consent: localize.getText(key: LocaleKey.vendorsConsent.key),
            li: localize.getText(key: LocaleKey.vendorsLi.key),
            accepted: localize.getText(key: LocaleKey.accepted.key),
            notAccepted: localize.getText(key: LocaleKey.notAccepted.key),
            notRejected: localize.getText(key: LocaleKey.notRejected.key),
            rejected: localize.getText(key: LocaleKey.rejected.key)
        )
    }

    /// Consent + LI partner lists for a free TCF purpose — STRUCTURE only
    /// (name, badge, policy link, acceptance state-KEY; never a state value).
    /// Web parity: Purposes.jsx:211-212 (TCF + Google + Sirdata merged,
    /// name-deduped, sorted).
    private func tcfPurposeVendorData(snap: ConsentSnapshot, sd: ConsentStaticData, labels: StatusLabels, pid: Int) -> (consent: [VendorSummary], li: [VendorSummary]) {
        var consentOut: [VendorSummary] = []
        for v in snap.vendors where v.filteredPurposes.contains(pid) {
            consentOut.append(VendorSummary(
                name: v.name, iabBadge: "IAB TCF", status: labels.consent,
                policyUrl: v.policyUrl,
                stateKey: ToggleKey.owned(ToggleKey.tcfVendor(v.id), ToggleKey.tcfPurposeStatus(pid))
            ))
        }
        // Google providers (consent only — web parity: Purposes.jsx:211)
        if sd.googlePurposes.contains(pid) {
            for gp in snap.googleProviders where !consentOut.contains(where: { $0.name == gp.name }) {
                consentOut.append(VendorSummary(
                    name: gp.name, iabBadge: nil, status: labels.consent,
                    policyUrl: gp.policyUrl,
                    stateKey: ToggleKey.owned(ToggleKey.googleProvider(gp.id), ToggleKey.tcfPurposeStatus(pid))
                ))
            }
        }
        // Sirdata consent vendors — web parity: Purposes.jsx:212
        // `purposes` = the Sirdata vendor's TCF purposes. NOT `extraPurposes`,
        // which holds SIRDATA purpose ids: matching those against a TCF purpose
        // id compares two unrelated id spaces.
        for v in snap.sirdataVendors where v.purposes.contains(pid) && !consentOut.contains(where: { $0.name == v.name }) {
            consentOut.append(VendorSummary(
                name: v.name, iabBadge: nil, status: labels.consent,
                policyUrl: v.policyUrl,
                stateKey: ToggleKey.owned(ToggleKey.sirdataVendor(v.id), ToggleKey.tcfPurposeStatus(pid))
            ))
        }
        consentOut.sort { $0.name.lowercased() < $1.name.lowercased() }

        var liOut: [VendorSummary] = []
        for v in snap.vendors where v.filteredLegIntPurposes.contains(pid) {
            liOut.append(VendorSummary(
                name: v.name, iabBadge: "IAB TCF", status: labels.li,
                policyUrl: v.policyUrl,
                stateKey: ToggleKey.owned(ToggleKey.tcfVendorLI(v.id), ToggleKey.tcfPurposeStatusLI(pid))
            ))
        }
        // Same rule on the LI channel: TCF purpose id → `legIntPurposes`
        // (web parity: Purposes.jsx vendorsLI).
        for v in snap.sirdataVendors where v.legIntPurposes.contains(pid) && !liOut.contains(where: { $0.name == v.name }) {
            liOut.append(VendorSummary(
                name: v.name, iabBadge: nil, status: labels.li,
                policyUrl: v.policyUrl,
                stateKey: ToggleKey.owned(ToggleKey.sirdataVendorLI(v.id), ToggleKey.tcfPurposeStatusLI(pid))
            ))
        }
        liOut.sort { $0.name.lowercased() < $1.name.lowercased() }
        return (consentOut, liOut)
    }

    /// Consent + LI partner lists for a free Sirdata purpose.
    ///
    /// A SIRDATA purpose id matches ONLY the Sirdata channels (`extraPurposes` /
    /// `legIntExtraPurposes`) — web parity: Purposes.jsx passes
    /// `sirdataVendors.filter(({extraPurposes}) => extraPurposes.indexOf(id) > -1)`
    /// to SirdataPurpose. Also testing `purposes` (TCF ids) pulled in unrelated
    /// partners whose TCF purpose happened to share the number.
    private func sirdataPurposeVendorData(snap: ConsentSnapshot, labels: StatusLabels, pid: Int) -> (consent: [VendorSummary], li: [VendorSummary]) {
        let consent = snap.sirdataVendors
            .filter { $0.extraPurposes.contains(pid) }
            .sorted { $0.nameLower < $1.nameLower }
            .map { v in
                VendorSummary(name: v.name, iabBadge: nil, status: labels.consent,
                              policyUrl: v.policyUrl,
                              stateKey: ToggleKey.owned(ToggleKey.sirdataVendor(v.id),
                                                        ToggleKey.sirdataPurposeStatus(pid)))
            }
        let li = snap.sirdataVendors
            .filter { $0.legIntExtraPurposes.contains(pid) }
            .sorted { $0.nameLower < $1.nameLower }
            .map { v in
                VendorSummary(name: v.name, iabBadge: nil, status: labels.li,
                              policyUrl: v.policyUrl,
                              stateKey: ToggleKey.owned(ToggleKey.sirdataVendorLI(v.id),
                                                        ToggleKey.sirdataPurposeStatusLI(pid)))
            }
        return (consent, li)
    }

    /// TCF vendors filtered by a read-only id set (special features, special purposes,
    /// features).
    ///
    /// FRONT-1276 — `purposeStatusKey` is the id-set's own acceptance key, combined with each
    /// partner's bit. Pass nil where the web shows NO status: a special purpose and a feature
    /// have no consent channel to report, and their web partner lists are rendered without
    /// `withState` (SpecialPurpose.jsx, Feature.jsx). Reporting the partner's consent bit
    /// there answered a question nobody asked, and answered it wrong.
    private func tcfVendorSummaries(snap: ConsentSnapshot, labels: StatusLabels,
                                    purposeStatusKey: String? = nil,
                                    matching: (SnapTcfVendor) -> Bool) -> [VendorSummary] {
        snap.vendors
            .filter(matching)
            .sorted { $0.nameLower < $1.nameLower }
            .map { v in
                VendorSummary(name: v.name, iabBadge: "IAB TCF",
                              status: purposeStatusKey == nil ? nil : labels.consent,
                              policyUrl: v.policyUrl,
                              stateKey: purposeStatusKey.map { ToggleKey.owned(ToggleKey.tcfVendor(v.id), $0) })
            }
    }

    /// Nested rows of an expanded TCF stack.
    private func tcfStackNestedRows(snap: ConsentSnapshot, sd: ConsentStaticData, labels: StatusLabels, stack: SnapStack, stackRowId: String) -> [PurposeRowModel] {
        var items: [PurposeRowModel] = []
        for pid in stack.purposes where pid != 1 {
            guard sd.availablePurposeIds.contains(pid), let name = sd.tcfPurposeNameMap[pid] else { continue }
            items.append(stackTcfPurposeRow(snap: snap, sd: sd, labels: labels, pid: pid, name: name, rowId: "\(stackRowId)_p_\(pid)"))
        }
        items.append(contentsOf: stackSpecialFeatureRows(snap: snap, labels: labels, specialFeatures: stack.specialFeatures, stackRowId: stackRowId))
        return items
    }

    /// Nested rows of an expanded Sirdata stack: TCF purposes, then Sirdata
    /// extra purposes, then special features (mirrors the previous builder).
    private func sirdataStackNestedRows(snap: ConsentSnapshot, sd: ConsentStaticData, labels: StatusLabels, stack: SnapStack, stackRowId: String) -> [PurposeRowModel] {
        var items: [PurposeRowModel] = []
        for pid in stack.purposes where pid != 1 {
            guard sd.availablePurposeIds.contains(pid), let name = sd.tcfPurposeNameMap[pid] else { continue }
            items.append(stackTcfPurposeRow(snap: snap, sd: sd, labels: labels, pid: pid, name: name, rowId: "\(stackRowId)_p_\(pid)"))
        }
        for pid in stack.extraPurposes {
            guard sd.availableSirdataPurposeIds.contains(pid), let name = sd.sirdataPurposeNameMap[pid] else { continue }
            let consentVendors = snap.sirdataVendors.filter { $0.extraPurposes.contains(pid) }
            let liVendors = snap.sirdataVendors.filter { $0.legIntExtraPurposes.contains(pid) }
            var summaries: [VendorSummary] = []
            for v in consentVendors {
                summaries.append(VendorSummary(name: v.name, iabBadge: nil, status: labels.consent,
                                               policyUrl: v.policyUrl,
                                               stateKey: ToggleKey.owned(ToggleKey.sirdataVendor(v.id),
                                                                         ToggleKey.sirdataPurposeStatus(pid))))
            }
            for v in liVendors where !summaries.contains(where: { $0.name == v.name }) {
                summaries.append(VendorSummary(name: v.name, iabBadge: nil, status: labels.li,
                                               policyUrl: v.policyUrl,
                                               stateKey: ToggleKey.owned(ToggleKey.sirdataVendorLI(v.id),
                                                                         ToggleKey.sirdataPurposeStatusLI(pid))))
            }
            items.append(PurposeRowModel(
                id: "\(stackRowId)_sdp_\(pid)",
                name: name,
                description: snap.sirdataPurposeById[pid]?.descriptionProcessed ?? "",
                toggleIntent: .toggleSirdataPurpose(Int32(pid)),
                labelKey: "sirdataPurpose\(pid)",
                consentToggleIntent: .toggleSirdataPurposeConsent(Int32(pid)),
                liToggleIntent: .toggleSirdataPurposeLI(Int32(pid)),
                consentVendorCount: consentVendors.count,
                liVendorCount: liVendors.count,
                consentVendors: summaries.filter { $0.status == labels.consent },
                liVendors: summaries.filter { $0.status == labels.li }
            ))
        }
        items.append(contentsOf: stackSpecialFeatureRows(snap: snap, labels: labels, specialFeatures: stack.specialFeatures, stackRowId: stackRowId))
        return items
    }

    /// One nested TCF-purpose row inside a stack, with the merged
    /// TCF + Google + Sirdata partner list (name-dedup across the MIXED list,
    /// then split by legal-basis label — mirrors the previous builder).
    private func stackTcfPurposeRow(snap: ConsentSnapshot, sd: ConsentStaticData, labels: StatusLabels, pid: Int, name: String, rowId: String) -> PurposeRowModel {
        let consentVendors = snap.vendors.filter { $0.filteredPurposes.contains(pid) }.sorted { $0.nameLower < $1.nameLower }
        let liVendors = snap.vendors.filter { $0.filteredLegIntPurposes.contains(pid) }.sorted { $0.nameLower < $1.nameLower }
        let sirdataConsentVendors = snap.sirdataVendors.filter { $0.purposes.contains(pid) }
        let sirdataLIVendors = snap.sirdataVendors.filter { $0.legIntPurposes.contains(pid) }
        var summaries: [VendorSummary] = []
        for v in consentVendors {
            summaries.append(VendorSummary(name: v.name, iabBadge: "IAB TCF", status: labels.consent,
                                           policyUrl: v.policyUrl,
                                           stateKey: ToggleKey.owned(ToggleKey.tcfVendor(v.id),
                                                                     ToggleKey.tcfPurposeStatus(pid))))
        }
        for v in liVendors where !summaries.contains(where: { $0.name == v.name }) {
            summaries.append(VendorSummary(name: v.name, iabBadge: "IAB TCF", status: labels.li,
                                           policyUrl: v.policyUrl,
                                           stateKey: ToggleKey.owned(ToggleKey.tcfVendorLI(v.id),
                                                                     ToggleKey.tcfPurposeStatusLI(pid))))
        }
        if sd.googlePurposes.contains(pid) {
            for gp in snap.googleProvidersSortedByName where !summaries.contains(where: { $0.name == gp.name }) {
                summaries.append(VendorSummary(name: gp.name, iabBadge: nil, status: labels.consent,
                                               policyUrl: gp.policyUrl,
                                               stateKey: ToggleKey.owned(ToggleKey.googleProvider(gp.id),
                                                                         ToggleKey.tcfPurposeStatus(pid))))
            }
        }
        for sv in sirdataConsentVendors where !summaries.contains(where: { $0.name == sv.name }) {
            summaries.append(VendorSummary(name: sv.name, iabBadge: nil, status: labels.consent,
                                           policyUrl: sv.policyUrl,
                                           stateKey: ToggleKey.owned(ToggleKey.sirdataVendor(sv.id),
                                                                     ToggleKey.tcfPurposeStatus(pid))))
        }
        for sv in sirdataLIVendors where !summaries.contains(where: { $0.name == sv.name }) {
            summaries.append(VendorSummary(name: sv.name, iabBadge: nil, status: labels.li,
                                           policyUrl: sv.policyUrl,
                                           stateKey: ToggleKey.owned(ToggleKey.sirdataVendorLI(sv.id),
                                                                     ToggleKey.tcfPurposeStatusLI(pid))))
        }
        return PurposeRowModel(
            id: rowId,
            name: name,
            description: snap.purposeById[pid]?.descriptionProcessed ?? "",
            toggleIntent: .togglePurpose(Int32(pid)),
            labelKey: "purpose\(pid)",
            consentToggleIntent: .togglePurposeConsent(Int32(pid)),
            liToggleIntent: .togglePurposeLI(Int32(pid)),
            consentVendorCount: consentVendors.count + (sd.googlePurposes.contains(pid) ? snap.googleProviders.count : 0) + sirdataConsentVendors.count,
            liVendorCount: liVendors.count + sirdataLIVendors.count,
            consentVendors: summaries.filter { $0.status == labels.consent },
            liVendors: summaries.filter { $0.status == labels.li }
        )
    }

    /// Nested special-feature rows of an expanded stack (TCF or Sirdata).
    private func stackSpecialFeatureRows(snap: ConsentSnapshot, labels: StatusLabels, specialFeatures: [Int], stackRowId: String) -> [PurposeRowModel] {
        var items: [PurposeRowModel] = []
        for sfId in specialFeatures {
            guard let sf = snap.specialFeatureById[sfId] else { continue }
            let summaries = tcfVendorSummaries(snap: snap, labels: labels,
                                                   purposeStatusKey: ToggleKey.specialFeatureStatus(sfId)) { $0.specialFeatures.contains(sfId) }
            items.append(PurposeRowModel(
                id: "\(stackRowId)_sf_\(sfId)",
                name: sf.name,
                description: sf.descriptionProcessed,
                toggleIntent: .toggleSpecialFeature(Int32(sfId)),
                labelKey: "specialFeature\(sfId)",
                consentVendorCount: summaries.count,
                consentVendors: summaries
            ))
        }
        return items
    }

    /// Row id of a support-section row, derived from its locale label key
    /// ("purpose1", "specialFeature2"). Single source for the id so the
    /// structure builder and `buildToggles` can never drift apart — the toggle
    /// VALUES are looked up under exactly this key.
    private func supportRowId(labelKey: String) -> String { "support-\(labelKey)" }

    /// Derives the complete, tap-immutable Purposes screen STRUCTURE from the
    /// snapshot. Every rule is a verbatim port of the web-parity filters,
    /// dedups, orderings and special cases. Live values are NEVER stored here.
    private func buildPurposesScreen(sd: ConsentStaticData, screen: ConsentScreen) -> PurposesScreenModel {
        let snap = sd.snap
        var model = PurposesScreenModel()
        let labels = makeStatusLabels()
        // Cookie wall workflow: the PURPOSE_ONE screen shows ONLY purpose 1
        // with a toggle (web parity: togglePurposeOneShowing).
        let isPurposeOne = screen == ConsentScreen.purposeOne

        // Ids covered by a displayed stack (so they don't repeat at root).
        let tcfStackPurposeIds: Set<Int> = sd.expandedDisplayMode ? [] : Set(snap.stacks.flatMap { $0.purposes })
        let tcfStackSfIds: Set<Int> = sd.expandedDisplayMode ? [] : Set(snap.stacks.flatMap { $0.specialFeatures })
        let sdStackTcfPurposeIds: Set<Int> = sd.expandedDisplayMode ? [] : Set(snap.sirdataStacks.flatMap { $0.purposes })
        let sdStackSirdataPurposeIds: Set<Int> = sd.expandedDisplayMode ? [] : sd.stackSirdataPurposeIds
        let sdStackSfIds: Set<Int> = sd.expandedDisplayMode ? [] : Set(snap.sirdataStacks.flatMap { $0.specialFeatures })

        // ─── Publisher standard purposes (web parity: Purposes.jsx filter) ──
        if !isPurposeOne {
            let filteredStandard = snap.standardPurposes.filter { sp in
                let pid = Int(sp.id)
                return !tcfStackPurposeIds.contains(pid) && !sdStackTcfPurposeIds.contains(pid) &&
                    snap.purposeById[pid] == nil
            }
            for sp in filteredStandard {
                let pid = Int(sp.id)
                let tcf = snap.purposeById[pid]
                model.publisherPurposeRows.append(PurposeRowModel(
                    id: "std_purpose_\(pid)",
                    name: tcf?.name ?? "\(localize.getText(key: LocaleKey.purposesStack.key)) \(sp.id)",
                    description: tcf?.descriptionProcessed ?? "",
                    toggleIntent: .toggleStandardPurpose(sp.id),
                    labelKey: "purpose\(pid)",
                    legalBasisLabel: localize.getText(key: sp.isLI ? LocaleKey.purposesPublisherLi.key : LocaleKey.purposesPublisherConsent.key)
                ))
            }
        }
        // Publisher custom purposes (web parity: CustomPurpose.jsx). NOTE:
        // intentionally NOT gated on isPurposeOne — preserves the previous
        // implementation's behavior.
        for cp in snap.customPurposes {
            let cpVendorSummaries: [VendorSummary] = cp.vendorName.map { vendorName in
                [VendorSummary(
                    name: vendorName,
                    iabBadge: nil,
                    status: cp.isLI ? labels.li : labels.consent,
                    policyUrl: cp.vendorPolicyUrl,
                    stateKey: ToggleKey.customPurpose(Int(cp.id))
                )]
            } ?? []
            model.publisherPurposeRows.append(PurposeRowModel(
                id: "custom_purpose_\(cp.id)",
                name: cp.name,
                description: cp.descriptionProcessed,
                toggleIntent: .toggleCustomPurpose(cp.id),
                consentVendorCount: cp.isLI ? 0 : cpVendorSummaries.count,
                liVendorCount: cp.isLI ? cpVendorSummaries.count : 0,
                consentVendors: cp.isLI ? [] : cpVendorSummaries,
                liVendors: cp.isLI ? cpVendorSummaries : [],
                legalBasisLabel: cp.vendorName == nil
                    ? localize.getText(key: cp.isLI ? LocaleKey.purposesPublisherLi.key : LocaleKey.purposesPublisherConsent.key)
                    : ""
            ))
        }

        // ─── Activities (stacks — Sirdata stacks take priority, web parity) ─
        if !isPurposeOne && !sd.expandedDisplayMode {
            if !snap.sirdataStacks.isEmpty {
                let lastId = snap.sirdataStacks.last?.id
                model.stackRows = snap.sirdataStacks.map { stack in
                    let rowId = "sd_stack_\(stack.id)"
                    return StackRowModel(
                        id: rowId,
                        name: stack.name,
                        description: stack.descriptionProcessed,
                        toggleIntent: .toggleSirdataStack(stack.id),
                        isSirdata: true,
                        showDivider: stack.id != lastId,
                        nestedItems: sirdataStackNestedRows(snap: snap, sd: sd, labels: labels, stack: stack, stackRowId: rowId)
                    )
                }
            } else if !snap.stacks.isEmpty {
                let lastId = snap.stacks.last?.id
                model.stackRows = snap.stacks.map { stack in
                    let rowId = "stack_\(stack.id)"
                    return StackRowModel(
                        id: rowId,
                        name: stack.name,
                        description: stack.descriptionProcessed,
                        toggleIntent: .toggleTcfStack(stack.id),
                        showDivider: stack.id != lastId,
                        nestedItems: tcfStackNestedRows(snap: snap, sd: sd, labels: labels, stack: stack, stackRowId: rowId)
                    )
                }
            }
            model.showActivitiesHeader = !model.stackRows.isEmpty
        }

        // ─── Free purposes (not covered by a displayed stack) ───────────────
        let rootPurposes: [SnapPurpose] = isPurposeOne
            ? snap.purposes.filter { $0.id == 1 }
            : snap.purposes.filter { !tcfStackPurposeIds.contains($0.id) && !sdStackTcfPurposeIds.contains($0.id) && $0.id != 1 }
        for purpose in rootPurposes {
            let pid = purpose.id
            let vendorData = tcfPurposeVendorData(snap: snap, sd: sd, labels: labels, pid: pid)
            model.freePurposeRows.append(PurposeRowModel(
                id: "purpose_\(pid)",
                name: purpose.name,
                description: purpose.descriptionProcessed,
                toggleIntent: .togglePurpose(Int32(pid)),
                hasStandardPurpose: snap.standardPurposes.contains { Int($0.id) == pid },
                labelKey: "purpose\(pid)",
                consentToggleIntent: .togglePurposeConsent(Int32(pid)),
                liToggleIntent: .togglePurposeLI(Int32(pid)),
                consentVendorCount: vendorData.consent.count,
                liVendorCount: vendorData.li.count,
                consentVendors: vendorData.consent,
                liVendors: vendorData.li,
                standardPurposeIsLI: snap.standardPurposes.first { Int($0.id) == pid }?.isLI == true,
                standardPurposeToggleIntent: .toggleStandardPurpose(Int32(pid))
            ))
        }
        if !isPurposeOne {
            let rootSirdata = snap.sirdataPurposes.filter { !sdStackSirdataPurposeIds.contains($0.id) }
            for purpose in rootSirdata {
                let pid = purpose.id
                let vendorData = sirdataPurposeVendorData(snap: snap, labels: labels, pid: pid)
                model.freePurposeRows.append(PurposeRowModel(
                    id: "sd_purpose_\(pid)",
                    name: purpose.name,
                    description: purpose.descriptionProcessed,
                    toggleIntent: .toggleSirdataPurpose(Int32(pid)),
                    hasStandardPurpose: false,
                    labelKey: "sirdataPurpose\(pid)",
                    consentToggleIntent: .toggleSirdataPurposeConsent(Int32(pid)),
                    liToggleIntent: .toggleSirdataPurposeLI(Int32(pid)),
                    consentVendorCount: vendorData.consent.count,
                    liVendorCount: vendorData.li.count,
                    consentVendors: vendorData.consent,
                    liVendors: vendorData.li
                ))
            }
        }

        // ─── Special features (GAP-08: SF1 prefix inline) ───────────────────
        if !isPurposeOne {
            let rootSpecialFeatures = snap.specialFeatures.filter {
                !tcfStackSfIds.contains($0.id) && !sdStackSfIds.contains($0.id) && $0.id != 2 &&
                    !($0.id == 1 && snap.sirdataStacks.contains(where: { Int($0.id) == 3 }))
            }
            for sf in rootSpecialFeatures {
                let sfId = sf.id
                let sfName = sfId == 1
                    ? "\(localize.getText(key: LocaleKey.purposesSpecialFeature1Prefix.key)) \(sf.name)"
                    : sf.name
                let sfVendors = tcfVendorSummaries(snap: snap, labels: labels,
                                                   purposeStatusKey: ToggleKey.specialFeatureStatus(sfId)) { $0.specialFeatures.contains(sfId) }
                model.specialFeatureRows.append(PurposeRowModel(
                    id: "sf_\(sfId)",
                    name: sfName,
                    description: sf.descriptionProcessed,
                    toggleIntent: .toggleSpecialFeature(Int32(sfId)),
                    labelKey: "specialFeature\(sfId)",
                    consentVendorCount: sfVendors.count,
                    consentVendors: sfVendors
                ))
            }
        }

        // ─── Support section (purpose 1 + special feature 2) ────────────────
        // Web parity: Purposes.jsx renders `purposes.filter(id === 1)` then
        // `specialFeatures.filter(id === 2)`, each with `hideMainToggle` — the
        // main toggle moves into the partner-count header (Purpose.jsx:88,
        // SpecialFeature.jsx:51).
        //
        // Each list is walked SEPARATELY and the row type comes from the list
        // being walked. Never infer the type from the id: TCF numbers ids per
        // type, so purpose 1, feature 1, special feature 1 and special purpose 1
        // all coexist and cross-list id tests are always wrong.
        if !isPurposeOne {
            for purpose in snap.purposes where purpose.id == 1 {
                let pid = purpose.id
                let vendorData = tcfPurposeVendorData(snap: snap, sd: sd, labels: labels, pid: pid)
                // Same resolution as the free purpose rows: drive the consent
                // sub-channel when the purpose has one, else the combined toggle.
                let consentIntent: ConsentIntent = sd.purposeConsentIds.contains(pid)
                    ? .togglePurposeConsent(Int32(pid))
                    : .togglePurpose(Int32(pid))
                model.supportRows.append(PurposeRowModel(
                    id: supportRowId(labelKey: "purpose\(pid)"),
                    name: purpose.name,
                    description: purpose.descriptionProcessed,
                    hideMainToggle: true,
                    hasStandardPurpose: snap.standardPurposes.contains { Int($0.id) == pid },
                    labelKey: "purpose\(pid)",
                    consentToggleIntent: consentIntent,
                    liToggleIntent: .togglePurposeLI(Int32(pid)),
                    consentVendorCount: vendorData.consent.count,
                    liVendorCount: vendorData.li.count,
                    consentVendors: vendorData.consent,
                    liVendors: vendorData.li,
                    standardPurposeIsLI: snap.standardPurposes.first { Int($0.id) == pid }?.isLI == true,
                    standardPurposeToggleIntent: .toggleStandardPurpose(Int32(pid))
                ))
            }
            // Web parity: SF2 is skipped here when a displayed stack already
            // covers it (`stackSpecialFeatures.indexOf(id) === -1`).
            let supportSpecialFeatures = snap.specialFeatures.filter {
                $0.id == 2 && !tcfStackSfIds.contains($0.id) && !sdStackSfIds.contains($0.id)
            }
            for sf in supportSpecialFeatures {
                let sfId = sf.id
                let sfVendors = tcfVendorSummaries(snap: snap, labels: labels,
                                                   purposeStatusKey: ToggleKey.specialFeatureStatus(sfId)) { $0.specialFeatures.contains(sfId) }
                model.supportRows.append(PurposeRowModel(
                    id: supportRowId(labelKey: "specialFeature\(sfId)"),
                    name: sf.name,
                    description: sf.descriptionProcessed,
                    hideMainToggle: true,
                    labelKey: "specialFeature\(sfId)",
                    consentToggleIntent: .toggleSpecialFeature(Int32(sfId)),
                    consentVendorCount: sfVendors.count,
                    consentVendors: sfVendors
                ))
            }
        }

        // ─── GAP-06: Special Purposes and Features in separate sections ─────
        if !isPurposeOne {
            for sp in snap.specialPurposes {
                let spId = sp.id
                let spVendors = tcfVendorSummaries(snap: snap, labels: labels) { $0.specialPurposes.contains(spId) }
                model.specialPurposeRows.append(PurposeRowModel(
                    id: "sp_purpose_\(spId)",
                    name: sp.name,
                    description: sp.descriptionProcessed,
                    labelKey: "specialPurpose\(spId)",
                    consentVendorCount: spVendors.count,
                    vendorCountWording: .activityUse,
                    consentVendors: spVendors
                ))
            }
            for feat in snap.features {
                let featId = feat.id
                let featVendors = tcfVendorSummaries(snap: snap, labels: labels) { $0.features.contains(featId) }
                model.featureRows.append(PurposeRowModel(
                    id: "feat_purpose_\(featId)",
                    name: feat.name,
                    description: feat.descriptionProcessed,
                    labelKey: "feature\(featId)",
                    consentVendorCount: featVendors.count,
                    vendorCountWording: .activityUse,
                    consentVendors: featVendors
                ))
            }
        }

        return model
    }

    // MARK: - Toggles Derivation (the ONLY per-tap computation)

    /// Builds the complete `TogglesState` from the live selector snapshot.
    /// Keys MUST mirror the ids the structure builders emit — both sides use
    /// the same literal schemes ("purpose_X", "<stackRowId>_p_X", ToggleKey.*).
    private func buildToggles(sd: ConsentStaticData, computer: ConsentStateComputer) -> TogglesState {
        let snap = sd.snap
        let labels = makeStatusLabels()
        let sel = computer.sel
        var t = TogglesState()
        func consentAcc(_ isOn: Bool) -> String { isOn ? labels.accepted : labels.notAccepted }
        func liAcc(_ isOn: Bool) -> String { isOn ? labels.notRejected : labels.rejected }

        // ─── Purposes screen: free rows ─────────────────────────────────
        for p in snap.purposes {
            let id = "purpose_\(p.id)"
            t.row[id] = computer.purposeState(p.id)
            t.consent[id] = computer.purposeConsentState(p.id)
            t.li[id] = computer.purposeLIState(p.id)
            t.standard[id] = computer.standardPurposeState(p.id)
        }
        for p in snap.sirdataPurposes {
            let id = "sd_purpose_\(p.id)"
            t.row[id] = computer.sirdataPurposeState(p.id)
            t.consent[id] = computer.sirdataPurposeConsentState(p.id)
            t.li[id] = computer.sirdataPurposeLIState(p.id)
        }
        for sf in snap.specialFeatures {
            t.row["sf_\(sf.id)"] = computer.specialFeatureState(sf.id)
        }
        for sp in snap.standardPurposes {
            t.row["std_purpose_\(sp.id)"] = computer.standardPurposeState(Int(sp.id))
        }
        for cp in snap.customPurposes {
            let state = computer.customPurposeState(Int(cp.id))
            t.row["custom_purpose_\(cp.id)"] = state
            t.acceptance[ToggleKey.customPurpose(Int(cp.id))] =
                cp.isLI ? liAcc(state == ToggleState.on) : consentAcc(state == ToggleState.on)
        }

        // ─── Purposes screen: stacks + nested rows ──────────────────────
        func fillNested(stackRowId: String, purposes: [Int], specialFeatures: [Int], extraPurposes: [Int]) {
            for pid in purposes where pid != 1 {
                guard sd.availablePurposeIds.contains(pid), sd.tcfPurposeNameMap[pid] != nil else { continue }
                let id = "\(stackRowId)_p_\(pid)"
                t.row[id] = computer.purposeState(pid)
                t.consent[id] = computer.purposeConsentState(pid)
                t.li[id] = computer.purposeLIState(pid)
            }
            for pid in extraPurposes {
                guard sd.availableSirdataPurposeIds.contains(pid), sd.sirdataPurposeNameMap[pid] != nil else { continue }
                let id = "\(stackRowId)_sdp_\(pid)"
                t.row[id] = computer.sirdataPurposeState(pid)
                t.consent[id] = computer.sirdataPurposeConsentState(pid)
                t.li[id] = computer.sirdataPurposeLIState(pid)
            }
            for sfId in specialFeatures where snap.specialFeatureById[sfId] != nil {
                t.row["\(stackRowId)_sf_\(sfId)"] = computer.specialFeatureState(sfId)
            }
        }
        for stack in snap.stacks {
            let rowId = "stack_\(stack.id)"
            t.row[rowId] = computer.stackState(purposes: stack.purposes, specialFeatures: stack.specialFeatures, extraPurposes: [])
            fillNested(stackRowId: rowId, purposes: stack.purposes, specialFeatures: stack.specialFeatures, extraPurposes: [])
        }
        for stack in snap.sirdataStacks {
            let rowId = "sd_stack_\(stack.id)"
            t.row[rowId] = computer.stackState(purposes: stack.purposes, specialFeatures: stack.specialFeatures, extraPurposes: stack.extraPurposes)
            fillNested(stackRowId: rowId, purposes: stack.purposes, specialFeatures: stack.specialFeatures, extraPurposes: stack.extraPurposes)
        }

        // ─── Purposes screen: support rows (purpose 1 + SF2) ────────────
        // Mirrors the structure builder one-for-one: same ids (via
        // supportRowId), same per-type walk, only the consent/LI sub-channels
        // exist (the main toggle is hidden on these rows). No cross-list id
        // test — TCF ids are per-type.
        for purpose in snap.purposes where purpose.id == 1 {
            let pid = purpose.id
            let rowId = supportRowId(labelKey: "purpose\(pid)")
            let consentOnly = computer.purposeConsentState(pid)
            t.consent[rowId] = consentOnly.isEmpty ? computer.purposeState(pid) : consentOnly
            t.li[rowId] = computer.purposeLIState(pid)
            t.standard[rowId] = computer.standardPurposeState(pid)
        }
        for sf in snap.specialFeatures where sf.id == 2 {
            t.consent[supportRowId(labelKey: "specialFeature\(sf.id)")] = computer.specialFeatureState(sf.id)
        }

        // ─── Vendor acceptance labels (purposes-screen partner lists) ───
        for v in snap.vendors {
            t.acceptance[ToggleKey.tcfVendor(v.id)] = consentAcc(sel.vendorIds.contains(v.id))
            t.acceptance[ToggleKey.tcfVendorLI(v.id)] = liAcc(sel.vendorLIIds.contains(v.id))
        }
        for v in snap.sirdataVendors {
            t.acceptance[ToggleKey.sirdataVendor(v.id)] = consentAcc(sel.sirdataVendorIds.contains(v.id))
            t.acceptance[ToggleKey.sirdataVendorLI(v.id)] = liAcc(sel.sirdataVendorLIIds.contains(v.id))
        }
        for p in snap.googleProviders {
            t.acceptance[ToggleKey.googleProvider(p.id)] = consentAcc(computer.acProviderState(p) == ToggleState.on)
        }

        // ─── Purpose status labels (vendors-screen section items) ───────
        var purposeConsentOn: [Int: Bool] = [:]
        var purposeLIOn: [Int: Bool] = [:]
        for id in sd.availablePurposeIds {
            // D3: the CONSENT channel, not the aggregated four-state row. A dual-basis
            // purpose with consent given and legitimate interest opposed aggregates to
            // PARTIALLY_ACCEPTED, so `== on` was false and the line read "Not accepted"
            // while the consent WAS given — the web tests set membership on the consent
            // channel (`selectedPurposeIds.has(id)`).
            let consentOn = computer.purposeConsentState(id) == ToggleState.on
            let liOn = computer.purposeLIState(id) == ToggleState.on
            purposeConsentOn[id] = consentOn
            purposeLIOn[id] = liOn
            t.acceptance[ToggleKey.tcfPurposeStatus(id)] = consentAcc(consentOn)
            t.acceptance[ToggleKey.tcfPurposeStatusLI(id)] = liAcc(liOn)
        }
        var specialFeatureOn: [Int: Bool] = [:]
        for sf in snap.specialFeatures {
            let on = computer.specialFeatureState(sf.id) == ToggleState.on
            specialFeatureOn[sf.id] = on
            t.acceptance[ToggleKey.specialFeatureStatus(sf.id)] = consentAcc(on)
        }
        var sirdataPurposeConsentOn: [Int: Bool] = [:]
        var sirdataPurposeLIOn: [Int: Bool] = [:]
        for id in sd.availableSirdataPurposeIds {
            // D3: consent channel, see the TCF purposes above.
            let consentOn = computer.sirdataPurposeConsentState(id) == ToggleState.on
            let liOn = computer.sirdataPurposeLIState(id) == ToggleState.on
            sirdataPurposeConsentOn[id] = consentOn
            sirdataPurposeLIOn[id] = liOn
            t.acceptance[ToggleKey.sirdataPurposeStatus(id)] = consentAcc(consentOn)
            t.acceptance[ToggleKey.sirdataPurposeStatusLI(id)] = liAcc(liOn)
        }

        // ─── FRONT-1276: the same statuses, read UNDER a given partner ───
        //
        // Arbitré par le mainteneur : un statut reflète la finalité ET le partenaire. The
        // purpose-scoped entries above answer "was this purpose granted?", so a partner whose
        // own bit was false still showed « accepté » on every purpose it declares. One entry
        // per (purpose, partner channel); the views keep reading a single ready-to-paint
        // value, as the architecture requires.
        // Two keys per (partner, purpose) pair, filled together because both screens ask the
        // same question of the same pair — the partners screen reads the purpose under a
        // partner SECTION, the purposes screen reads a partner under the purpose (D1). Both
        // resolve to `purposeOn && partnerOn`; only the lookup differs.
        //
        // `channelKey` is the partner's section key (partners screen), `partnerKey` its
        // vendor-level key (purposes screen).
        func ownConsent(_ purposeKey: String, _ channelKey: String, _ partnerKey: String,
                        _ purposeOn: Bool, _ partnerOn: Bool) {
            let label = consentAcc(purposeOn && partnerOn)
            t.acceptance[ToggleKey.owned(purposeKey, channelKey)] = label
            t.acceptance[ToggleKey.owned(partnerKey, purposeKey)] = label
        }
        func ownLI(_ purposeKey: String, _ channelKey: String, _ partnerKey: String,
                   _ purposeOn: Bool, _ partnerOn: Bool) {
            let label = liAcc(purposeOn && partnerOn)
            t.acceptance[ToggleKey.owned(purposeKey, channelKey)] = label
            t.acceptance[ToggleKey.owned(partnerKey, purposeKey)] = label
        }
        let sirdataById = Dictionary(uniqueKeysWithValues: snap.sirdataVendors.map { ($0.id, $0) })

        /// The four lists a Sirdata partner exposes through a carrier row, or on its own.
        func fillSirdataOwned(_ sv: SnapSirdataVendor, partnerId: String,
                              consentSlot: String, liSlot: String) {
            let consentChannel = ToggleKey.partnerSection(partnerId, consentSlot)
            let partnerKey = ToggleKey.sirdataVendor(sv.id)
            let consentOn = sel.sirdataVendorIds.contains(sv.id)
            for pid in sv.purposesList {
                ownConsent(ToggleKey.tcfPurposeStatus(pid), consentChannel, partnerKey,
                           purposeConsentOn[pid] ?? false, consentOn)
            }
            for pid in sv.extraPurposesList {
                ownConsent(ToggleKey.sirdataPurposeStatus(pid), consentChannel, partnerKey,
                           sirdataPurposeConsentOn[pid] ?? false, consentOn)
            }
            let liChannel = ToggleKey.partnerSection(partnerId, liSlot)
            let partnerLIKey = ToggleKey.sirdataVendorLI(sv.id)
            let liOn = sel.sirdataVendorLIIds.contains(sv.id)
            for pid in sv.legIntPurposesList {
                ownLI(ToggleKey.tcfPurposeStatusLI(pid), liChannel, partnerLIKey, purposeLIOn[pid] ?? false, liOn)
            }
            for pid in sv.legIntExtraPurposesList {
                ownLI(ToggleKey.sirdataPurposeStatusLI(pid), liChannel, partnerLIKey,
                      sirdataPurposeLIOn[pid] ?? false, liOn)
            }
        }

        for v in snap.vendors {
            let partnerId = "tcf_\(v.id)"
            let consentChannel = ToggleKey.partnerSection(partnerId, "consent")
            let partnerKey = ToggleKey.tcfVendor(v.id)
            let consentOn = sel.vendorIds.contains(v.id)
            for pid in v.filteredPurposesList {
                ownConsent(ToggleKey.tcfPurposeStatus(pid), consentChannel, partnerKey,
                           purposeConsentOn[pid] ?? false, consentOn)
            }
            for sf in snap.specialFeatures where v.specialFeatures.contains(sf.id) {
                ownConsent(ToggleKey.specialFeatureStatus(sf.id), consentChannel, partnerKey,
                           specialFeatureOn[sf.id] ?? false, consentOn)
            }
            let liChannel = ToggleKey.partnerSection(partnerId, "li")
            let liOn = sel.vendorLIIds.contains(v.id)
            for pid in v.filteredLegIntPurposesList {
                ownLI(ToggleKey.tcfPurposeStatusLI(pid), liChannel, ToggleKey.tcfVendorLI(v.id),
                      purposeLIOn[pid] ?? false, liOn)
            }
            if let linked = v.linkedSirdata, let sv = sirdataById[linked.id] {
                fillSirdataOwned(sv, partnerId: partnerId, consentSlot: "nonTcConsent", liSlot: "nonTcLI")
            }
        }
        for sv in snap.sirdataVendors {
            fillSirdataOwned(sv, partnerId: "sd_\(sv.id)", consentSlot: "consent", liSlot: "li")
        }
        for p in snap.googleProviders {
            let partnerId = "gp_\(p.id)"
            let consentChannel = ToggleKey.partnerSection(partnerId, "consent")
            // The provider's OWN bit, not acProviderState: that one aggregates the fused
            // Sirdata partner, and a status reports what THIS partner was granted.
            let consentOn = sel.providerIds.contains(p.id)
            for pid in sd.googlePurposes {
                ownConsent(ToggleKey.tcfPurposeStatus(pid), consentChannel, ToggleKey.googleProvider(p.id),
                           purposeConsentOn[pid] ?? false, consentOn)
            }
            if let linked = p.linkedSirdata, let sv = sirdataById[linked.id] {
                fillSirdataOwned(sv, partnerId: partnerId, consentSlot: "nonTcConsent", liSlot: "nonTcLI")
            }
        }

        // ─── Vendors screen: partner rows + section toggles ─────────────
        // FRONT-1276: a row the apply screen presents ON ITS OWN reports its own state only —
        // aggregating the partner that was split off would show an answer given elsewhere.
        for v in snap.vendors {
            let partnerId = "tcf_\(v.id)"
            t.row[ToggleKey.partnerRow(partnerId)] =
                computer.vendorCombinedState(v, unlinked: isUnlinkedRow(partnerId))
            t.row[ToggleKey.partnerSection(partnerId, "consent")] = sel.vendorIds.contains(v.id) ? ToggleState.on : ToggleState.off
            t.row[ToggleKey.partnerSection(partnerId, "li")] = sel.vendorLIIds.contains(v.id) ? ToggleState.on : ToggleState.off
            if let linked = v.linkedSirdata {
                t.row[ToggleKey.partnerSection(partnerId, "nonTcConsent")] = sel.sirdataVendorIds.contains(linked.id) ? ToggleState.on : ToggleState.off
                t.row[ToggleKey.partnerSection(partnerId, "nonTcLI")] = sel.sirdataVendorLIIds.contains(linked.id) ? ToggleState.on : ToggleState.off
            }
        }
        for v in snap.sirdataVendors {
            let partnerId = "sd_\(v.id)"
            t.row[ToggleKey.partnerRow(partnerId)] =
                computer.sirdataVendorCombinedState(v, unlinked: isUnlinkedRow(partnerId))
            t.row[ToggleKey.partnerSection(partnerId, "consent")] = sel.sirdataVendorIds.contains(v.id) ? ToggleState.on : ToggleState.off
            t.row[ToggleKey.partnerSection(partnerId, "li")] = sel.sirdataVendorLIIds.contains(v.id) ? ToggleState.on : ToggleState.off
        }
        for p in snap.googleProviders {
            let partnerId = "gp_\(p.id)"
            let state = computer.acProviderState(p, unlinked: isUnlinkedRow(partnerId))
            t.row[ToggleKey.partnerRow(partnerId)] = state
            t.row[ToggleKey.partnerSection(partnerId, "consent")] = state
            if let linked = p.linkedSirdata {
                t.row[ToggleKey.partnerSection(partnerId, "nonTcConsent")] = sel.sirdataVendorIds.contains(linked.id) ? ToggleState.on : ToggleState.off
                t.row[ToggleKey.partnerSection(partnerId, "nonTcLI")] = sel.sirdataVendorLIIds.contains(linked.id) ? ToggleState.on : ToggleState.off
            }
        }
        for cp in snap.customPurposes where (cp.vendorName?.isEmpty ?? true) == false {
            let partnerId = "custom_\(cp.id)"
            let state = computer.customPurposeState(Int(cp.id))
            t.row[ToggleKey.partnerRow(partnerId)] = state
            t.row[ToggleKey.partnerSection(partnerId, "main")] = state
        }

        return t
    }

    // MARK: - State Refresh

    /// Recomputes ONLY the toggle values and publishes them — the single
    /// per-tap code path. Structure and expansion are untouched by design:
    /// a consent tap can never rebuild rows, texts or partner lists.
    /// Publishing is skipped when no value changed (e.g. the conflated
    /// counter-watcher refresh right after a tap's synchronous one), so a tap
    /// causes exactly ONE publish and one lightweight re-render.
    private func rebuildToggles() {
        guard let sd = staticData else { return }
        let computer = ConsentStateComputer(
            snap: sd.snap,
            purposeConsentIds: sd.purposeConsentIds,
            purposeLIIds: sd.purposeLIIds,
            sirdataPurposeConsentIds: sd.sirdataPurposeConsentIds,
            sirdataPurposeLIIds: sd.sirdataPurposeLIIds,
            sel: SelectedSets.bridge(consentData: store.consentData)
        )
        let newToggles = buildToggles(sd: sd, computer: computer)
        if newToggles == toggles { return }
        toggles = newToggles
    }

    /// Rebuilds the SCREEN STRUCTURE (rows, texts, partner lists) and then the
    /// toggles. Runs on load, navigation and workflow changes — NEVER on a
    /// consent tap. Everything the screen shows is loaded here, up front.
    private func rebuildStructure() {
        if staticData == nil || staticData?.workflow != uiState.workflow {
            staticData = buildStaticData()
        }
        let sd = staticData!
        toggleStateNames = .localized(localize)
        isRightToLeft = Self.resolveIsRightToLeft(localize.getLanguage().code)

        var newState = ConsentUiState()
        newState.purposes = sd.purposes
        newState.specialFeatures = sd.specialFeatures
        newState.vendors = sd.vendors
        newState.stacks = sd.stacks
        newState.sirdataPurposes = sd.sirdataPurposes
        newState.sirdataVendors = sd.sirdataVendors
        newState.sirdataStacks = sd.sirdataStacks
        newState.googleProviders = sd.googleProviders
        newState.googlePurposes = sd.googlePurposes
        newState.whiteLabel = sd.whiteLabel
        newState.disableTcf = sd.disableTcf
        newState.currentScreen = uiState.currentScreen
        newState.workflow = uiState.workflow
        newState.isLoading = false
        newState.error = nil
        newState.tcString = store.consentData.tcString
        newState.gdprApplies = IosCMPManager.shared.isGdprApplies()
        newState.title = sd.title
        newState.description = sd.description
        newState.customDescription = sd.customDescription
        newState.text1 = sd.text1
        newState.text2 = sd.text2
        newState.text3 = sd.text3
        newState.text1Segments = sd.text1Segments
        newState.text2Segments = sd.text2Segments
        newState.text3Segments = sd.text3Segments
        newState.specialPurposes = sd.specialPurposes
        newState.features = sd.features
        newState.standardPurposes = sd.standardPurposes
        newState.customPurposes = sd.customPurposes
        newState.privacyPolicyUrl = sd.privacyPolicyUrl
        newState.scopeReminderKey = sd.scopeReminderKey
        newState.scopeReminderSegments = sd.scopeReminderSegments
        newState.hostnames = sd.hostnames
        newState.utiqActive = sd.utiqActive
        newState.utiqNoticeUrl = sd.utiqNoticeUrl
        newState.isCnilVariant = sd.isCnilVariant
        newState.expandedDisplayMode = sd.expandedDisplayMode
        newState.hasLegitimateInterest = sd.hasLegitimateInterest
        newState.hasCustomPurposes = sd.hasCustomPurposes
        newState.hasUtiq = sd.hasUtiq
        newState.purposeConsentIds = sd.purposeConsentIds
        newState.purposeLIIds = sd.purposeLIIds
        newState.sirdataPurposeConsentIds = sd.sirdataPurposeConsentIds
        newState.sirdataPurposeLIIds = sd.sirdataPurposeLIIds
        newState.partnerCount = sd.partnerCount
        newState.scopeTextKey = sd.scopeTextKey
        newState.consentStorageKey = sd.consentStorageKey
        newState.maxAgeDays = sd.maxAgeDays
        newState.hasGeolocation = sd.hasGeolocation
        newState.dataController = sd.dataController
        newState.cookieDurationSeconds = sd.cookieDurationSeconds
        newState.sirdataStackIds = sd.sirdataStackIds
        newState.availablePurposeIds = sd.availablePurposeIds
        newState.availableSirdataPurposeIds = sd.availableSirdataPurposeIds
        newState.availableSpecialFeatureIds = sd.availableSpecialFeatureIds
        newState.choicesStyle = sd.choicesStyle
        newState.noConsentButton = sd.noConsentButton
        newState.closeButton = sd.closeButton
        newState.customPurposeNames = sd.customPurposeNames
        newState.tcfPurposeNameMap = sd.tcfPurposeNameMap
        newState.sirdataPurposeNameMap = sd.sirdataPurposeNameMap
        newState.tcfDataCategoryNameMap = sd.tcfDataCategoryNameMap
        newState.stackSirdataPurposeIds = sd.stackSirdataPurposeIds

        // Screen-scoped STRUCTURE building: each screen's content is built
        // when that screen is (re-)entered, complete and final — taps then
        // only flip toggles or expansion.
        let isPurposesScreen = newState.currentScreen == ConsentScreen.purposes
            || newState.currentScreen == ConsentScreen.purposeOne
        newState.purposesScreen = isPurposesScreen
            ? buildPurposesScreen(sd: sd, screen: newState.currentScreen)
            : uiState.purposesScreen
        let isVendorsScreen = newState.currentScreen == ConsentScreen.vendors
            || newState.currentScreen == ConsentScreen.vendorsMissing
        newState.partnerEntries = isVendorsScreen
            ? buildPartnerEntries(sd: sd, isVendorsMissing: newState.currentScreen == .vendorsMissing)
            : uiState.partnerEntries

        newState.usNat = buildUsNatData()

        // Expansion is owned here and carried across rebuilds.
        newState.expandedIds = uiState.expandedIds
        uiState = newState
        rebuildToggles()
    }

    // MARK: - FRONT-1342 : l'écran US « Privacy Choices »

    /// L'écran US, projeté depuis la règle PARTAGÉE — ou `nil` hors juridiction US.
    ///
    /// Rien n'est dérivé ici : `UsNatScreen.build` décide quelles oppositions sont offertes,
    /// quelle intro et quel libellé de contrôle leur correspondent, et quels États lister. Ce
    /// helper ne fait que **résoudre les libellés**. Miroir exact de `buildUsNatData()` côté
    /// Compose, et c'est délibéré : deux copies de plateforme d'une même règle divergeraient
    /// sans que rien ne le signale — le défaut qu'a coûté `executeSetGdprApplies`
    /// (FRONT-1308). Ici les deux plateformes ne font que **projeter** le même `UsNatScreen`.
    private func buildUsNatData() -> UsNatScreenData? {
        // `cmp.isCcpaApplies()` et SURTOUT PAS `IosCMPManager.shared.isCcpaApplies()` : le
        // second redemande la GÉOLOCALISATION à chaque appel et ignore la surcharge publique
        // `setCcpaApplies`, alors que le chargement des libellés US et le signal GPP lisent
        // tous deux le champ d'instance. Deux sources de vérité pour une seule question — et
        // l'écart est observable : un hôte appelant `setCcpaApplies(false)` sur un appareil de
        // géo US verrait l'écran US sans ses libellés, le fetch ayant été sauté. Relevé en
        // revue de la moitié Compose, appliqué ici d'emblée.
        guard cmp.isCcpaApplies() else { return nil }

        let ccpa = cmp.config?.cmp.ccpa
        let st = UsNatScreen.shared.build(
            ccpa: ccpa,
            applyToAllStates: ccpa?.applyToAllStates ?? false,
            optedOut: usNatEffectiveOptOut()
        )
        // Les clés sont QUALIFIÉES (`LocaleKey.usnatTitle`) et non écrites en membre
        // implicite (`.usnatTitle`), pour deux raisons qui vont dans le même sens : c'est la
        // forme du reste du paquet, et c'est la SEULE que `check-ios-abi.sh --consumers`
        // sache lire — son extracteur ne retient que les jetons `Type.membre`, donc une clé
        // inexistante écrite en membre implicite passerait son garde au vert. Vérifié en
        // l'injectant, pas déduit.
        let t = { (key: LocaleKey) in self.localize.getUsNatText(key: key.key) }
        return UsNatScreenData(
            title: t(LocaleKey.usnatTitle),
            subtitle: t(LocaleKey.usnatSubtitle),
            intro: st.introKey.map(t) ?? "",
            states: t(st.statesKey),
            para: st.showsPara ? t(LocaleKey.usnatPara) : "",
            toggleLabel: st.toggleKey.map(t) ?? "",
            more: t(LocaleKey.usnatMore),
            saveLabel: t(LocaleKey.usnatSave),
            statesTitle: t(LocaleKey.usnatStatesTitle),
            closeLabel: t(LocaleKey.buttonsClose),
            coveredStates: st.coveredStates,
            anyOffered: st.anyOffered,
            showsSave: st.showsSave,
            showsPara: st.showsPara,
            optedOut: st.optedOut
        )
    }

    /// La valeur que l'écran affiche : le choix en attente, sinon la décision enregistrée.
    ///
    /// Le repli lit `store.consentData.usNatSaleOptOut`, et SURTOUT PAS `isCcpaOptedOut()` :
    /// celui-ci lit la chaîne US Privacy, que le parc installé porte FABRIQUÉE (dérivée d'un
    /// toggle TCF avant FRONT-1345) et que rien dans le stockage ne distingue d'une décision
    /// authentique. Le contrôle se pré-cocherait donc sur un choix que personne n'a fait.
    private func usNatEffectiveOptOut() -> Bool {
        usNatPendingOptOut ?? (store.consentData.usNatSaleOptOut == UsNat.shared.SALE_OPT_OUT_YES)
    }

    /// Bascule le contrôle unique — EN MÉMOIRE. Voir `usNatPendingOptOut`.
    ///
    /// Seule la tranche `usNat` est reconstruite, et non toute la structure : rien d'autre
    /// dans l'écran ne dépend de cette valeur, et un `rebuildStructure()` complet repaierait
    /// ici des milliers de lectures bridgées pour un tap sur une case à cocher.
    func toggleUsNatOptOut() {
        usNatPendingOptOut = !usNatEffectiveOptOut()
        uiState.usNat = buildUsNatData()
    }

    /// Le SEUL chemin d'écriture de l'écran US.
    ///
    /// `setCcpaOptOut` pose la §6 et la §7 ENSEMBLE depuis la même source
    /// (`recordCcpaSaleOptOut`, FRONT-1348) : n'écrire que l'une rouvrirait la divergence que
    /// ce ticket-là a fermée. Et l'enregistrement part MÊME sans geste sur le contrôle, comme
    /// le web — avoir vu la notice et validé sans s'opposer EST une décision. Le garde est
    /// structurel : le bouton n'existe que sous `showsSave`.
    /// **La réponse est rapportée ICI, et l'ordre est structurel** (FRONT-1404).
    /// `setCcpaOptOut` est synchrone — c'est même la raison pour laquelle FRONT-1349 a écarté
    /// de la renvoyer sur le fil principal, « son retour ne dirait plus que l'écriture a eu
    /// lieu » — donc quand la `Task` s'exécute, `store.consentData.usNatSaleOptOut` porte déjà
    /// la décision que `postCcpaSaveAction` va lire. Poser le hit au site d'appel laisserait
    /// l'ordre à la discipline ; posé ici, il ne peut pas s'inverser.
    func commitUsNatOptOut() {
        IosCMPApi.shared.setCcpaOptOut(optedOut: usNatEffectiveOptOut())
        Task { try? await cmp.postCcpaSaveAction() }
    }

    // MARK: - Selection Methods

    // Kotlin default arguments are not exported to Swift —
    // `ignoreRelated: false` must be passed explicitly.

    func selectAll(isSelected: Bool) {
        selector.selectAll(isSelected: isSelected)
    }

    // T-V05: Select only missing vendors in VENDORS_MISSING mode (web parity).
    func selectMissingVendors() {
        selector.selectMissingVendors()
    }

    func selectPurpose(id: Int32, isSelected: Bool) {
        selector.selectPurpose(status: SelectorStatus(dataId: id, isSelected: isSelected, ignoreRelated: false))
    }

    /// Toggle only a TCF purpose's consent channel (not legitimate interest).
    func selectPurposeConsent(id: Int32, isSelected: Bool) {
        selector.selectPurposeConsent(status: SelectorStatus(dataId: id, isSelected: isSelected, ignoreRelated: false))
    }

    /// Toggle only a TCF purpose's legitimate interest channel.
    func selectPurposeLI(id: Int32, isSelected: Bool) {
        selector.selectPurposeLI(status: SelectorStatus(dataId: id, isSelected: isSelected, ignoreRelated: false))
    }

    /// Toggle only a Sirdata purpose's consent channel.
    func selectSirdataPurposeConsent(id: Int32, isSelected: Bool) {
        selector.selectSirdataPurposeConsent(status: SelectorStatus(dataId: id, isSelected: isSelected, ignoreRelated: false))
    }

    /// Toggle only a Sirdata purpose's legitimate interest channel.
    func selectSirdataPurposeLI(id: Int32, isSelected: Bool) {
        selector.selectSirdataPurposeLI(status: SelectorStatus(dataId: id, isSelected: isSelected, ignoreRelated: false))
    }

    /// FRONT-1276 — `unlinked` means the apply screen presents this row ON ITS OWN, its
    /// linked partner having been split off. The click must then stay on the row: propagating
    /// it would write a partner the user cannot see, and typically REVOKE the very answer
    /// that got the other one split off.
    func selectVendor(id: Int32, isSelected: Bool, unlinked: Bool = false) {
        selector.selectVendor(status: SelectorStatus(dataId: id, isSelected: isSelected, ignoreRelated: false),
                              unlinked: unlinked)
    }

    /// Toggle only a TCF vendor's consent channel (not legitimate interest).
    func selectVendorConsent(id: Int32, isSelected: Bool) {
        selector.selectVendorConsent(status: SelectorStatus(dataId: id, isSelected: isSelected, ignoreRelated: false))
    }

    /// Toggle only a TCF vendor's legitimate interest channel.
    func selectVendorLI(id: Int32, isSelected: Bool) {
        selector.selectVendorLI(status: SelectorStatus(dataId: id, isSelected: isSelected, ignoreRelated: false))
    }

    /// Toggle only a Sirdata vendor's consent channel.
    func selectSirdataVendorConsent(id: Int32, isSelected: Bool) {
        selector.selectSirdataVendorConsent(status: SelectorStatus(dataId: id, isSelected: isSelected, ignoreRelated: false))
    }

    /// Toggle only a Sirdata vendor's legitimate interest channel.
    func selectSirdataVendorLI(id: Int32, isSelected: Bool) {
        selector.selectSirdataVendorLI(status: SelectorStatus(dataId: id, isSelected: isSelected, ignoreRelated: false))
    }

    func selectSpecialFeature(id: Int32, isSelected: Bool) {
        selector.selectSpecialFeature(status: SelectorStatus(dataId: id, isSelected: isSelected, ignoreRelated: false))
    }

    func selectSirdataPurpose(id: Int32, isSelected: Bool) {
        selector.selectSirdataPurpose(status: SelectorStatus(dataId: id, isSelected: isSelected, ignoreRelated: false))
    }

    /// Toggle a publisher standard purpose (routes to consent or LI by legal basis).
    func selectStandardPurpose(id: Int32, isSelected: Bool) {
        selector.selectStandardPurpose(status: SelectorStatus(dataId: id, isSelected: isSelected, ignoreRelated: false))
    }

    /// Toggle a publisher custom purpose (routes to consent or LI by legal basis).
    func selectCustomPurpose(id: Int32, isSelected: Bool) {
        selector.selectCustomPurpose(status: SelectorStatus(dataId: id, isSelected: isSelected, ignoreRelated: false))
    }

    /// FRONT-1276 — see `selectVendor`.
    func selectSirdataVendor(id: Int32, isSelected: Bool, unlinked: Bool = false) {
        selector.selectSirdataVendor(status: SelectorStatus(dataId: id, isSelected: isSelected, ignoreRelated: false),
                                     unlinked: unlinked)
    }

    /// FRONT-1276 — see `selectVendor`.
    func selectACProvider(id: Int32, isSelected: Bool, unlinked: Bool = false) {
        selector.selectACProvider(status: SelectorStatus(dataId: id, isSelected: isSelected, ignoreRelated: false),
                                  unlinked: unlinked)
    }

    func selectTcfStack(id: Int32, isSelected: Bool) {
        selector.selectTcfStack(status: SelectorStatus(dataId: id, isSelected: isSelected, ignoreRelated: false))
    }

    func selectSirdataStack(id: Int32, isSelected: Bool) {
        selector.selectSirdataStack(status: SelectorStatus(dataId: id, isSelected: isSelected, ignoreRelated: false))
    }

    // MARK: - Intent-based toggles (per-row)
    // A row reports only a tap intent; the target value is computed HERE from the
    // LIVE selector/store state — never from the possibly-stale uiState the row was
    // composed with — so a tap always flips the true current value regardless of
    // any render lag. Mirrors the Android ConsentViewModel toggle* methods.
    private var toggleOn: String { ToggleState.on }

    /// Applies a per-row selection intent and rebuilds `uiState` SYNCHRONOUSLY,
    /// on the same runloop turn as the tap.
    ///
    /// This is the fix for the "a tap applies the previous action" bug on iOS.
    /// Previously the visual result of a tap was delivered only by the
    /// `updateCounter` watcher a runloop turn (and, with the old `delay(16)`, a
    /// frame) later — so the screen lagged one action behind. The selector
    /// cascade below is fully synchronous, so by the time it returns the store
    /// already holds the new state; rebuilding `uiState` right here makes the
    /// tapped zone update instantly. (The counter watcher still fires and
    /// recomputes identical state — harmless.)
    ///
    /// Crucially this lives in the Swift UI layer, compiled from source, so the
    /// fix is active immediately and does not depend on regenerating the
    /// committed `SirDataCMP.xcframework` binary.
    ///
    /// The mutation also bumps `updateCounter`, so the counter watcher fires a
    /// moment later and refreshes again with identical state — a harmless no-op
    /// diff. We deliberately do NOT suppress that callback: suppression risked
    /// dropping a different, coalesced external change (see the counter watcher).
    private func applyImmediately(_ mutation: () -> Void) {
        mutation()
        // TOGGLES ONLY — a consent tap never rebuilds structure or texts.
        rebuildToggles()
    }

    func togglePurpose(id: Int32) {
        applyImmediately { selectPurpose(id: id, isSelected: selector.getPurposeState(id: id) != toggleOn) }
    }
    func togglePurposeConsent(id: Int32) {
        applyImmediately { selectPurposeConsent(id: id, isSelected: selector.getPurposeConsentState(id: id) != toggleOn) }
    }
    func togglePurposeLI(id: Int32) {
        applyImmediately { selectPurposeLI(id: id, isSelected: selector.getPurposeLIState(id: id) != toggleOn) }
    }
    func toggleSirdataPurpose(id: Int32) {
        applyImmediately { selectSirdataPurpose(id: id, isSelected: selector.getSirdataPurposeState(id: id) != toggleOn) }
    }
    func toggleSirdataPurposeConsent(id: Int32) {
        applyImmediately { selectSirdataPurposeConsent(id: id, isSelected: selector.getSirdataPurposeConsentState(id: id) != toggleOn) }
    }
    func toggleSirdataPurposeLI(id: Int32) {
        applyImmediately { selectSirdataPurposeLI(id: id, isSelected: selector.getSirdataPurposeLIState(id: id) != toggleOn) }
    }
    func toggleSpecialFeature(id: Int32) {
        applyImmediately {
            let current = store.consentData.coreData.selectedSpecialFeatureIds.contains(KotlinInt(int: id))
            selectSpecialFeature(id: id, isSelected: !current)
        }
    }
    func toggleStandardPurpose(id: Int32) {
        applyImmediately { selectStandardPurpose(id: id, isSelected: selector.getStandardPurposeState(id: id) != toggleOn) }
    }
    func toggleCustomPurpose(id: Int32) {
        applyImmediately { selectCustomPurpose(id: id, isSelected: selector.getCustomPurposeState(id: id) != toggleOn) }
    }
    func toggleTcfStack(id: Int32) {
        applyImmediately {
            let current = store.vendorList.getStack(id: id).map {
                selector.getStackState(purposeIds: $0.purposes, specialFeatureIds: $0.specialFeatures, sirdataPurposeIds: [])
            } ?? ""
            selectTcfStack(id: id, isSelected: current != toggleOn)
        }
    }
    func toggleSirdataStack(id: Int32) {
        applyImmediately {
            let current = store.sirdataList.getStack(id: id).map {
                selector.getStackState(purposeIds: $0.purposes, specialFeatureIds: $0.specialFeatures, sirdataPurposeIds: $0.extraPurposes)
            } ?? ""
            selectSirdataStack(id: id, isSelected: current != toggleOn)
        }
    }

    // Vendors screen intent toggles — the target is computed from the LIVE
    // store/selector state, mirroring the purposes-screen toggles above and
    // Android's toggleVendor* contract. Never derived from a rendered value.
    func toggleVendor(id: Int32) {
        applyImmediately {
            let unlinked = isUnlinkedRow("tcf_\(id)")
            let current = store.vendorList.vendors.first { $0.id == id }
                .map { selector.getVendorState(vendor: $0, unlinked: unlinked) } ?? ""
            selectVendor(id: id, isSelected: current != toggleOn, unlinked: unlinked)
        }
    }
    func toggleVendorConsent(id: Int32) {
        applyImmediately {
            let current = store.consentData.coreData.selectedVendorIds.contains(KotlinInt(int: id))
            selectVendorConsent(id: id, isSelected: !current)
        }
    }
    func toggleVendorLI(id: Int32) {
        applyImmediately {
            let current = store.consentData.coreData.selectedVendorLIIds.contains(KotlinInt(int: id))
            selectVendorLI(id: id, isSelected: !current)
        }
    }
    func toggleSirdataVendor(id: Int32) {
        applyImmediately {
            let unlinked = isUnlinkedRow("sd_\(id)")
            let current = store.sirdataList.vendors.first { $0.id == id }
                .map { selector.getSirdataVendorState(vendor: $0, unlinked: unlinked) } ?? ""
            selectSirdataVendor(id: id, isSelected: current != toggleOn, unlinked: unlinked)
        }
    }
    func toggleSirdataVendorConsent(id: Int32) {
        applyImmediately {
            let current = store.consentData.customData.selectedSirdataVendorIds.contains(KotlinInt(int: id))
            selectSirdataVendorConsent(id: id, isSelected: !current)
        }
    }
    func toggleSirdataVendorLI(id: Int32) {
        applyImmediately {
            let current = store.consentData.customData.selectedSirdataVendorLIIds.contains(KotlinInt(int: id))
            selectSirdataVendorLI(id: id, isSelected: !current)
        }
    }
    func toggleACProvider(id: Int32) {
        applyImmediately {
            let unlinked = isUnlinkedRow("gp_\(id)")
            let current = store.googleProviderList.providers.first { $0.id == id }
                .map { selector.getACProviderState(provider: $0, unlinked: unlinked) } ?? ""
            selectACProvider(id: id, isSelected: current != toggleOn, unlinked: unlinked)
        }
    }

    // MARK: - Intent Funnel

    /// Single entry point for every row/toggle interaction on the consent
    /// screens. Views never carry closures or compute targets — they emit a
    /// `ConsentIntent` and this method resolves it against the live state.
    func send(_ intent: ConsentIntent) {
        switch intent {
        case .togglePurpose(let id): togglePurpose(id: id)
        case .togglePurposeConsent(let id): togglePurposeConsent(id: id)
        case .togglePurposeLI(let id): togglePurposeLI(id: id)
        case .toggleSirdataPurpose(let id): toggleSirdataPurpose(id: id)
        case .toggleSirdataPurposeConsent(let id): toggleSirdataPurposeConsent(id: id)
        case .toggleSirdataPurposeLI(let id): toggleSirdataPurposeLI(id: id)
        case .toggleSpecialFeature(let id): toggleSpecialFeature(id: id)
        case .toggleTcfStack(let id): toggleTcfStack(id: id)
        case .toggleSirdataStack(let id): toggleSirdataStack(id: id)
        case .toggleStandardPurpose(let id): toggleStandardPurpose(id: id)
        case .toggleCustomPurpose(let id): toggleCustomPurpose(id: id)
        case .selectPurpose(let id, let isSelected): applyImmediately { selectPurpose(id: id, isSelected: isSelected) }
        case .toggleVendor(let id): toggleVendor(id: id)
        case .toggleVendorConsent(let id): toggleVendorConsent(id: id)
        case .toggleVendorLI(let id): toggleVendorLI(id: id)
        case .toggleSirdataVendor(let id): toggleSirdataVendor(id: id)
        case .toggleSirdataVendorConsent(let id): toggleSirdataVendorConsent(id: id)
        case .toggleSirdataVendorLI(let id): toggleSirdataVendorLI(id: id)
        case .toggleACProvider(let id): toggleACProvider(id: id)
        case .toggleExpand(let key): toggleExpand(key)
        }
    }

    /// Toggles a row/zone's expanded state. Collapsing a row also collapses
    /// every nested zone whose key is prefixed by it (same behavior as the
    /// previous view-local implementation). Mutating `uiState` publishes the
    /// change; `refreshUiState()` carries `expandedIds` over, so expansion is
    /// never lost on consent changes.
    private func toggleExpand(_ id: String) {
        if uiState.expandedIds.contains(id) {
            uiState.expandedIds = uiState.expandedIds.filter { !$0.hasPrefix("\(id)_") && $0 != id }
        } else {
            uiState.expandedIds.insert(id)
        }
    }

    // MARK: - Partner Entries (Vendors screen STRUCTURE — built on entry)

    /// Builds the partners list STRUCTURE for VendorsView: names, sections,
    /// purposes, links, intents and state KEYS — never state values. Live
    /// toggle/acceptance values are looked up in `toggles` by the views.
    /// Pure Swift over the load-time snapshot.
    /// FRONT-1276 — which partners the apply screen shows, and how. Port of
    /// `buildPartnerRows(store, {missingOnly: true})` (`partnerRows.js`, web).
    ///
    /// Decided when the screen is entered, and frozen there — a structure rebuild never
    /// happens on a tap, so this is naturally stable. That matters twice, both paid on the
    /// web: re-answering "is anything left to decide?" after a click made the row VANISH the
    /// instant its toggle went to accepted, and a click on a fused row passes through states
    /// where the pair looks divergent, which would split the partner into a second row.
    struct ApplyRowPlan {
        var visibleKeys: Set<String> = []
        /// Rows presented ON THEIR OWN: no fused section, no linked aggregation, no propagation.
        var unlinkedKeys: Set<String> = []
        /// Linked Sirdata partners promoted to a row of their own because their carrier answered.
        var promotedSirdataIds: Set<Int> = []
        var isActive = false
    }

    private var applyRowPlan = ApplyRowPlan()

    func isUnlinkedRow(_ key: String) -> Bool { applyRowPlan.unlinkedKeys.contains(key) }

    private func computeApplyRowPlan(snap: ConsentSnapshot) -> ApplyRowPlan {
        let sel = SelectedSets.bridge(consentData: store.consentData)
        var plan = ApplyRowPlan()
        plan.isActive = true

        // A Sirdata partner still owes an answer. Extra (Sirdata-specific) purposes count as
        // much as standard TCF ones: a partner fused into a TCF or Google row usually declares
        // nothing BUT extras.
        func sirdataMissing(_ sv: SnapSirdataVendor) -> Bool {
            let consentMissing = (!sv.purposes.isEmpty || !sv.extraPurposes.isEmpty)
                && !sel.sirdataVendorIds.contains(sv.id)
            let liMissing = (!sv.legIntPurposes.isEmpty || !sv.legIntExtraPurposes.isEmpty)
                && !sel.sirdataVendorLIIds.contains(sv.id)
            return consentMissing || liMissing
        }

        // Arbitré par le mainteneur : quand deux partenaires liés portent des réponses
        // DIFFÉRENTES, on les délie le temps de présenter le choix. Chacun apparaît alors
        // seul, avec SON état — jamais les deux, leurs toggles principaux se propageant l'un
        // à l'autre.
        //
        //   porteur sans réponse, lié sans réponse  -> le porteur, fusionné
        //   porteur sans réponse, lié AYANT répondu -> le porteur seul, délié
        //   porteur AYANT répondu, lié sans réponse -> le lié seul, délié
        //   les deux ont répondu                    -> rien
        func keepCarrier(_ key: String, _ linked: SnapSirdataVendor?) {
            plan.visibleKeys.insert(key)
            if let linked, !sirdataMissing(linked) { plan.unlinkedKeys.insert(key) }
        }
        func promoteLinked(_ linked: SnapSirdataVendor?) {
            guard let linked, sirdataMissing(linked) else { return }
            plan.promotedSirdataIds.insert(linked.id)
            plan.visibleKeys.insert("sd_\(linked.id)")
            plan.unlinkedKeys.insert("sd_\(linked.id)")
        }

        // Same three groupings as the screen, in the same order — a Sirdata partner carrying
        // both links belongs to the TCF row, which HIDES the Google provider. Walking the
        // hidden provider anyway would promote a partner already fused into a visible row.
        var linkedByTcf: [Int: SnapSirdataVendor] = [:]
        var linkedByGoogle: [Int: SnapSirdataVendor] = [:]
        var hiddenProviderIds = Set<Int>()
        // FRONT-1317 — « lié à un porteur VISIBLE », donc décidable. Restreint AVANT les index
        // de liaison : un partenaire Sirdata rattaché à un porteur écarté ne doit pas être
        // emporté avec lui, il retombe sur sa liaison Google ou sur une ligne autonome. Même
        // ordre que le bundle web et que le jumeau Android.
        let tcfIds = Set(snap.vendors.filter { $0.hasDecidableChannel }.map { $0.id })
        let providerIds = Set(snap.googleProviders.map { $0.id })
        for sv in snap.sirdataVendors {
            if let tcfId = sv.tcfVendorId, tcfIds.contains(tcfId) {
                linkedByTcf[tcfId] = sv
                if let gpId = sv.googleProviderId { hiddenProviderIds.insert(gpId) }
            } else if let gpId = sv.googleProviderId, providerIds.contains(gpId) {
                linkedByGoogle[gpId] = sv
            }
        }

        for vendor in snap.vendors {
            // Special features count on the consent channel — a DELIBERATE divergence from the
            // web filter, see the Android twin (`computeApplyRows`) for the full reasoning: the
            // web contradicts itself there, and a vendor declaring only special features had
            // its consent recorded by "Accept" without ever being presented.
            //
            // FRONT-1317 — ce raisonnement supposait tacitement la fonctionnalité spéciale
            // AFFICHÉE. Le test portait sur la déclaration brute, donc dès que
            // `disabledSpecialFeatures` la retirait de l'écran, ce code produisait le défaut
            // même qu'il fermait. Les deux drapeaux ci-dessous portent l'intersection avec les
            // listes affichées — ils sont l'exacte éligibilité que `ConsentSelector` applique.
            let consentMissing = vendor.combinedConsentEligible && !sel.vendorIds.contains(vendor.id)
            let missing = consentMissing
                || (vendor.combinedLIEligible && !sel.vendorLIIds.contains(vendor.id))
            let linked = linkedByTcf[vendor.id]
            if missing { keepCarrier("tcf_\(vendor.id)", linked) } else { promoteLinked(linked) }
        }
        for provider in snap.googleProviders where !hiddenProviderIds.contains(provider.id) {
            let linked = linkedByGoogle[provider.id]
            if !sel.providerIds.contains(provider.id) {
                keepCarrier("gp_\(provider.id)", linked)
            } else {
                promoteLinked(linked)
            }
        }
        let linkedIds = Set(linkedByTcf.values.map { $0.id }).union(linkedByGoogle.values.map { $0.id })
        for sv in snap.sirdataVendors where !linkedIds.contains(sv.id) {
            if sirdataMissing(sv) { plan.visibleKeys.insert("sd_\(sv.id)") }
        }

        return plan
    }

    private func buildPartnerEntries(sd: ConsentStaticData, isVendorsMissing: Bool) -> [PartnerEntryData] {
        let snap = sd.snap
        applyRowPlan = isVendorsMissing ? computeApplyRowPlan(snap: snap) : ApplyRowPlan()
        let plan = applyRowPlan
        let consentLabel = localize.getText(key: LocaleKey.vendorsConsent.key)
        let liLabel = localize.getText(key: LocaleKey.vendorsLi.key)
        let spAndFeaturesLabel = localize.getText(key: LocaleKey.vendorsSpecialPurposesAndFeatures.key)
        let dataCategoriesLabel = localize.getText(key: LocaleKey.vendorsDataCategories.key)
        let nonTcfConsentLabel = localize.getText(key: LocaleKey.vendorsNonTcfConsent.key)
        let nonTcfLiLabel = localize.getText(key: LocaleKey.vendorsNonTcfLi.key)
        let legIntClaimLabelText = localize.getText(key: LocaleKey.vendorsLiClaim.key)
        // Retention / storage templates — fetched ONCE, formatted in Swift.
        let retentionSessionText = localize.getText(key: LocaleKey.dataRetentionSession.key)
        let retentionDayText = localize.getText(key: LocaleKey.dataRetentionDay.key)
        let retentionDaysTemplate = localize.getText(key: LocaleKey.dataRetentionDayPlural.key)
        let storageLabel = localize.getText(key: LocaleKey.vendorsStorage.key)
        let cookieMaxAgeTemplate = localize.getText(key: LocaleKey.vendorsCookieMaxAgeSeconds.key)
        let cookieSessionText = localize.getText(key: LocaleKey.vendorsCookieSession.key)
        let cookieRefreshText = localize.getText(key: LocaleKey.storageCookieRefresh.key)
        let nonCookieAccessText = localize.getText(key: LocaleKey.vendorsUsesNonCookieAccess.key)
        let andSeparator = " " + localize.getText(key: "and") + " "

        func tcfPurposeName(_ id: Int) -> String? {
            sd.tcfPurposeNameMap[id] ?? snap.purposeById[id]?.name
        }
        func sirdataPurposeName(_ id: Int) -> String? {
            sd.sirdataPurposeNameMap[id] ?? snap.sirdataPurposeById[id]?.name
        }
        func tcfPurposeDescription(_ id: Int) -> String {
            snap.purposeById[id]?.descriptionRaw ?? ""
        }
        func sirdataPurposeDescription(_ id: Int) -> String {
            snap.sirdataPurposeById[id]?.descriptionRaw ?? ""
        }
        func formatRetention(_ days: Int) -> String? {
            if days == 0 { return retentionSessionText }
            if days == 1 { return retentionDayText }
            return retentionDaysTemplate.replacingOccurrences(of: "<count/>", with: "\(days)")
        }
        func buildStorageDisclosure(_ vendor: SnapTcfVendor) -> VendorStorageDisclosure? {
            if !vendor.usesCookies && vendor.cookieMaxAgeSeconds <= 0 && !vendor.usesNonCookieAccess { return nil }
            var parts: [String] = []
            if vendor.usesCookies || vendor.cookieMaxAgeSeconds > 0 {
                if vendor.cookieMaxAgeSeconds > 0 {
                    let duration = getDurationFromSeconds(vendor.cookieMaxAgeSeconds)
                    parts.append(cookieMaxAgeTemplate.replacingOccurrences(of: "<duration/>", with: duration))
                } else {
                    parts.append(cookieSessionText)
                }
                if vendor.cookieRefresh {
                    parts[parts.count - 1] = parts.last! + " " + cookieRefreshText
                }
            }
            if vendor.usesNonCookieAccess {
                parts.append(nonCookieAccessText)
            }
            let description = parts.joined(separator: andSeparator) + "."
            return VendorStorageDisclosure(label: storageLabel, description: description,
                                           url: vendor.deviceStorageDisclosureUrl)
        }

        // FRONT-1261: Sirdata vendors linked to a visible TCF/Google parent are
        // fused into that parent's nonTc sections and hidden from the standalone list.
        var linkedSirdataIds = Set<Int>()
        for v in snap.vendors { if let linked = v.linkedSirdata { linkedSirdataIds.insert(linked.id) } }
        for p in snap.googleProviders { if let linked = p.linkedSirdata { linkedSirdataIds.insert(linked.id) } }

        // T-V09 (GAP-V12): Hide Google providers linked to Sirdata vendors
        // that are linked to active TCF vendors.
        let hiddenGoogleProviderIds = Set(snap.sirdataVendors.compactMap { sv -> Int? in
            guard sv.linkedTcfExists, let gpId = sv.googleProviderId else { return nil }
            return gpId
        })

        // ─── TCF partners ──────────────────────────────────────────────────
        // FRONT-1317 — un partenaire à qui l'écran ne peut rien demander n'est pas affiché.
        let tcfPartners: [PartnerEntryData] = snap.vendors.filter { $0.hasDecidableChannel }.map { vendor in
            let id = vendor.id
            let partnerId = "tcf_\(id)"
            // Web parity (IabTcfVendor.jsx): the consent block lists the vendor's
            // purposes AND its SPECIAL FEATURES — two opt-in channels of the same
            // block. Only the purposes were listed, so a special feature never
            // showed up on a partner row, and a vendor declaring special features
            // but no consent purpose got an empty block (`hasConsentChannel`
            // already counted them). Special features are walked in DISPLAY-list
            // order, like the web, since the vendor holds them as a set.
            // (split in two lets: a single chained expression is the classic way to
            // hit "unable to type-check this expression in reasonable time")
            // FRONT-1276: the status key is scoped to THIS partner's channel — the same
            // purpose reads « accepté » under a partner that granted it and « non accepté »
            // under one that did not.
            let consentOwner = ToggleKey.partnerSection(partnerId, "consent")
            let liOwner = ToggleKey.partnerSection(partnerId, "li")
            let purposeItems: [VendorPurposeItem] = vendor.filteredPurposesList.compactMap { pid in
                tcfPurposeName(pid).map {
                    VendorPurposeItem(
                        name: $0,
                        statusKey: ToggleKey.owned(ToggleKey.tcfPurposeStatus(pid), consentOwner),
                        description: tcfPurposeDescription(pid),
                        retention: vendor.retentionPurposes[pid].flatMap { formatRetention($0) }
                    )
                }
            }
            let specialFeatureItems: [VendorPurposeItem] = snap.specialFeatures
                .filter { vendor.specialFeatures.contains($0.id) }
                .map { sf in
                    VendorPurposeItem(
                        name: sf.name,
                        statusKey: ToggleKey.owned(ToggleKey.specialFeatureStatus(sf.id), consentOwner),
                        description: sf.descriptionRaw
                    )
                }
            let consentItems: [VendorPurposeItem] = purposeItems + specialFeatureItems
            let consent: VendorPurposeSectionData? = consentItems.isEmpty
                ? nil
                : VendorPurposeSectionData(
                    label: consentLabel,
                    stateKey: ToggleKey.partnerSection(partnerId, "consent"),
                    purposes: consentItems,
                    // Web parity: the per-channel toggle only exists when the vendor
                    // also has an LI channel to separate it from — the row toggle
                    // already covers a consent-only vendor.
                    showToggle: vendor.hasLIChannel && !isVendorsMissing,
                    toggleIntent: .toggleVendorConsent(Int32(id)))
            let li: VendorPurposeSectionData? = vendor.hasLIChannel
                ? VendorPurposeSectionData(
                    label: liLabel,
                    stateKey: ToggleKey.partnerSection(partnerId, "li"),
                    purposes: vendor.filteredLegIntPurposesList.compactMap { pid in
                        tcfPurposeName(pid).map {
                            VendorPurposeItem(
                                name: $0,
                                statusKey: ToggleKey.owned(ToggleKey.tcfPurposeStatusLI(pid), liOwner),
                                description: tcfPurposeDescription(pid),
                                retention: vendor.retentionPurposes[pid].flatMap { formatRetention($0) }
                            )
                        }
                    },
                    // Web parity (IabTcfVendor.jsx) : ce toggle est conditionné aux
                    // seules FINALITÉS de consentement du vendor —
                    // `purposes.find(({id}) => purposeList.indexOf(id) > -1)`, sans
                    // `specialFeatureList`. `hasConsentChannel` compte les special
                    // features, ce que le web ne fait délibérément pas ici : un vendor
                    // à special features sans finalité de consentement affiche donc son
                    // bloc consentement (cette visibilité-là les compte bien) mais pas
                    // de sous-toggle LI. Asymétrie voulue côté web, Android identique.
                    showToggle: !purposeItems.isEmpty && !isVendorsMissing,
                    toggleIntent: .toggleVendorLI(Int32(id)))
                : nil
            // FRONT-1261: non-TCF consent + LI sections from the linked Sirdata vendor.
            // FRONT-1276: none of them when the apply screen presents this row on its own.
            let linkedSv = plan.unlinkedKeys.contains(partnerId)
                ? nil
                : snap.sirdataVendors.first { $0.tcfVendorId == id }
            let nonTcConsent: VendorPurposeSectionData? = linkedSv.flatMap { sv in
                // FRONT-1276: the fused partner exposes its STANDARD purposes as well as its
                // extra ones — exactly what its standalone row renders. Listing only the extras
                // made a partner declaring nothing but standard purposes vanish from the
                // screen, its own row having been removed by FRONT-1261.
                let owner = ToggleKey.partnerSection(partnerId, "nonTcConsent")
                let purposes = sv.purposesList.compactMap { pid in
                    tcfPurposeName(pid).map {
                        VendorPurposeItem(name: $0,
                                          statusKey: ToggleKey.owned(ToggleKey.tcfPurposeStatus(pid), owner),
                                          description: tcfPurposeDescription(pid))
                    }
                } + sv.extraPurposesList.compactMap { pid in
                    sirdataPurposeName(pid).map {
                        VendorPurposeItem(name: $0,
                                          statusKey: ToggleKey.owned(ToggleKey.sirdataPurposeStatus(pid), owner),
                                          description: sirdataPurposeDescription(pid))
                    }
                }
                guard !purposes.isEmpty else { return nil }
                return VendorPurposeSectionData(
                    label: nonTcfConsentLabel,
                    stateKey: ToggleKey.partnerSection(partnerId, "nonTcConsent"),
                    purposes: purposes,
                    vendorName: sv.name,
                    vendorPolicyUrl: sv.policyUrl ?? "",
                    toggleIntent: .toggleSirdataVendorConsent(Int32(sv.id)))
            }
            let nonTcLI: VendorPurposeSectionData? = linkedSv.flatMap { sv in
                // FRONT-1276: standard purposes belong here too, see the consent section.
                let owner = ToggleKey.partnerSection(partnerId, "nonTcLI")
                let purposes = sv.legIntPurposesList.compactMap { pid in
                    tcfPurposeName(pid).map {
                        VendorPurposeItem(name: $0,
                                          statusKey: ToggleKey.owned(ToggleKey.tcfPurposeStatusLI(pid), owner),
                                          description: tcfPurposeDescription(pid))
                    }
                } + sv.legIntExtraPurposesList.compactMap { pid in
                    sirdataPurposeName(pid).map {
                        VendorPurposeItem(name: $0,
                                          statusKey: ToggleKey.owned(ToggleKey.sirdataPurposeStatusLI(pid), owner),
                                          description: sirdataPurposeDescription(pid))
                    }
                }
                guard !purposes.isEmpty else { return nil }
                return VendorPurposeSectionData(
                    label: nonTcfLiLabel,
                    stateKey: ToggleKey.partnerSection(partnerId, "nonTcLI"),
                    purposes: purposes,
                    vendorName: sv.name,
                    vendorPolicyUrl: sv.policyUrl ?? "",
                    toggleIntent: .toggleSirdataVendorLI(Int32(sv.id)))
            }
            // T-V03: Special Purposes & Features + Data Categories read-only sections
            // Descriptions included: each line renders as the same expandable web
            // `VendorPurpose` as a consent purpose. Each list is looked up in ITS
            // OWN type list — a special purpose 1, a feature 1 and a special
            // feature 1 coexist and are unrelated (cf. CLAUDE.md).
            let spAndFeatures: VendorInfoSection? = {
                var items: [VendorInfoItem] = []
                for spId in vendor.specialPurposes {
                    if let sp = snap.specialPurposes.first(where: { $0.id == spId }) {
                        items.append(VendorInfoItem(
                            name: sp.name,
                            description: sp.descriptionRaw,
                            retention: vendor.retentionSpecialPurposes[spId].flatMap { formatRetention($0) }))
                    }
                }
                for fId in vendor.features {
                    if let f = snap.features.first(where: { $0.id == fId }) {
                        items.append(VendorInfoItem(name: f.name, description: f.descriptionRaw))
                    }
                }
                return items.isEmpty ? nil : VendorInfoSection(label: spAndFeaturesLabel, items: items)
            }()
            let dataCategories: VendorInfoSection? = {
                let items = vendor.dataDeclaration.compactMap { dcId -> VendorInfoItem? in
                    sd.tcfDataCategoryNameMap[dcId].map {
                        VendorInfoItem(name: $0, description: sd.tcfDataCategoryDescriptionMap[dcId] ?? "")
                    }
                }
                return items.isEmpty ? nil : VendorInfoSection(label: dataCategoriesLabel, items: items)
            }()
            return PartnerEntryData(
                id: partnerId, name: vendor.name, policyUrl: vendor.policyUrl ?? "", isIabTcf: true,
                consentSection: consent, liSection: li, nonTcConsentSection: nonTcConsent, nonTcLISection: nonTcLI,
                specialPurposesSection: spAndFeatures, dataCategoriesSection: dataCategories,
                storageDisclosure: buildStorageDisclosure(vendor),
                spOnly: vendor.spOnly,
                legIntClaimUrl: vendor.legIntClaim,
                legIntClaimLabel: legIntClaimLabelText,
                combinedIntent: .toggleVendor(Int32(id))
            )
        }

        // ─── Sirdata partners ───────────────────────────────────────────────
        let sirdataPartners: [PartnerEntryData] = snap.sirdataVendors
            .filter { !linkedSirdataIds.contains($0.id) || plan.promotedSirdataIds.contains($0.id) }
            .map { vendor in
                let id = vendor.id
                let partnerId = "sd_\(id)"
                let consentOwner = ToggleKey.partnerSection(partnerId, "consent")
                let liOwner = ToggleKey.partnerSection(partnerId, "li")
                let consent: VendorPurposeSectionData? = vendor.hasConsentChannel
                    ? VendorPurposeSectionData(
                        label: consentLabel,
                        stateKey: consentOwner,
                        purposes: vendor.purposesList.compactMap { pid in
                            tcfPurposeName(pid).map {
                                VendorPurposeItem(name: $0,
                                                  statusKey: ToggleKey.owned(ToggleKey.tcfPurposeStatus(pid), consentOwner))
                            }
                        } + vendor.extraPurposesList.compactMap { pid in
                            sirdataPurposeName(pid).map {
                                VendorPurposeItem(name: $0,
                                                  statusKey: ToggleKey.owned(ToggleKey.sirdataPurposeStatus(pid), consentOwner))
                            }
                        },
                        // Web parity (SirdataVendor.jsx): mirror of the LI rule below —
                        // a per-channel toggle only when the other channel exists too.
                        showToggle: vendor.hasLIChannel && !isVendorsMissing,
                        toggleIntent: .toggleSirdataVendorConsent(Int32(id)))
                    : nil
                let li: VendorPurposeSectionData? = vendor.hasLIChannel
                    ? VendorPurposeSectionData(
                        label: liLabel,
                        stateKey: liOwner,
                        purposes: vendor.legIntPurposesList.compactMap { pid in
                            tcfPurposeName(pid).map {
                                VendorPurposeItem(name: $0,
                                                  statusKey: ToggleKey.owned(ToggleKey.tcfPurposeStatusLI(pid), liOwner))
                            }
                        } + vendor.legIntExtraPurposesList.compactMap { pid in
                            sirdataPurposeName(pid).map {
                                VendorPurposeItem(name: $0,
                                                  statusKey: ToggleKey.owned(ToggleKey.sirdataPurposeStatusLI(pid), liOwner))
                            }
                        },
                        showToggle: vendor.hasConsentChannel && !isVendorsMissing,
                        toggleIntent: .toggleSirdataVendorLI(Int32(id)))
                    : nil
                return PartnerEntryData(
                    id: partnerId, name: vendor.name, policyUrl: vendor.policyUrl ?? "", isIabTcf: false,
                    consentSection: consent, liSection: li, nonTcConsentSection: nil, nonTcLISection: nil,
                    specialPurposesSection: nil, dataCategoriesSection: nil, storageDisclosure: nil,
                    combinedIntent: .toggleSirdataVendor(Int32(id))
                )
            }

        // ─── Google AC partners ─────────────────────────────────────────────
        let googlePartners: [PartnerEntryData] = snap.googleProviders
            .filter { !hiddenGoogleProviderIds.contains($0.id) }
            .map { provider in
                let id = provider.id
                let partnerId = "gp_\(id)"
                let consentOwner = ToggleKey.partnerSection(partnerId, "consent")
                let consent: VendorPurposeSectionData? = {
                    let purposes = sd.googlePurposes.compactMap { pid in
                        tcfPurposeName(pid).map {
                            VendorPurposeItem(name: $0,
                                              statusKey: ToggleKey.owned(ToggleKey.tcfPurposeStatus(pid), consentOwner))
                        }
                    }
                    guard !purposes.isEmpty else { return nil }
                    return VendorPurposeSectionData(
                        label: consentLabel,
                        stateKey: consentOwner,
                        purposes: purposes,
                        showToggle: false)
                }()
                // FRONT-1261: non-TCF sections from the linked Sirdata vendor.
                // FRONT-1276: none of them when this row is presented on its own.
                let linkedSv = plan.unlinkedKeys.contains(partnerId)
                    ? nil
                    : snap.sirdataVendors.first { $0.googleProviderId == id }
                let nonTcConsent: VendorPurposeSectionData? = linkedSv.flatMap { sv in
                    // FRONT-1276: standard purposes belong here too, see the TCF row.
                    let owner = ToggleKey.partnerSection(partnerId, "nonTcConsent")
                    let purposes = sv.purposesList.compactMap { pid in
                        tcfPurposeName(pid).map {
                            VendorPurposeItem(name: $0,
                                              statusKey: ToggleKey.owned(ToggleKey.tcfPurposeStatus(pid), owner))
                        }
                    } + sv.extraPurposesList.compactMap { pid in
                        sirdataPurposeName(pid).map {
                            VendorPurposeItem(name: $0,
                                              statusKey: ToggleKey.owned(ToggleKey.sirdataPurposeStatus(pid), owner))
                        }
                    }
                    guard !purposes.isEmpty else { return nil }
                    return VendorPurposeSectionData(
                        label: nonTcfConsentLabel,
                        stateKey: ToggleKey.partnerSection(partnerId, "nonTcConsent"),
                        purposes: purposes,
                        vendorName: sv.name,
                        vendorPolicyUrl: sv.policyUrl ?? "",
                        toggleIntent: .toggleSirdataVendorConsent(Int32(sv.id)))
                }
                let nonTcLI: VendorPurposeSectionData? = linkedSv.flatMap { sv in
                    // FRONT-1276: standard purposes belong here too, see the TCF row.
                    let owner = ToggleKey.partnerSection(partnerId, "nonTcLI")
                    let purposes = sv.legIntPurposesList.compactMap { pid in
                        tcfPurposeName(pid).map {
                            VendorPurposeItem(name: $0,
                                              statusKey: ToggleKey.owned(ToggleKey.tcfPurposeStatusLI(pid), owner))
                        }
                    } + sv.legIntExtraPurposesList.compactMap { pid in
                        sirdataPurposeName(pid).map {
                            VendorPurposeItem(name: $0,
                                              statusKey: ToggleKey.owned(ToggleKey.sirdataPurposeStatusLI(pid), owner))
                        }
                    }
                    guard !purposes.isEmpty else { return nil }
                    return VendorPurposeSectionData(
                        label: nonTcfLiLabel,
                        stateKey: ToggleKey.partnerSection(partnerId, "nonTcLI"),
                        purposes: purposes,
                        vendorName: sv.name,
                        vendorPolicyUrl: sv.policyUrl ?? "",
                        toggleIntent: .toggleSirdataVendorLI(Int32(sv.id)))
                }
                return PartnerEntryData(
                    id: partnerId, name: provider.name, policyUrl: provider.policyUrl ?? "", isIabTcf: false,
                    consentSection: consent, liSection: nil, nonTcConsentSection: nonTcConsent, nonTcLISection: nonTcLI,
                    specialPurposesSection: nil, dataCategoriesSection: nil, storageDisclosure: nil,
                    combinedIntent: .toggleACProvider(Int32(id))
                )
            }

        // ─── Custom vendor partners ─────────────────────────────────────────
        let customVendorPartners: [PartnerEntryData] = snap.customPurposes
            .filter { ($0.vendorName?.isEmpty ?? true) == false }
            .map { cp in
                let partnerId = "custom_\(cp.id)"
                let purposeItem = VendorPurposeItem(
                    name: cp.name,
                    statusKey: ToggleKey.customPurpose(Int(cp.id)),
                    description: cp.descriptionRaw
                )
                let section = VendorPurposeSectionData(
                    label: cp.isLI ? liLabel : consentLabel,
                    stateKey: ToggleKey.partnerSection(partnerId, "main"),
                    purposes: [purposeItem],
                    showToggle: false
                )
                return PartnerEntryData(
                    id: partnerId,
                    name: cp.vendorName ?? "",
                    policyUrl: cp.vendorPolicyUrl ?? "",
                    isIabTcf: false,
                    consentSection: cp.isLI ? nil : section,
                    liSection: cp.isLI ? section : nil,
                    nonTcConsentSection: nil,
                    nonTcLISection: nil,
                    specialPurposesSection: nil,
                    dataCategoriesSection: nil,
                    storageDisclosure: nil,
                    combinedIntent: .toggleCustomPurpose(cp.id)
                )
            }

        let allPartners = tcfPartners + sirdataPartners + googlePartners + customVendorPartners
        guard plan.isActive else { return allPartners }
        // FRONT-1276: the apply screen lists what the plan decided. Custom publisher vendors
        // are never filtered out, on either screen (web parity: Vendors.jsx renders them
        // outside the filtered list).
        return allPartners.filter { $0.id.hasPrefix("custom_") || plan.visibleKeys.contains($0.id) }
    }

    // MARK: - Consent Submission

    func getActionResponse() -> UserActionResponse {
        selector.getActionResponse()
    }

    func submitConsent(action: UserActionResponse) async {
        // FRONT-1284 — the write path stamps the workflow decade onto `consentScreen`
        // (`ConsentScreenValue`), and the workflow lives in `uiState`. Set here, at the
        // single exit towards `shared/`, rather than at the three places it changes:
        // one piece of information, one synchronisation point.
        cmp.workflow = uiState.workflow
        // Clear any previous error so the user gets fresh feedback on retry.
        uiState.error = nil
        do {
            // Kotlin suspend functions are exported as throwing async functions.
            // ConsentResult is a Kotlin sealed class: nested types are exported
            // as ConsentResult.Success / ConsentResult.Error in Swift, and
            // Swift pattern matching does not apply — use `as?` casts.
            let result = try await IosCMPManager.shared.submitConsent(userAction: action)
            if let success = result as? ConsentResult.Success {
                uiState.tcString = success.consentData.tcString
                uiState.isLoading = false
            } else if let error = result as? ConsentResult.Error {
                uiState.error = error.message
                uiState.isLoading = false
            }
        } catch {
            uiState.error = error.localizedDescription
            uiState.isLoading = false
        }
    }

    /// GAP-CW-01/02/03/05: PurposeOne accept — saves consent with ACCEPT action,
    /// sets consentScreen to PURPOSE_ONE, updates lastPrompt,
    /// and navigates to PURPOSES screen without finishing.
    /// Web parity: PurposeOne.jsx handleAccept.
    func submitPurposeOneConsent() {
        // GAP-CW-01: Set consentScreen to PURPOSE_ONE before persisting
        store.consentData.coreData.consentScreen = ConsentScreen.purposeOne.value
        // GAP-CW-02: Update lastPrompt (equivalent to web storage.updateLastPrompt()).
        // FRONT-1280: this used to write askLaterTimestamp, which carried both web
        // notions (`lp` and `al`) in one field. Accepting purpose 1 is not a report.
        IosCMPApi.shared.recordPrompt()
        // GAP-CW-03: Use ACCEPT action (not SAVE) — user is accepting cookies (purpose 1)
        Task {
            await submitConsent(action: UserActionResponse.accept)
        }
        // GAP-CW-05: Navigate to Purposes screen without finishing (web parity: togglePurposesShowing(true))
        navigateTo(screen: .purposes)
    }

    /// GAP-B07: Set consentScreen before saving consent from the Main banner
    /// (web parity: Main.jsx handleAccept/handleReject/handleContinue all set
    /// consentScreen = ConsentScreen.MAIN before calling onSave).
    ///
    /// FRONT-1284 — an **accept** in the "apply choices" workflow records MAIN_MISSING
    /// instead, as `MainApply.jsx:36` does. The test is on the workflow, not the screen:
    /// MAIN_MISSING is never the current screen on mobile — the apply mode renders the
    /// MAIN screen with `workflow == .applyChoices`, just as the web renders `MainApply`
    /// under that workflow.
    ///
    /// The workflow *decade* is not added here: it belongs to the shared write path
    /// (`ConsentScreenValue`, called from `submitConsent`), so that the rule has one home
    /// for both platforms.
    func setConsentScreenForSave(isAccept: Bool = false) {
        let recorded: ConsentScreen =
            (isAccept && uiState.workflow == .applyChoices) ? .mainMissing : .main
        store.consentData.coreData.consentScreen = recorded.value
    }

    /// Records the "Ask me later" timestamp and signals the banner to dismiss.
    ///
    /// FRONT-1280: goes through the shared manager, which persists the timestamp.
    /// Written to memory only, the report was lost at the next launch — which is
    /// exactly when it is read, so it had no effect at all.
    func askLater() {
        IosCMPApi.shared.recordAskLater()
        store.notifyUpdate()
        shouldDismiss = true
    }

    /// Adopts the workflow the cascade decided, if nobody asked for one explicitly.
    ///
    /// Codex (P1): a host presenting the banner at startup may present it before the
    /// asynchronous config has arrived. The decision then rests on the first two rules
    /// only and yields `.main`, freezing the standard banner where the loaded config
    /// would have selected the cookiewall or the "apply choices" mode.
    ///
    /// An explicitly requested workflow is never replaced, `.main` included: Codex
    /// (P2) noted that using an enum value as the "absent" sentinel would betray the
    /// promise of `ConsentView(workflow:)`. Hence the flag rather than a value test.
    /// Called before the first structure build, whose texts depend on the workflow.
    ///
    /// **Once only, and that matters** (Codex, P1). The state watcher fires on every
    /// transition out of `loading`, so also on the `persisting` / `complete` of a save.
    /// Without the latch, accepting purpose one from a cookiewall — which keeps the
    /// view open and navigates to the purposes screen — replayed the cascade: purpose
    /// one now granted and the prompt recorded, it returned `.main` and **erased** the
    /// `.cookiewallModify` the user had just triggered, sending them back to the
    /// standard banner with the wrong buttons.
    ///
    /// The cascade answers "what is left to ask?". An in-UI transition answers
    /// something else, and it wins — hence the latch also set by `setWorkflow`.
    private func adoptDecidedWorkflowIfUnset() {
        guard !workflowWasExplicit, !workflowSettled else { return }
        workflowSettled = true
        let decided = IosCMPApi.shared.getConsentDisplayDecision().workflow
        if decided != uiState.workflow {
            uiState.workflow = decided
        }
    }

    /// Records the manual-reopen prompt, once, when the banner actually appears.
    ///
    /// Called from `ConsentView.onAppear`. `.manualDisplay` never comes out of the
    /// cascade, so the test means exactly "the host asked for a manual re-open"; the
    /// latch keeps a re-appearance (backgrounding, a sheet re-presented) from
    /// restarting the window a second time.
    ///
    /// Also reports `load:revisit` (FRONT-1399), the Android twin of which lives in the
    /// view model's `init`. The latch is the RIGHT gate for it despite multi-emission
    /// being deliberate: `@StateObject` is created once per *presentation*, so a fresh
    /// view model — and a fresh hit — comes with every reopening the host asks for. What
    /// the latch suppresses is a re-appearance of the SAME instance, which is not a
    /// reopening the user requested.
    ///
    /// `try?` swallows only the cancellation the `postRevisitAction` suspension can
    /// throw; everything else is already caught by its own `runCatching`. The `Task`
    /// dies with the view, so it cannot carry a hit from a stale session — the shorter
    /// scope is what holds the FRONT-1284 invariant here.
    func recordManualPromptIfNeeded() {
        guard uiState.workflow == .manualDisplay, !didRecordManualPrompt else { return }
        didRecordManualPrompt = true
        IosCMPApi.shared.recordPrompt()
        Task {
            try? await cmp.postRevisitAction(workflow: uiState.workflow)
        }
    }

    /// Sets the workflow from an in-UI transition (cookiewall → cookiewall-modify) and
    /// settles it, so the decision cascade will not re-derive it afterwards.
    ///
    /// Deliberately does not rebuild: every call site navigates right after, and
    /// `navigateTo` rebuilds — matching the behaviour before this method existed.
    func setWorkflow(_ workflow: Workflow) {
        workflowSettled = true
        uiState.workflow = workflow
    }

    // MARK: - Reporting (familles `ui` et `ccpa_response`)

    /// Remonte un clic d'interface — FRONT-1402, jumeau de `ConsentViewModel.reportUiClick`
    /// côté Android. La règle vit dans `SirDataCMP.postUiClick`, seul endroit que `commonTest`
    /// puisse exercer ; ce fichier ne fait que la câbler.
    ///
    /// L'identité du bouton est PASSÉE, jamais déduite : elle est une propriété du site
    /// d'appel, comme sur le web où chaque gestionnaire émet son propre clic. Trois boutons
    /// partagent d'ailleurs le même geste métier — « Continuer sans accepter », « Enregistrer »
    /// et la croix sous variante CNIL passent tous par `save(_:)` dans `ConsentView` — donc rien
    /// dans l'état ne peut les séparer.
    ///
    /// `try?` n'avale que l'annulation que la suspension peut jeter ; tout le reste est déjà
    /// pris par le `runCatching` de la règle partagée, dont le `withTimeoutOrNull` borne
    /// l'attente. Même forme que `recordManualPromptIfNeeded`.
    func reportUiClick(_ action: UserActionUi) {
        Task { try? await cmp.postUiClick(action: action) }
    }

    /// Remonte une navigation, en capturant l'écran d'ORIGINE **synchronement**.
    ///
    /// C'est le seul piège de ce câblage : l'action dépend de l'origine (`purposes` depuis le
    /// bandeau, `see_purposes` depuis un écran de détail), et `navigateTo` écrase
    /// `currentScreen`. Lue dans la `Task`, l'origine serait donc déjà la CIBLE — toute
    /// navigation ressortirait en `see_*`, y compris depuis le bandeau. La lecture est faite
    /// ici, avant le `Task`, et `ConsentView.navigateReported` appelle cette fonction **avant**
    /// `navigateTo` : deux gardes pour un invariant qu'aucun test ne peut voir, `iosMain`
    /// n'étant pas visible de `commonTest`.
    ///
    /// Un retour au bandeau n'émet rien : le résolveur rend `nil` pour `MAIN` et
    /// `MAIN_MISSING`, donc les boutons « retour » traversent cette fonction sans produire de
    /// hit. C'est la parité web, où `Details.handleBack` n'émet rien non plus.
    func reportUiNavigation(to screen: ConsentScreen) {
        let from = uiState.currentScreen
        Task { try? await cmp.postUiNavigation(from: from, to: screen) }
    }

    /// Remonte `response:close` — la croix du bandeau qui ne persiste RIEN, FRONT-1480.
    ///
    /// Parité web : `Main.handleClose` (hors variante CNIL) émet `response:close` PUIS
    /// `ui:close`. Sans ce hit, chaque fermeture comptait un clic terminal sans réponse et
    /// faussait `PartnerStatDataQuality` de +1. Même chemin que l'Android
    /// (`ConsentActions.onCloseDismissing`).
    func reportCloseResponse() {
        Task { try? await cmp.postCloseResponse() }
    }

    /// Remonte la FERMETURE de l'écran US — `ccpa_response:close`, FRONT-1404.
    ///
    /// Elle ne lit rien et n'écrit rien : la croix de cet écran ne persiste RIEN (parité web,
    /// le fix I1 de FRONT-1342), elle constate seulement qu'on a refermé sans décider. C'est ce
    /// qui la distingue de `commitUsNatOptOut`, dont le hit dépend de l'écriture qui le précède.
    ///
    /// L'écran US n'émet **aucun** `ui` : le bundle web CCPA n'en émet pas non plus, sa famille
    /// de réponses est `ccpa_response`. Ne pas y ajouter de `reportUiClick` par symétrie avec le
    /// bandeau RGPD — la famille est décidée par le visiteur, pas par l'écran.
    func reportCcpaClose() {
        Task { try? await cmp.postCcpaCloseAction() }
    }

    // MARK: - Navigation

    func navigateTo(screen: ConsentScreen) {
        uiState.currentScreen = screen
        // Entering a screen builds its complete STRUCTURE up front ("tout est
        // chargé à l'affichage") — taps afterwards only flip toggles or
        // expansion. Guarded: before the store finishes loading there is
        // nothing to derive from.
        if !uiState.isLoading {
            rebuildStructure()
        }
    }

    // MARK: - Localization

    func getLocalize() -> Localize { localize }
}

// NOTE: Kotlin StateFlows are observed through ConsentStateWatcher /
// UpdateCounterWatcher (FlowWatcher.kt in iosMain). A previous Combine
// bridge here only emitted the initial value and never any update —
// do not reintroduce it.
