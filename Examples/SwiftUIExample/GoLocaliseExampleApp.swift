import Foundation
import GoLocalise
import SwiftUI

private struct DemoConfiguration {
  let baseURL: URL
  let token: String
  let projectId: String
  let environment: String
  let initialLocale: String

  static func load(bundle: Bundle = .main) throws -> Self {
    func value(_ key: String) throws -> String {
      guard let value = bundle.object(forInfoDictionaryKey: key) as? String, !value.isEmpty else {
        throw DemoError.configuration("Missing \(key) in the app build configuration")
      }
      return value
    }
    guard let baseURL = URL(string: try value("GOLOCALISE_BASE_URL")) else {
      throw DemoError.configuration("GOLOCALISE_BASE_URL is invalid")
    }
    return try Self(
      baseURL: baseURL,
      token: value("GOLOCALISE_SDK_TOKEN"),
      projectId: value("GOLOCALISE_PROJECT_ID"),
      environment: value("GOLOCALISE_ENVIRONMENT"),
      initialLocale: value("GOLOCALISE_DEFAULT_LOCALE")
    )
  }
}

private enum DemoError: LocalizedError {
  case configuration(String)
  var errorDescription: String? {
    if case .configuration(let message) = self { return message }
    return nil
  }
}

@MainActor
private final class DemoViewModel: ObservableObject {
  @Published var entries: [GoLocaliseTranslationEntry] = []
  @Published var locales: [String] = []
  @Published var locale = "en"
  @Published var namespace = "All namespaces"
  @Published var query = ""
  @Published var status = "Loading localization…"
  @Published var error: String?

  let projectId: String
  let environment: String
  private let client: GoLocaliseClient?

  init() {
    do {
      let config = try DemoConfiguration.load()
      projectId = config.projectId
      environment = config.environment
      locale = config.initialLocale
      let cache = try FileCacheAdapter(
        directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
          .appendingPathComponent("GoLocaliseDemo")
      )
      client = GoLocaliseClient(
        configuration: try GoLocaliseConfiguration(
          baseURL: config.baseURL, token: config.token, projectId: config.projectId,
          environment: config.environment, locale: config.initialLocale, cache: cache
        ))
    } catch {
      projectId = "Not configured"
      environment = "—"
      client = nil
      self.error = error.localizedDescription
      status = "Configuration required"
    }
  }

  var release: String { client?.currentRelease.map { "v\($0)" } ?? "Not loaded" }
  var isRTL: Bool { isRightToLeftLocale(locale) }
  var namespaces: [String] { Array(Set(entries.map(\.namespace))).sorted() }
  var filteredEntries: [GoLocaliseTranslationEntry] {
    entries.filter { entry in
      let matchesNamespace = namespace == "All namespaces" || entry.namespace == namespace
      let text = "\(entry.namespace) \(entry.key) \(entry.value)"
      return matchesNamespace && (query.isEmpty || text.localizedCaseInsensitiveContains(query))
    }
  }

  func initialize() async {
    guard let client else { return }
    if let publishedLocales = try? await client.supportedLocales(), !publishedLocales.isEmpty {
      locales = publishedLocales
      if !publishedLocales.contains(locale) {
        locale = publishedLocales[0]
      }
    }
    apply(await client.setLocale(locale))
    entries = client.translations()
  }

  func changeLocale(to next: String) async {
    guard let client else { return }
    locale = next
    status = "Loading \(next)…"
    apply(await client.setLocale(next))
    entries = client.translations()
  }

  func refresh() async {
    guard let client else { return }
    status = "Checking for updates…"
    apply(await client.refresh())
    entries = client.translations()
  }

  private func apply(_ result: RefreshResult) {
    switch result {
    case .updated(let release): status = "Updated to release \(release)"
    case .unchanged: status = "Up to date"
    case .failed: status = "Offline — cached translations preserved"
    }
  }
}

private struct DemoScreen: View {
  @StateObject private var model = DemoViewModel()

  var body: some View {
    NavigationView {
      List {
        Section("Connection") {
          DemoMetadataRow(label: "Project", value: model.projectId)
          DemoMetadataRow(label: "Environment", value: model.environment)
          DemoMetadataRow(label: "Release", value: model.release)
          DemoMetadataRow(label: "Status", value: model.status)
          if let error = model.error { Text(error).foregroundStyle(.red) }
        }
        Section("Language and namespace") {
          Picker("Language", selection: $model.locale) {
            ForEach(model.locales.isEmpty ? [model.locale] : model.locales, id: \.self) { Text($0) }
          }
          .onChange(of: model.locale) { locale in Task { await model.changeLocale(to: locale) } }
          if model.namespaces.count > 1 {
            Picker("Namespace", selection: $model.namespace) {
              Text("All namespaces").tag("All namespaces")
              ForEach(model.namespaces, id: \.self) { Text($0) }
            }
          }
        }
        Section("Translations") {
          if model.filteredEntries.isEmpty {
            Text("No translations found").foregroundStyle(.secondary)
          }
          ForEach(model.filteredEntries, id: \.key) { entry in
            NavigationLink(
              destination: TranslationDetailView(
                entry: entry, locale: model.locale, release: model.release)
            ) {
              VStack(alignment: .leading, spacing: 5) {
                Text("\(entry.namespace).\(entry.key)").font(.caption.monospaced()).foregroundStyle(
                  .green)
                Text(entry.value)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .environment(\.layoutDirection, model.isRTL ? .rightToLeft : .leftToRight)
              }
            }
            .textSelection(.enabled)
          }
        }
      }
      .navigationTitle("GoLocalise Demo")
      .searchable(text: $model.query, prompt: "Search keys or values")
      .refreshable { await model.refresh() }
      .toolbar { Button("Refresh") { Task { await model.refresh() } } }
      .task { await model.initialize() }
      // Keep controls and navigation predictable. RTL is applied to translated
      // content itself so switching back to English never mirrors the chrome.
      .environment(\.layoutDirection, .leftToRight)
    }
  }
}

private struct TranslationDetailView: View {
  let entry: GoLocaliseTranslationEntry
  let locale: String
  let release: String

  var body: some View {
    List {
      DemoMetadataRow(label: "Key", value: entry.key)
      DemoMetadataRow(label: "Namespace", value: entry.namespace)
      DemoMetadataRow(label: "Language", value: locale)
      DemoMetadataRow(label: "Release", value: release)
      Section("Resolved value") {
        Text(entry.value)
          .textSelection(.enabled)
          .environment(\.layoutDirection, isRightToLeftLocale(locale) ? .rightToLeft : .leftToRight)
      }
    }
    .navigationTitle("Translation")
  }
}

private struct DemoMetadataRow: View {
  let label: String
  let value: String

  var body: some View {
    HStack {
      Text(label)
      Spacer()
      Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
    }
  }
}

@main
struct GoLocaliseExampleApp: App {
  var body: some Scene { WindowGroup { DemoScreen() } }
}

private func isRightToLeftLocale(_ locale: String) -> Bool {
  let language = locale.replacingOccurrences(of: "_", with: "-")
    .split(separator: "-").first.map(String.init)?.lowercased() ?? locale.lowercased()
  return ["ar", "fa", "he", "iw", "ur", "ps", "sd", "ku", "yi"].contains(language)
}
