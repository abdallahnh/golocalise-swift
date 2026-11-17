## 1.1.0

### New
- **Build-only namespaces.** Namespaces set to "Build only" in GoLocalise are left out of OTA releases. Download them in CI from `GET /api/v1/projects/{projectId}/translations?environment=production&namespace=<name>&format=json` (one `<namespace>.json` per namespace) and bundle them with the app; lookups fall back to these bundled strings.
  - JavaScript: `bundledFromExports({ checkout, legal })`
  - Swift: `ExportedBundledTranslations(bundle: .main, subdirectory: "GoLocalise")`
  - Android: `ExportedBundledTranslations.fromAssets(context.assets, "golocalise")`

Ready-made Bitbucket Pipelines and GitHub Actions steps are in the GoLocalise Developer Hub.

No breaking changes.
