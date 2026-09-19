import CryptoKit
import Foundation

public struct GoLocaliseConfiguration: Sendable {
  public let baseURL: URL
  public let token: String
  public let projectId: String
  public let environment: String
  public let locale: String
  public let timeout: TimeInterval
  public let refreshOnInitialize: Bool
  public let transport: any OTATransport
  public let cache: any PersistentCacheAdapter
  public let bundled: (any BundledTranslationAdapter)?

  public init(
    baseURL: URL,
    token: String,
    projectId: String,
    environment: String,
    locale: String,
    timeout: TimeInterval = 5,
    refreshOnInitialize: Bool = true,
    transport: any OTATransport = URLSessionTransport(),
    cache: any PersistentCacheAdapter = MemoryCacheAdapter(),
    bundled: (any BundledTranslationAdapter)? = nil
  ) throws {
    guard token.hasPrefix("gl_sdk_") else {
      throw SDKError.invalidConfiguration("A public gl_sdk_ credential is required")
    }
    guard !projectId.isEmpty, !environment.isEmpty, !locale.isEmpty else {
      throw SDKError.invalidConfiguration("projectId, environment, and locale are required")
    }
    guard timeout > 0 else {
      throw SDKError.invalidConfiguration("timeout must be positive")
    }
    let localHosts = ["localhost", "127.0.0.1", "::1"]
    guard
      baseURL.scheme == "https"
        || (baseURL.scheme == "http" && localHosts.contains(baseURL.host ?? ""))
    else {
      throw SDKError.invalidConfiguration("baseURL must use HTTPS except on localhost")
    }
    self.baseURL = baseURL
    self.token = token
    self.projectId = projectId
    self.environment = environment
    self.locale = canonicalLocale(locale)
    self.timeout = timeout
    self.refreshOnInitialize = refreshOnInitialize
    self.transport = transport
    self.cache = cache
    self.bundled = bundled
  }
}

public final class GoLocaliseClient: @unchecked Sendable {
  private let configuration: GoLocaliseConfiguration
  private let lock = NSLock()
  private var activeLocale: String
  private var state: CacheEnvelope?

  public init(configuration: GoLocaliseConfiguration) {
    self.configuration = configuration
    activeLocale = configuration.locale
  }

  @discardableResult
  public func initialize() async -> RefreshResult {
    let locale = localeSnapshot()
    await loadCache(locale: locale)
    if !configuration.refreshOnInitialize {
      return .unchanged(release: currentRelease)
    }
    return await refresh()
  }

  @discardableResult
  public func refresh() async -> RefreshResult {
    let locale = localeSnapshot()
    let previous = stateSnapshot()
    do {
      let manifestResponse = try await configuration.transport.get(
        url: try manifestURL(locale: locale),
        headers: requestHeaders(etag: previous?.manifestETag),
        timeout: configuration.timeout
      )
      if manifestResponse.status == 304 {
        return .unchanged(release: previous?.manifest.release)
      }
      try requireSuccess(manifestResponse, resource: "manifest")
      let manifest = try JSONDecoder().decode(OTAManifest.self, from: manifestResponse.body)
      try validate(manifest: manifest, locale: locale)
      guard let localeEntry = manifest.locales[locale] else {
        throw SDKError.invalidPayload("Manifest does not contain requested locale")
      }
      if let previous, manifest.release < previous.manifest.release {
        return .unchanged(release: previous.manifest.release)
      }
      if let previous, manifest.release == previous.manifest.release {
        guard localeEntry.hash == previous.manifest.locales[locale]?.hash else {
          throw SDKError.invalidPayload("Same release returned different artifact hash")
        }
        return .unchanged(release: manifest.release)
      }
      let artifactURL = try resolvedArtifactURL(localeEntry.url)
      let artifactResponse = try await configuration.transport.get(
        url: artifactURL,
        headers: requestHeaders(etag: nil),
        timeout: configuration.timeout
      )
      try requireSuccess(artifactResponse, resource: "artifact")
      guard artifactResponse.body.count == localeEntry.size else {
        throw SDKError.invalidPayload("Artifact size mismatch")
      }
      guard sha256(artifactResponse.body) == localeEntry.hash else {
        throw SDKError.invalidPayload("Artifact hash mismatch")
      }
      let artifact = try JSONDecoder().decode(OTAArtifact.self, from: artifactResponse.body)
      try validate(artifact: artifact, manifest: manifest, locale: locale)
      let next = CacheEnvelope(
        manifest: manifest,
        manifestETag: manifestResponse.headers["etag"],
        artifact: artifact
      )
      let encoded = try JSONEncoder().encode(next)
      try await configuration.cache.writeAtomically(key: cacheKey(locale), data: encoded)
      guard install(next, ifLocaleIs: locale) else {
        return .failed(message: "Locale changed during refresh")
      }
      return .updated(release: manifest.release)
    } catch {
      return .failed(message: error.localizedDescription)
    }
  }

