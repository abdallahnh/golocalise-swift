import CryptoKit
import Foundation
import XCTest

@testable import GoLocalise

private struct GoldenFixture: Decodable {
  let projectId: String
  let environment: String
  let namespace: String
  let key: String
  let englishA: String
  let arabicA: String
  let englishB: String
  let arabicB: String
}

private enum Stub: @unchecked Sendable {
  case response(OTAHTTPResponse)
  case failure(Error)
}

private actor QueueTransport: OTATransport {
  private var queue: [Stub] = []
  private(set) var requests: [(URL, [String: String])] = []

  func enqueue(_ stubs: Stub...) {
    queue.append(contentsOf: stubs)
  }

  func get(url: URL, headers: [String: String], timeout _: TimeInterval) async throws
    -> OTAHTTPResponse
  {
    requests.append((url, headers))
    guard !queue.isEmpty else { throw URLError(.notConnectedToInternet) }
    switch queue.removeFirst() {
    case .response(let response): return response
    case .failure(let error): throw error
    }
  }
}

private actor InterruptibleCache: PersistentCacheAdapter {
  private var values: [String: Data] = [:]
  var failWrites = false

  func read(key: String) -> Data? { values[key] }

  func writeAtomically(key: String, data: Data) throws {
    if failWrites { throw CocoaError(.fileWriteUnknown) }
    values[key] = data
  }

  func setFailWrites(_ value: Bool) { failWrites = value }
}

private struct ReleaseResponses {
  let manifest: OTAHTTPResponse
  let artifact: OTAHTTPResponse
  let artifactData: Data
  let hash: String
}

final class GoLocaliseClientTests: XCTestCase {
  private let token = "gl_sdk_public_reference_token_abcdefghijklmnopqrstuvwxyz"
  private lazy var fixture: GoldenFixture = {
    guard let url = Bundle.module.url(forResource: "golden", withExtension: "json") else {
      fatalError("Missing bundled test fixture: golden.json")
    }
    return try! JSONDecoder().decode(GoldenFixture.self, from: Data(contentsOf: url))
  }()

  func testCanonicalizesRegionalLocaleVariants() async throws {
    let client = try makeClient(
      transport: QueueTransport(), refreshOnInitialize: false, locale: "AR_lb")
    XCTAssertEqual(client.currentLocale, "ar-LB")
    let switched = await client.setLocale("ar_iq", refresh: false)
    XCTAssertEqual(switched, .unchanged(release: nil))
    XCTAssertEqual(client.currentLocale, "ar-IQ")
  }

  func testAsyncInitializeSynchronousLookupAndLocaleSwitch() async throws {
    let transport = QueueTransport()
    let english = try release(1, locale: "en", value: fixture.englishA)
    let arabic = try release(1, locale: "ar", value: fixture.arabicA)
    await transport.enqueue(
      .response(english.manifest), .response(english.artifact),
      .response(arabic.manifest), .response(arabic.artifact)
    )
    let client = try makeClient(
      transport: transport,
      bundled: DictionaryBundledTranslations(["en": ["common": ["bundled": "Bundled"]]])
    )
    let initialized = await client.initialize()
    XCTAssertEqual(initialized, .updated(release: 1))
    XCTAssertEqual(
      client.translation(for: fixture.key, namespace: fixture.namespace), fixture.englishA)
    XCTAssertEqual(client.namespaces(), [fixture.namespace])
    XCTAssertEqual(client.keys(namespace: fixture.namespace), [fixture.key])
    XCTAssertEqual(
      client.translations(),
      [
        GoLocaliseTranslationEntry(
          key: fixture.key, namespace: fixture.namespace, value: fixture.englishA)
      ]
    )
    XCTAssertEqual(client.translation(for: "bundled", namespace: "common"), "Bundled")
    XCTAssertEqual(client.translation(for: "missing", fallback: "Fallback"), "Fallback")
    XCTAssertEqual(client.translation(for: "missing"), "missing")
    let switched = await client.setLocale("ar")
    XCTAssertEqual(switched, .updated(release: 1))
    XCTAssertEqual(
      client.translation(for: fixture.key, namespace: fixture.namespace), fixture.arabicA)
    let requests = await transport.requests
    XCTAssertTrue(
      requests.allSatisfy { $0.1["Authorization"]?.hasPrefix("Bearer gl_sdk_") == true })
  }

