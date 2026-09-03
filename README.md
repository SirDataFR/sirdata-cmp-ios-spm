# Sirdata CMP — iOS SDK (Swift Package)

> **Not yet published.** No version of the SDK has been released on any channel yet
> (Swift Package Manager, CocoaPods, Maven Central and npm all return 404). This
> repository currently holds only the SPM manifest, with placeholder `url` and
> `checksum` values that the first release replaces. The installation instructions
> below describe the intended end state — they will not resolve until then.
> Tracked by FRONT-1361.

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

Full integration guide: https://developers.sirdata.com (setup, showing the consent UI, reading consent, vendor SDK interoperability).

## Release notes

Release notes for each version are available in the iOS SDK changelog: https://developers.sirdata.com/ios/versions

## For maintainers

This repository only distributes the SDK. It contains the SPM manifest (`Package.swift`, whose `binaryTarget` points to the XCFramework zip attached to a release of the source repository, with its checksum) and the SwiftUI sources of the `SirDataCMPUI` module, synced from the source repository at each release by the `release-ios.yml` workflow. Do not edit either by hand outside a release: the UI sources and the binary must always be at the same version.

## License

Proprietary. Copyright (c) 2024-2026 Sirdata SAS. All rights reserved.

The `LICENSE`, `NOTICE` and `THIRD-PARTY-LICENSES/` files are copied into this
repository by the release workflow, at each release. They are **deliberately not
committed ahead of the first release**: a second copy of the licence text would be
free to drift from the canonical one, and that text is versioned and never
overwritten in place. Until the first release, the authoritative text is:

    https://sirdata.com/legal/sdk-licence-v1.1.txt

Contact dev@sirdata.com for a commercial agreement.