  @discardableResult
  public func setLocale(_ locale: String, refresh: Bool = true) async -> RefreshResult {
    guard !locale.isEmpty else { return .failed(message: "locale is required") }
    let locale = canonicalLocale(locale)
    switchToLocale(locale)
    await loadCache(locale: locale)
    if refresh { return await self.refresh() }
    return .unchanged(release: currentRelease)
  }

  public func translation(
    for key: String,
    namespace: String = "default",
    fallback: String? = nil
  ) -> String {
    lock.lock()
    let locale = activeLocale
    let otaValue = state?.artifact.namespaces[namespace]?[key]
    lock.unlock()
    return otaValue ?? configuration.bundled?.translation(
      locale: locale, namespace: namespace, key: key) ?? fallback ?? key
  }

  public func namespaces() -> [String] {
    lock.lock()
    let snapshot = state?.artifact.namespaces ?? [:]
    lock.unlock()
    return snapshot.keys.sorted()
  }

  public func keys(namespace: String? = nil) -> [String] {
    lock.lock()
    let snapshot = state?.artifact.namespaces ?? [:]
    lock.unlock()
    let names = namespace.map { [$0] } ?? Array(snapshot.keys)
    return names.flatMap { name in snapshot[name].map { Array($0.keys) } ?? [] }.sorted()
  }

  public func translations(namespace: String? = nil) -> [GoLocaliseTranslationEntry] {
    lock.lock()
    let snapshot = state?.artifact.namespaces ?? [:]
    lock.unlock()
    let names = namespace.map { [$0] } ?? Array(snapshot.keys)
    var result: [GoLocaliseTranslationEntry] = []
    for name in names {
      for (key, value) in snapshot[name] ?? [:] {
        result.append(GoLocaliseTranslationEntry(key: key, namespace: name, value: value))
      }
    }
    return result.sorted {
      $0.namespace == $1.namespace ? $0.key < $1.key : $0.namespace < $1.namespace
    }
  }

  public func supportedLocales() async throws -> [String] {
    let response = try await configuration.transport.get(
      url: try resolvedArtifactURL(
        "ota/v1/projects/\(configuration.projectId)/environments/\(configuration.environment)/locales"
      ),
      headers: requestHeaders(etag: nil),
      timeout: configuration.timeout
    )
    try requireSuccess(response, resource: "locales")
    return try JSONDecoder().decode([String].self, from: response.body)
  }

  /// Resolves and safely formats an Apple printf-style translation. The
  /// original resolved value is returned when its placeholders are malformed
  /// or do not match the supplied arguments.
  public func translation(
    for key: String,
    namespace: String = "default",
    arguments: [String],
    fallback: String? = nil
  ) -> String {
    let value = translation(for: key, namespace: namespace, fallback: fallback)
    guard let format = canonicalAppleFormat(value, argumentCount: arguments.count),
      appleStringArgumentCount(format) == arguments.count
    else { return value }
    return String(format: format, arguments: arguments.map { $0 as NSString })
  }

  /// Selects a locale-aware plural form and formats its canonical count token.
  /// Existing scalar translations remain valid and are returned unchanged.
  public func translation(
    for key: String,
    namespace: String = "default",
    count: Double,
    arguments: [String] = [],
    fallback: String? = nil
  ) -> String {
    lock.lock()
    let locale = activeLocale
    let otaPlural = state?.artifact.pluralMessages[namespace]?[key]
    lock.unlock()
    let bundledPlural = (configuration.bundled as? any BundledPluralTranslationAdapter)?
      .pluralTranslation(locale: locale, namespace: namespace, key: key)
    guard let plural = otaPlural ?? bundledPlural else {
      return translation(
        for: key,
        namespace: namespace,
        arguments: arguments,
        fallback: fallback
      )
    }
    let category = pluralCategory(locale: locale, count: count)
    let selected = plural.forms[category] ?? plural.forms["other"] ?? fallback ?? key
    guard
      let withCount = replaceNamedToken(
        selected,
        name: plural.variable,
        value: displayCount(count)
      )
    else { return selected }
    guard !arguments.isEmpty else { return withCount }
    guard let format = canonicalAppleFormat(withCount, argumentCount: arguments.count),
      appleStringArgumentCount(format) == arguments.count
    else { return withCount }
    return String(format: format, arguments: arguments.map { $0 as NSString })
  }

  public var currentRelease: Int? {
    lock.lock()
    defer { lock.unlock() }
    return state?.manifest.release
  }

  public var currentLocale: String {
    localeSnapshot()
  }

