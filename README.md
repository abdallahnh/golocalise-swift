# GoLocalise iOS SDK

The Swift Package implements the frozen GoLocalise OTA protocol v1 for iOS 15+
and macOS 12+.

```swift
import GoLocalise

let bundled = DictionaryBundledTranslations([
    "en": ["common": ["welcome": "Welcome"]],
    "ar": ["common": ["welcome": "مرحباً"]],
])

let client = GoLocaliseClient(configuration: try GoLocaliseConfiguration(
    baseURL: URL(string: "https://api.golocalise.me")!,
    token: "gl_sdk_your_public_read_token",
    projectId: "your-project-id",
    environment: "production",
    locale: "ar",
    cache: try FileCacheAdapter(
        directory: FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("GoLocalise")
    ),
    bundled: bundled
))

Task { await client.initialize() }

// Always synchronous: OTA memory → bundled value → fallback → key.
let title = client.translation(
    for: "welcome",
    namespace: "common",
    fallback: "Welcome"
)
```

`initialize()`, `refresh()`, and `setLocale(_:)` are asynchronous. Translation
lookup never performs network access. Refresh validates scope, protocol, same
origin, byte size, and SHA-256 before atomically replacing cache. Every failure
keeps the last-known-good cache and bundled fallback available.

The SwiftUI demo source is in `Examples/SwiftUIExample`. It is a configuration-
driven, read-only client with release status, supported-locale switching, search,
namespace filtering, pull-to-refresh, large-list rendering, and RTL support.

## Build-only namespaces

Namespaces set to **Build only** in GoLocalise are left out of OTA releases.
Download them in your CI/CD pipeline, one `<namespace>.json` per namespace, from
`GET /api/v1/projects/{projectId}/translations?environment=production&namespace=<name>&format=json`
(ready-made Bitbucket Pipelines and GitHub Actions steps are in the Developer
Hub), and bundle them with the app. Lookups fall back to these bundled strings.

Add the `GoLocalise` folder to the app target as a folder reference, then:

```swift
let bundled = ExportedBundledTranslations(bundle: .main, subdirectory: "GoLocalise")
```

## Installation

### Swift Package Manager

Add GoLocalise to your project using Swift Package Manager:

```swift
dependencies: [
    .package(
        url: "https://github.com/abdallahnh/golocalise-swift.git",
        from: "1.1.0"
    )
]
```

Then add `GoLocalise` as a dependency to your target.

You can also add the package directly in Xcode using:

**File → Add Package Dependencies**

and enter:

```text
https://github.com/abdallahnh/golocalise-swift.git
```