  func testSafeApplePlaceholderFormattingUsesBundledAndFallbackValues() throws {
    let client = try makeClient(
      transport: QueueTransport(),
      bundled: DictionaryBundledTranslations([
        "en": [
          "default": [
            "cart": "Your cart contains items from %@. Replace them with %@?",
            "positional": "%2$@ then %1$@",
            "percent": "%@ is 100%% ready",
            "malformed": "Hello %s",
            "canonical": "{1} then {0}",
            "oneBased": "Testing {1} and {2}",
          ]
        ]
      ])
    )

    XCTAssertEqual(
      client.translation(for: "cart", arguments: ["McDonald's", "Burger King"]),
      "Your cart contains items from McDonald's. Replace them with Burger King?"
    )
    XCTAssertEqual(
      client.translation(for: "positional", arguments: ["first", "second"]), "second then first")
    XCTAssertEqual(client.translation(for: "percent", arguments: ["Build"]), "Build is 100% ready")
    XCTAssertEqual(client.translation(for: "malformed", arguments: ["World"]), "Hello %s")
    XCTAssertEqual(
      client.translation(for: "canonical", arguments: ["first", "second"]), "second then first")
    XCTAssertEqual(
      client.translation(for: "oneBased", arguments: ["one", "two"]), "Testing one and two")
    XCTAssertEqual(
      client.translation(for: "cart", arguments: ["Only one"]),
      "Your cart contains items from %@. Replace them with %@?")
    XCTAssertEqual(
      client.translation(for: "missing", arguments: ["العربية"], fallback: "مرحباً %@"),
      "مرحباً العربية"
    )
  }

  func testLocaleAwarePluralFormattingFromOTA() async throws {
    let plural = OTAPluralMessage(
      variable: "count",
      forms: [
        "zero": "لا عناصر",
        "one": "عنصر واحد",
        "two": "عنصران",
        "few": "{count} عناصر لـ {0}",
        "many": "{count} عنصراً لـ {0}",
        "other": "{count} عنصر لـ {0}",
      ]
    )
    let data = try JSONEncoder().encode(
      OTAArtifact(
        protocolVersion: 1,
        projectId: fixture.projectId,
        environment: fixture.environment,
        release: 1,
        locale: "ar",
        namespaces: [fixture.namespace: [fixture.key: plural.forms["other"]!]],
        pluralMessages: [fixture.namespace: [fixture.key: plural]]
      )
    )
    let response = try release(1, locale: "ar", value: "unused", artifactData: data)
    let transport = QueueTransport()
    await transport.enqueue(.response(response.manifest), .response(response.artifact))
    let client = try makeClient(transport: transport, locale: "ar")
    let initialized = await client.initialize()
    XCTAssertEqual(initialized, .updated(release: 1))
    XCTAssertEqual(
      client.translation(
        for: fixture.key,
        namespace: fixture.namespace,
        count: 7,
        arguments: ["المتجر"]
      ),
      "7 عناصر لـ المتجر"
    )
    XCTAssertEqual(
      client.translation(for: fixture.key, namespace: fixture.namespace, count: 2),
      "عنصران"
    )
  }

  func testOfflineAndTimeoutPreservePersistentLastKnownGood() async throws {
    let cache = MemoryCacheAdapter()
    let online = QueueTransport()
    let first = try release(1, locale: "en", value: fixture.englishA)
    await online.enqueue(.response(first.manifest), .response(first.artifact))
    let initial = try makeClient(transport: online, cache: cache)
    let initialized = await initial.initialize()
    XCTAssertEqual(initialized, .updated(release: 1))

    let offline = QueueTransport()
    await offline.enqueue(.failure(URLError(.notConnectedToInternet)))
    let restarted = try makeClient(transport: offline, cache: cache)
    guard case .failed = await restarted.initialize() else {
      return XCTFail("Expected offline failure")
    }
    XCTAssertEqual(restarted.currentRelease, 1)
    XCTAssertEqual(
      restarted.translation(for: fixture.key, namespace: fixture.namespace), fixture.englishA)

    let timeout = QueueTransport()
    await timeout.enqueue(.failure(URLError(.timedOut)))
    let timeoutClient = try makeClient(
      transport: timeout,
      bundled: DictionaryBundledTranslations(["en": ["common": [fixture.key: fixture.englishA]]])
    )
    guard case .failed = await timeoutClient.initialize() else {
      return XCTFail("Expected timeout")
    }
    XCTAssertEqual(
      timeoutClient.translation(for: fixture.key, namespace: fixture.namespace), fixture.englishA)
  }

  func testHTTPFailureMatrixPreservesLastKnownGood() async throws {
    for status in [401, 403, 404, 429, 500] {
      let transport = QueueTransport()
      let first = try release(1, locale: "en", value: fixture.englishA)
      await transport.enqueue(.response(first.manifest), .response(first.artifact))
      let client = try makeClient(transport: transport)
      _ = await client.initialize()
      await transport.enqueue(.response(OTAHTTPResponse(status: status)))
      guard case .failed(let message) = await client.refresh() else {
        return XCTFail("Expected HTTP \(status) failure")
      }
      XCTAssertTrue(message.contains("HTTP \(status)"))
      XCTAssertEqual(client.currentRelease, 1)
      XCTAssertEqual(
        client.translation(for: fixture.key, namespace: fixture.namespace), fixture.englishA)
    }
  }