  private func loadCache(locale: String) async {
    do {
      guard let data = try await configuration.cache.read(key: cacheKey(locale)) else { return }
      let cached = try JSONDecoder().decode(CacheEnvelope.self, from: data)
      try validate(manifest: cached.manifest, locale: locale)
      try validate(artifact: cached.artifact, manifest: cached.manifest, locale: locale)
      _ = install(cached, ifLocaleIs: locale)
    } catch {
      clearState(ifLocaleIs: locale)
    }
  }

  private func validate(manifest: OTAManifest, locale: String) throws {
    guard manifest.protocolVersion == goLocaliseProtocolVersion else {
      throw SDKError.invalidPayload("Unsupported OTA protocol version")
    }
    guard manifest.projectId == configuration.projectId,
      manifest.environment == configuration.environment,
      manifest.release > 0
    else {
      throw SDKError.invalidPayload("Manifest scope mismatch")
    }
    guard let entry = manifest.locales[locale] else {
      throw SDKError.invalidPayload("Manifest does not contain requested locale")
    }
    guard entry.size >= 0,
      entry.hash.range(of: #"^sha256:[a-f0-9]{64}$"#, options: .regularExpression) != nil
    else {
      throw SDKError.invalidPayload("Manifest artifact metadata is invalid")
    }
    guard isValidISO8601Timestamp(manifest.generatedAt) else {
      throw SDKError.invalidPayload("Manifest timestamp is invalid")
    }
  }
  private func isValidISO8601Timestamp(_ value: String) -> Bool {
    let fractionalFormatter = ISO8601DateFormatter()
    fractionalFormatter.formatOptions = [
      .withInternetDateTime,
      .withFractionalSeconds,
    ]

    if fractionalFormatter.date(from: value) != nil {
      return true
    }

    let standardFormatter = ISO8601DateFormatter()
    standardFormatter.formatOptions = [
      .withInternetDateTime
    ]

    return standardFormatter.date(from: value) != nil
  }
  private func validate(artifact: OTAArtifact, manifest: OTAManifest, locale: String) throws {
    guard artifact.protocolVersion == goLocaliseProtocolVersion else {
      throw SDKError.invalidPayload("Unsupported OTA protocol version")
    }
    guard artifact.projectId == configuration.projectId,
      artifact.environment == configuration.environment,
      artifact.locale == locale,
      artifact.release == manifest.release
    else {
      throw SDKError.invalidPayload("Artifact scope mismatch")
    }
  }

  private func manifestURL(locale: String) throws -> URL {
    var url = configuration.baseURL
      .appendingPathComponent("ota")
      .appendingPathComponent("v1")
      .appendingPathComponent("projects")
      .appendingPathComponent(configuration.projectId)
      .appendingPathComponent("environments")
      .appendingPathComponent(configuration.environment)
      .appendingPathComponent("manifest")
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      throw SDKError.invalidConfiguration("Invalid base URL")
    }
    components.queryItems = [URLQueryItem(name: "locale", value: locale)]
    guard let result = components.url else {
      throw SDKError.invalidConfiguration("Invalid manifest URL")
    }
    url = result
    return url
  }

  private func resolvedArtifactURL(_ value: String) throws -> URL {
    guard let url = URL(string: value, relativeTo: configuration.baseURL)?.absoluteURL,
      url.scheme == configuration.baseURL.scheme,
      url.host == configuration.baseURL.host,
      url.port == configuration.baseURL.port
    else {
      throw SDKError.invalidPayload("Cross-origin artifact URL rejected")
    }
    return url
  }

  private func requestHeaders(etag: String?) -> [String: String] {
    var headers = ["Authorization": "Bearer \(configuration.token)"]
    if let etag { headers["If-None-Match"] = etag }
    return headers
  }

  private func requireSuccess(_ response: OTAHTTPResponse, resource: String) throws {
    guard (200..<300).contains(response.status) else {
      throw SDKError.http(resource: resource, status: response.status)
    }
  }

  private func sha256(_ data: Data) -> String {
    "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private func cacheKey(_ locale: String) -> String {
    "golocalise-v1:\(configuration.projectId):\(configuration.environment):\(locale)"
  }

  private func localeSnapshot() -> String {
    lock.lock()
    defer { lock.unlock() }
    return activeLocale
  }

  private func stateSnapshot() -> CacheEnvelope? {
    lock.lock()
    defer { lock.unlock() }
    return state
  }

  private func install(_ next: CacheEnvelope, ifLocaleIs locale: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard activeLocale == locale else { return false }
    state = next
    return true
  }

  private func switchToLocale(_ locale: String) {
    lock.lock()
    defer { lock.unlock() }
    activeLocale = locale
    state = nil
  }

  private func clearState(ifLocaleIs locale: String) {
    lock.lock()
    defer { lock.unlock() }
    if activeLocale == locale { state = nil }
  }
}

public struct GoLocaliseTranslationEntry: Equatable, Sendable {
  public let key: String
  public let namespace: String
  public let value: String
}

