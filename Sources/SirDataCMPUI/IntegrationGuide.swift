/**
 * SirData CMP iOS SDK — Integration Guide
 *
 * ## Prerequisites
 * - iOS 15.0+
 * - Xcode 15+
 * - Swift 5.9+
 *
 * ## Installation
 *
 * ### Swift Package Manager
 * Add the following to your `Package.swift`:
 * ```swift
 * .package(url: "https://github.com/SirDataFR/sirdata-cmp-ios-spm", from: "2.0.0")
 * ```
 *
 * ### CocoaPods
 * Add to your `Podfile`:
 * ```ruby
 * pod 'SirdataCMP', '~> 2.0'
 * ```
 *
 * ## Integration Steps
 *
 * ### 1. Initialize in AppDelegate
 * ```swift
 * import SirDataCMP
 * import SirDataCMPUI
 *
 * class AppDelegate: UIResponder, UIApplicationDelegate {
 *     func application(_ application: UIApplication,
 *                      didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
 *         // Initialize with your partner ID and config ID
 *         IosCMPApi.shared.initialize(partnerId: 123, configId: "your-config-id")
 *         return true
 *     }
 * }
 * ```
 *
 * ### 2. Show Consent Banner
 * ```swift
 * struct ContentView: View {
 *     @State private var showConsent = false
 *
 *     var body: some View {
 *         Button("Privacy settings") {
 *             IosCMPApi.shared.notifyBannerShown() // fires `cmpuishown` (IAB)
 *             showConsent = true
 *         }
 *         .sheet(isPresented: $showConsent) {
 *             // user-requested re-open: close button, `load:revisit`, capping restarted
 *             ConsentView(onFinish: { showConsent = false }, workflow: Workflow.manualDisplay)
 *         }
 *     }
 * }
 * ```
 *
 * ### 3. Read Consent State
 * ```swift
 * // TC String
 * let tcString = IosCMPApi.shared.getTcString()
 *
 * // Check if GDPR applies
 * let gdprApplies = IosCMPApi.shared.isGdprApplies()
 *
 * // Check specific purpose consent
 * let analyticsOK = IosCMPApi.shared.hasPurposeConsent(purposeId: 8)
 *
 * // Check specific vendor consent
 * let hasGoogleConsent = IosCMPApi.shared.hasVendorConsent(vendorId: 755)
 * ```
 *
 * ### 4. IAB TCF API for Vendor SDKs
 * ```swift
 * // Ping
 * IosCMPApi.shared.tcfApi().execute(command: "ping", version: 2, callback: { data, _, success in
 *     if success.boolValue, let pingData = data as? [String: Any] {
 *         print("CMP Status: \(pingData["cmpStatus"] ?? "unknown")")
 *     }
 * }, parameter: nil)
 *
 * // Get In-App TC Data
 * IosCMPApi.shared.tcfApi().execute(command: "getInAppTCData", version: 2, callback: { data, _, success in
 *     // Process TC data
 * }, parameter: nil)
 *
 * // Add event listener
 * IosCMPApi.shared.tcfApi().execute(command: "addEventListener", version: 2, callback: { data, listenerId, success in
 *     // Handle consent change events
 * }, parameter: nil)
 * ```
 *
 * ### 5. GPP API
 * ```swift
 * IosCMPApi.shared.gppApi().execute(command: "ping", parameter: nil) { data, success in
 *     // GPP ping data
 * }
 *
 * IosCMPApi.shared.gppApi().execute(command: "hasSection", parameter: "tcfeuv2") { data, success in
 *     // Check if TCF section exists
 * }
 * ```
 *
 * ## IAB TCF Compliance Notes
 * - `IABTCF_CmpSdkID` is written to NSUserDefaults IMMEDIATELY on initialize()
 * - All `IABTCF_*` keys are accessible to vendor SDKs via standard NSUserDefaults
 * - Vendor SDKs can observe `NSUserDefaults.didChangeNotification` for consent updates
 * - The TC string is encoded on the device (`TcStringEncoder`), from the choice the user records
 * - Only one CMP SDK may be active — calling initialize() twice throws an error
 */
import Foundation
