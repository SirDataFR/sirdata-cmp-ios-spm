/**
 * SirData CMP iOS SDK — Consent Adapter Forwarding
 *
 * Forwards consent state to third-party SDKs (Firebase Analytics, AppsFlyer, Adjust, Branch)
 * when the CMP resolves a new consent state.
 *
 * Each adapter uses conditional availability checks so the code compiles
 * even when the target SDK is not linked.
 *
 * **Consent mapping** is delegated to `TCFToGoogleConsentMapper` in the shared
 * KMM module via `cmp.getGoogleConsentState(isGdprRegion:)` — never duplicated
 * here. This guarantees privacy-signaling consistency across Android and iOS.
 */
import Foundation
import Combine
import SirDataCMP

// MARK: - Consent State Observer

/// Observes CMP consent state changes and forwards them to available third-party SDKs.
/// Automatically started when the CMP initializes via `IosCMPManager.shared`.
class ConsentAdapterForwarder: ObservableObject {

    static let shared = ConsentAdapterForwarder()

    private var stateWatcher: ConsentStateWatcher?
    private var cmp: SirDataCMP?

    private init() {}

    /// Wire the forwarder into the CMP lifecycle.
    /// Call this after `IosCMPApi.shared.initialize()` completes and the CMP is ready.
    func attach(cmp: SirDataCMP) {
        self.cmp = cmp
        startObserving()
    }

    /// Start observing consent state changes and forwarding to adapters.
    /// Note: Kotlin enums are exported as classes, so we compare with `==`
    /// against the exported case instances instead of Swift pattern matching.
    func startObserving() {
        guard let cmp else { return }
        stopObserving() // Cancel any existing subscription

        let watcher = ConsentStateWatcher(flow: cmp.getStore().state)
        watcher.watch { [weak self] state in
            guard let self else { return }
            if state == ConsentState.complete {
                self.forwardConsentToAdapters()
            }
        }
        stateWatcher = watcher
    }

    /// Stop observing consent state changes.
    func stopObserving() {
        stateWatcher?.close()
        stateWatcher = nil
    }

    // MARK: - Adapter Forwarding

    private func forwardConsentToAdapters() {
        guard let cmp else { return }

        // Single source of truth: the shared TCFToGoogleConsentMapper (commonMain).
        // Do NOT re-implement the TCF → Google Consent Mode mapping here — a local
        // copy previously diverged from the shared mapper (analytics_storage was
        // wrongly gated on vendor 755 and ignored measurement purposes 8/9).
        // Android forwards through the exact same mapper, so both platforms emit
        // identical signals by construction.
        let gdprApplies = IosCMPManager.shared.isGdprApplies()
        let consent = cmp.getGoogleConsentState(isGdprRegion: gdprApplies)

        let adStorage = consent.adStorageGranted
        let analyticsStorage = consent.analyticsStorageGranted
        let adUserData = consent.adUserDataGranted
        let adPersonalization = consent.adPersonalizationGranted

        // Forward to Firebase Analytics
        forwardToFirebase(
            adStorage: adStorage,
            analyticsStorage: analyticsStorage,
            adUserData: adUserData,
            adPersonalization: adPersonalization,
            gdprApplies: consent.isSubjectToGDPR
        )

        // Forward to AppsFlyer
        forwardToAppsFlyer(
            gdprApplies: consent.isSubjectToGDPR,
            hasConsentForDataUsage: consent.hasConsentForDataUsage,
            adPersonalization: adPersonalization,
            adStorage: adStorage
        )

        // Forward to Adjust
        forwardToAdjust(adStorage: adStorage)

        // Forward to Branch
        forwardToBranch(adStorage: adStorage)
    }

    // MARK: - Firebase Analytics

    private func forwardToFirebase(
        adStorage: Bool,
        analyticsStorage: Bool,
        adUserData: Bool,
        adPersonalization: Bool,
        gdprApplies: Bool
    ) {
        // Use NSClassFromString to check if Firebase Analytics is available
        guard NSClassFromString("FIRAnalytics") != nil else { return }

        // All four consent types MUST be set in every call.
        // When ANALYTICS_STORAGE or AD_STORAGE is DENIED, Firebase deletes ALL
        // user properties including AD_PERSONALIZATION. Explicitly re-setting all
        // types preserves the user's personalization choice per Google's guidance.
        #if canImport(FirebaseAnalytics)
        Analytics.setConsent([
            .adStorage: adStorage ? .granted : .denied,
            .analyticsStorage: analyticsStorage ? .granted : .denied,
            .adUserData: adUserData ? .granted : .denied,
            .adPersonalization: adPersonalization ? .granted : .denied
        ])

        if gdprApplies {
            Analytics.setDMAParamsForEEA(
                isSubjectToGDPR: true,
                hasConsentForAdPersonalization: adPersonalization,
                hasConsentForAdUserData: adUserData
            )
        }
        #endif
    }

    // MARK: - AppsFlyer

    private func forwardToAppsFlyer(
        gdprApplies: Bool,
        hasConsentForDataUsage: Bool,
        adPersonalization: Bool,
        adStorage: Bool
    ) {
        guard NSClassFromString("AppsFlyerLib") != nil else { return }

        #if canImport(AppsFlyerLib)
        let consent = AppsFlyerConsent(
            isUserSubjectToGDPR: gdprApplies,
            hasConsentForDataUsage: hasConsentForDataUsage,
            hasConsentForAdsPersonalization: adPersonalization,
            hasConsentForAdStorage: adStorage
        )
        AppsFlyerLib.shared().setConsentData(afConsent: consent)
        #endif
    }

    // MARK: - Adjust

    private func forwardToAdjust(adStorage: Bool) {
        guard NSClassFromString("ADJAdjust") != nil else { return }

        #if canImport(Adjust)
        ADJAdjust.trackMeasurementConsent(adStorage)
        #endif
    }

    // MARK: - Branch

    private func forwardToBranch(adStorage: Bool) {
        guard NSClassFromString("Branch") != nil else { return }

        #if canImport(Branch)
        Branch.getInstance().setTrackingDisabled(!adStorage)
        #endif
    }
}

// MARK: - Automatic Lifecycle Wiring

/// Auto-attach the forwarder when the CMP state becomes READY (config loaded).
/// This ensures consent is forwarded to third-party SDKs without requiring
/// any manual setup from the app integrator.
extension ConsentAdapterForwarder {

    /// Starts monitoring IosCMPManager initialization and auto-attaches
    /// when the CMP becomes ready. Call this once from your AppDelegate's
    /// `didFinishLaunchingWithOptions` after calling `IosCMPApi.shared.initialize()`.
    ///
    /// Alternatively, this is called automatically from `ConsentViewModel.init()`
    /// so integrators using the built-in consent UI do not need to call this.
    func autoAttachWhenReady() {
        guard IosCMPManager.shared.isInitialized() else { return }
        attach(cmp: IosCMPManager.shared.get())
    }
}