private func pluralCategory(locale: String, count: Double) -> String {
  let language =
    locale.replacingOccurrences(of: "_", with: "-")
    .split(separator: "-").first.map { $0.lowercased() } ?? locale.lowercased()
  let integer = Int(count)
  let isInteger = count == Double(integer)
  if language == "ar", isInteger {
    if integer == 0 { return "zero" }
    if integer == 1 { return "one" }
    if integer == 2 { return "two" }
    let modulo100 = abs(integer) % 100
    if (3...10).contains(modulo100) { return "few" }
    if (11...99).contains(modulo100) { return "many" }
    return "other"
  }
  return count == 1 ? "one" : "other"
}

private func canonicalLocale(_ locale: String) -> String {
  locale.replacingOccurrences(of: "_", with: "-")
    .split(separator: "-", omittingEmptySubsequences: false)
    .enumerated()
    .map { index, segment in
      if index == 0 { return segment.lowercased() }
      if segment.count == 2 || segment.count == 3, segment.allSatisfy(\.isLetter) {
        return segment.uppercased()
      }
      if segment.count == 4 {
        return segment.prefix(1).uppercased() + segment.dropFirst().lowercased()
      }
      return String(segment)
    }
    .joined(separator: "-")
}

private func displayCount(_ count: Double) -> String {
  count.rounded() == count ? String(Int(count)) : String(count)
}

private func replaceNamedToken(_ message: String, name: String, value: String) -> String? {
  let characters = Array(message)
  var result = ""
  var index = 0
  while index < characters.count {
    guard characters[index] == "{" else {
      if characters[index] == "}" { return nil }
      result.append(characters[index])
      index += 1
      continue
    }
    if index + 1 < characters.count, characters[index + 1] == "{" {
      result.append("{")
      index += 2
      continue
    }
    guard let closing = characters[(index + 1)...].firstIndex(of: "}") else { return nil }
    let token = String(characters[(index + 1)..<closing])
    if token == name {
      result += value
    } else if Int(token) != nil {
      result += "{\(token)}"
    } else {
      return nil
    }
    index = closing + 1
  }
  return result
}

private func appleStringArgumentCount(_ format: String) -> Int? {
  let characters = Array(format)
  var index = 0
  var sequentialCount = 0
  var positionalIndexes = Set<Int>()
  var usesSequential = false
  var usesPositional = false

  while index < characters.count {
    guard characters[index] == "%" else {
      index += 1
      continue
    }
    index += 1
    guard index < characters.count else { return nil }
    if characters[index] == "%" {
      index += 1
      continue
    }

    let digitsStart = index
    while index < characters.count, characters[index].isNumber { index += 1 }
    if index > digitsStart {
      guard index < characters.count, characters[index] == "$" else { return nil }
      let position = Int(String(characters[digitsStart..<index])) ?? 0
      guard position > 0 else { return nil }
      index += 1
      guard index < characters.count, characters[index] == "@" else { return nil }
      usesPositional = true
      positionalIndexes.insert(position)
    } else {
      guard characters[index] == "@" else { return nil }
      usesSequential = true
      sequentialCount += 1
    }
    if usesSequential && usesPositional { return nil }
    index += 1
  }

  if usesPositional {
    guard let highest = positionalIndexes.max(), positionalIndexes == Set(1...highest) else {
      return nil
    }
    return highest
  }
  return sequentialCount
}

private func canonicalAppleFormat(_ message: String, argumentCount: Int) -> String? {
  guard message.contains("{") || message.contains("}") else { return message }
  let pattern = try! NSRegularExpression(pattern: #"\{(\d+)\}"#)
  let range = NSRange(message.startIndex..., in: message)
  let matches = pattern.matches(in: message, range: range)
  var indexes = Set<Int>()
  let oneBased =
    !matches.isEmpty
    && !matches.contains { match in
      guard let indexRange = Range(match.range(at: 1), in: message),
        let index = Int(message[indexRange])
      else { return true }
      return index == 0
    }
    && matches.compactMap { match -> Int? in
      guard let range = Range(match.range(at: 1), in: message) else { return nil }
      return Int(message[range])
    }.max() == argumentCount
  var output = message
  for match in matches.reversed() {
    guard let tokenRange = Range(match.range(at: 0), in: output),
      let indexRange = Range(match.range(at: 1), in: output),
      let index = Int(output[indexRange])
    else { return nil }
    indexes.insert(index)
    output.replaceSubrange(tokenRange, with: "%\(oneBased ? index : index + 1)$@")
  }
  let expected = oneBased ? Set(1...argumentCount) : Set(0..<argumentCount)
  guard indexes == expected,
    !pattern.stringByReplacingMatches(in: message, range: range, withTemplate: "")
      .contains(where: { $0 == "{" || $0 == "}" })
  else { return nil }
  return output
}
