/**
 * SirData CMP iOS SDK — Integration Guide
 *
 * ## Prerequisites
 * - iOS 14.0+
 * - Xcode 15+
 * - Swift 5.9+
 *
 * ## Installation
 *
 * ### Swift Package Manager
 * Add the following to your `Package.swift`:
 * ```swift
 * .package(url: "https://github.com/SirDataFR/sirdata-cmp-mobile.git", from: "1.0.0")
 * ```
 *
 * ### CocoaPods
 * Add to your `Podfile`:
 * ```ruby
 * pod 'SirDataCMP'
 * ```
 *
 * ## Integration Steps
 *
 * ### 1. Initialize in AppDelegate
 * ```swift
 * import SirDataCMP
 * import shared
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
 *         Button("Show Consent") {
 *             showConsent = true
 *         }
 *         .sheet(isPresented: $showConsent) {
 *             ConsentView(onFinish: { showConsent = false })
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
 * let hasAnalytics = IosCMPApi.shared.hasPurposeConsent(purposeId: 5)
 *
 * // Check specific vendor consent
 * let hasGoogleConsent = IosCMPApi.shared.hasVendorConsent(vendorId: 755)
 * ```
 *
 * ### 4. IAB TCF API for Vendor SDKs
 * ```swift
 * // Ping
 * IosCMPApi.shared.tcfApi().execute(command: "ping", version: 2) { data, success in
 *     if success, let pingData = data as? [String: Any] {
 *         print("CMP Status: \(pingData["cmpStatus"] ?? "unknown")")
 *     }
 * }
 *
 * // Get In-App TC Data
 * IosCMPApi.shared.tcfApi().execute(command: "getInAppTCData", version: 2) { data, success in
 *     // Process TC data
 * }
 *
 * // Add event listener
 * IosCMPApi.shared.tcfApi().execute(command: "addEventListener", version: 2) { data, listenerId, success in
 *     // Handle consent change events
 * }
 * ```
 *
 * ### 5. GPP API
 * ```swift
 * IosCMPApi.shared.gppApi().execute(command: "ping") { data, success in
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
 * - TCString is generated server-side (NOT locally encoded)
 * - Only one CMP SDK may be active — calling initialize() twice throws an error
 */
import Foundation
