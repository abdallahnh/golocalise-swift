## 1.2.0

### New
- **iOS: `appleString(forKey:namespaces:)`** returns text in `.strings` form, for apps that use `Localizable.strings`. `${name}` template variables stay as written.
- **iOS: `appleString(forKey:namespaces:formatOf:)`** returns `nil` when release text's format arguments don't fit the bundled text, so the app keeps its bundled string instead of crashing. `%%` stays a single `%`.

### Fixes
- **Android:** `translation(key, arguments)` and plurals fall back to the bundled text, then to the fallback, when release text doesn't fit the arguments. `%%` is a single `%`.

### JavaScript
- Version aligned to 1.2.0. No API changes.

No breaking changes.
