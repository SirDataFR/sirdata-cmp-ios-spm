# Sirdata CMP — iOS SDK (Swift Package)

A Swift Package of the Sirdata CMP iOS SDK — an IAB TCF v2.2 (CMP ID 92), GPP and CCPA/USP consent management platform with a native SwiftUI consent UI.

## Requirements

- iOS 14.0+
- Xcode 15+
- Swift 5.9+

## Installation

In Xcode: **File → Add Package Dependencies**, then enter:

```
https://github.com/SirDataFR/sirdata-cmp-ios-spm
```

Or add it to your `Package.swift`:

```swift
.package(url: "https://github.com/SirDataFR/sirdata-cmp-ios-spm", from: "1.2.0")
```

The package ships one product, `SirDataCMP`, containing two modules:

```swift
import SirDataCMP    // Core API: IosCMPApi, TCF/GPP/USP handlers
import SirDataCMPUI  // SwiftUI consent UI: ConsentView
```

## Getting started

```swift
import SirDataCMP

@main
struct MyApp: App {
    init() {
        // Initialize before any ad or analytics SDK.
        IosCMPApi.shared.initialize(partnerId: <PARTNER_ID>, configId: "<CONFIG_ID>")
    }
    // ...
}
```

Full integration guide: https://cmp.docs.sirdata.net/en/mobile-apps-native-sdk/mobile-sdk/setup-1 (setup, showing the consent UI, reading consent, vendor SDK interoperability). Documentation en français : https://cmp.docs.sirdata.net/applications-mobiles-sdk-natif/mobile-sdk/setup-1

## Release notes

Release notes for each version are available in the iOS SDK changelog: https://cmp.docs.sirdata.net/en/mobile-apps-native-sdk/mobile-sdk/versions-1

## For maintainers

This repository only distributes the SDK. It contains the SPM manifest (`Package.swift`, whose `binaryTarget` points to the XCFramework zip attached to a release of **this** repository, with its checksum) and the SwiftUI sources of the `SirDataCMPUI` module, synced from the source repository at each release by the `release-ios.yml` workflow. Do not edit either by hand outside a release: the UI sources and the binary must always be at the same version.

## License

Proprietary. Copyright (c) 2024-2026 Sirdata SAS. All rights reserved. See LICENSE.
