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

## Apps that already use `Localizable.strings`

An app that reads its text with `NSLocalizedString` and formats it with
`String(format:)` can put OTA in front of its `.strings` files without changing
its screens. `appleString(forKey:namespaces:formatOf:)` returns a key's text as
the GoLocalise iOS `.strings` export writes it, or `nil` when the current
release doesn't have the key:

- Placeholders in iOS form: `{0}` is `%@` (`%1$@` when the arguments aren't in
  order), `{0:number}` is `%d`, `{0:decimal:2}` is `%.2f`, and a literal `%` is
  `%%` (text already written as `%%` stays one literal `%`).
- `${name}` template variables (App Shortcuts) are kept as written.
- Plurals as in the export with **Plurals: in the .strings file**: `key` is the
  "other" text and `key.one`, `key.few`… are its forms.
- Namespaces are searched in the order given.
- **Crash guard (1.2.0):** pass the bundled text as `formatOf`. When the
  release's text reads an argument the bundled text does not, or reads it as
  another kind, the lookup returns `nil`, so a release can never make
  `String(format:)` crash; the app shows its bundled text instead.

```swift
// For example in a Bundle.localizedString(forKey:value:table:) override:
let bundled = bundledLookup(key)
if let text = client.appleString(forKey: key, namespaces: namespaces, formatOf: bundled),
   !text.isEmpty {
    return text
}
return bundled
```

The lookup never touches the network and is cached per release.

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
        from: "1.2.0"
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