  func testMalformedManifestArtifactHashAndScopeAreRejected() async throws {
    let malformedManifest = QueueTransport()
    await malformedManifest.enqueue(.response(OTAHTTPResponse(status: 200, body: Data("{".utf8))))
    let malformedClient = try makeClient(transport: malformedManifest)
    guard case .failed = await malformedClient.refresh() else {
      return XCTFail("Expected malformed manifest failure")
    }

    let unsupported = QueueTransport()
    let invalidManifest = Data(#"{"protocolVersion":2}"#.utf8)
    await unsupported.enqueue(.response(OTAHTTPResponse(status: 200, body: invalidManifest)))
    let unsupportedClient = try makeClient(transport: unsupported)
    guard case .failed = await unsupportedClient.refresh() else {
      return XCTFail("Expected unsupported protocol failure")
    }

    try await assertInvalidArtifact(.malformed)
    try await assertInvalidArtifact(.scope)
    try await assertInvalidArtifact(.hash)
  }

  func test304SameOlderAndNewerReleaseBehavior() async throws {
    let transport = QueueTransport()
    let first = try release(1, locale: "en", value: fixture.englishA)
    let second = try release(2, locale: "en", value: fixture.englishB)
    await transport.enqueue(.response(first.manifest), .response(first.artifact))
    let client = try makeClient(transport: transport)
    _ = await client.initialize()
    await transport.enqueue(.response(OTAHTTPResponse(status: 304)))
    let notModified = await client.refresh()
    XCTAssertEqual(notModified, .unchanged(release: 1))
    await transport.enqueue(.response(first.manifest))
    let same = await client.refresh()
    XCTAssertEqual(same, .unchanged(release: 1))
    await transport.enqueue(.response(second.manifest), .response(second.artifact))
    let updated = await client.refresh()
    XCTAssertEqual(updated, .updated(release: 2))
    XCTAssertEqual(
      client.translation(for: fixture.key, namespace: fixture.namespace), fixture.englishB)
    await transport.enqueue(.response(first.manifest))
    let older = await client.refresh()
    XCTAssertEqual(older, .unchanged(release: 2))
    let requests = await transport.requests
    XCTAssertTrue(requests.contains { $0.1["If-None-Match"] != nil })
  }

  func testInterruptedAtomicWritePreservesMemoryAndDisk() async throws {
    let cache = InterruptibleCache()
    let transport = QueueTransport()
    let first = try release(1, locale: "en", value: fixture.englishA)
    let second = try release(2, locale: "en", value: fixture.englishB)
    await transport.enqueue(.response(first.manifest), .response(first.artifact))
    let client = try makeClient(transport: transport, cache: cache)
    _ = await client.initialize()
    await cache.setFailWrites(true)
    await transport.enqueue(.response(second.manifest), .response(second.artifact))
    guard case .failed = await client.refresh() else { return XCTFail("Expected cache failure") }
    XCTAssertEqual(client.currentRelease, 1)
    XCTAssertEqual(
      client.translation(for: fixture.key, namespace: fixture.namespace), fixture.englishA)
    await cache.setFailWrites(false)
    let restarted = try makeClient(
      transport: QueueTransport(), cache: cache, refreshOnInitialize: false)
    let initialized = await restarted.initialize()
    XCTAssertEqual(initialized, .unchanged(release: 1))
    XCTAssertEqual(
      restarted.translation(for: fixture.key, namespace: fixture.namespace), fixture.englishA)
  }

  func testHTTPSAndSameOriginAreRequired() async throws {
    XCTAssertThrowsError(
      try GoLocaliseConfiguration(
        baseURL: URL(string: "http://ota.example")!,
        token: token,
        projectId: fixture.projectId,
        environment: fixture.environment,
        locale: "en"
      )
    )
    let transport = QueueTransport()
    let first = try release(
      1, locale: "en", value: fixture.englishA, artifactURL: "https://attacker.example/a.json")
    await transport.enqueue(.response(first.manifest))
    let client = try makeClient(transport: transport)
    guard case .failed(let message) = await client.refresh() else {
      return XCTFail("Expected origin failure")
    }
    XCTAssertTrue(message.contains("Cross-origin"))
    let requestCount = await transport.requests.count
    XCTAssertEqual(requestCount, 1)
  }

  func testMissingLocaleWrongManifestScopeAndEmptyBundleAreSafe() async throws {
    let emptyBundleClient = try makeClient(
      transport: QueueTransport(),
      bundled: DictionaryBundledTranslations([:]),
      refreshOnInitialize: false
    )
    _ = await emptyBundleClient.initialize()
    XCTAssertEqual(emptyBundleClient.translation(for: "missing"), "missing")

    let base = try release(1, locale: "en", value: fixture.englishA)
    let decoded = try JSONDecoder().decode(OTAManifest.self, from: base.manifest.body)
    for invalid in [
      OTAManifest(
        protocolVersion: 1,
        projectId: fixture.projectId,
        environment: fixture.environment,
        release: 1,
        generatedAt: decoded.generatedAt,
        locales: [:]
      ),
      OTAManifest(
        protocolVersion: 1,
        projectId: "another-project",
        environment: fixture.environment,
        release: 1,
        generatedAt: decoded.generatedAt,
        locales: decoded.locales
      ),
    ] {
      let transport = QueueTransport()
      await transport.enqueue(
        .response(
          OTAHTTPResponse(
            status: 200,
            body: try JSONEncoder().encode(invalid)
          )))
      let client = try makeClient(transport: transport)
      guard case .failed = await client.refresh() else {
        return XCTFail("Expected invalid manifest failure")
      }
    }
  }

  func testFileCacheAdapterPersistsAtomically() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("golocalise-ios-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = try FileCacheAdapter(directory: directory)
    let value = Data(fixture.arabicA.utf8)
    try await cache.writeAtomically(key: "ar", data: value)
    let stored = try await cache.read(key: "ar")
    XCTAssertEqual(stored, value)
  }

  private enum InvalidArtifactCase { case malformed, scope, hash }

  private func assertInvalidArtifact(_ invalid: InvalidArtifactCase) async throws {
    let transport = QueueTransport()
    let first = try release(1, locale: "en", value: fixture.englishA)
    var body: Data
    switch invalid {
    case .malformed: body = Data("{".utf8)
    case .scope:
      body = try artifactData(release: 2, locale: "en", value: fixture.englishB, projectId: "other")
    case .hash:
      body = try artifactData(release: 2, locale: "en", value: fixture.englishB)
    }
    let expectedBody: Data
    switch invalid {
    case .hash:
      expectedBody = try artifactData(release: 2, locale: "en", value: fixture.englishA)
    case .malformed, .scope:
      expectedBody = body
    }
    let second = try release(2, locale: "en", value: fixture.englishB, artifactData: expectedBody)
    await transport.enqueue(
      .response(first.manifest), .response(first.artifact),
      .response(second.manifest), .response(OTAHTTPResponse(status: 200, body: body))
    )
    let client = try makeClient(transport: transport)
    _ = await client.initialize()
    guard case .failed = await client.refresh() else {
      return XCTFail("Expected invalid artifact failure")
    }
    XCTAssertEqual(client.currentRelease, 1)
  }

  private func makeClient(
    transport: any OTATransport,
    cache: any PersistentCacheAdapter = MemoryCacheAdapter(),
    bundled: (any BundledTranslationAdapter)? = nil,
    refreshOnInitialize: Bool = true,
    locale: String = "en"
  ) throws -> GoLocaliseClient {
    GoLocaliseClient(
      configuration: try GoLocaliseConfiguration(
        baseURL: URL(string: "https://ota.example/")!,
        token: token,
        projectId: fixture.projectId,
        environment: fixture.environment,
        locale: locale,
        refreshOnInitialize: refreshOnInitialize,
        transport: transport,
        cache: cache,
        bundled: bundled
      ))
  }

  private func release(
    _ version: Int,
    locale: String,
    value: String,
    artifactURL: String? = nil,
    artifactData supplied: Data? = nil
  ) throws -> ReleaseResponses {
    let data = try supplied ?? artifactData(release: version, locale: locale, value: value)
    let hash = sha256(data)
    let manifest = OTAManifest(
      protocolVersion: 1,
      projectId: fixture.projectId,
      environment: fixture.environment,
      release: version,
      generatedAt: "2026-09-10T00:00:0\(version)Z",
      locales: [
        locale: OTAManifestLocale(
          hash: hash,
          url: artifactURL ?? "/releases/\(version)/\(locale).json",
          size: data.count
        )
      ]
    )
    return ReleaseResponses(
      manifest: OTAHTTPResponse(
        status: 200,
        headers: ["etag": "\"manifest-\(version)-\(locale)\""],
        body: try JSONEncoder().encode(manifest)
      ),
      artifact: OTAHTTPResponse(status: 200, body: data),
      artifactData: data,
      hash: hash
    )
  }

  private func artifactData(
    release: Int,
    locale: String,
    value: String,
    projectId: String? = nil
  ) throws -> Data {
    try JSONEncoder().encode(
      OTAArtifact(
        protocolVersion: 1,
        projectId: projectId ?? fixture.projectId,
        environment: fixture.environment,
        release: release,
        locale: locale,
        namespaces: [fixture.namespace: [fixture.key: value]]
      ))
  }

  private func sha256(_ data: Data) -> String {
    "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
