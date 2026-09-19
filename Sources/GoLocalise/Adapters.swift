import CryptoKit
import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public struct OTAHTTPResponse: Sendable {
  public let status: Int
  public let headers: [String: String]
  public let body: Data

  public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
    self.status = status
    self.headers = headers
    self.body = body
  }
}

public protocol OTATransport: Sendable {
  func get(url: URL, headers: [String: String], timeout: TimeInterval) async throws
    -> OTAHTTPResponse
}

public protocol PersistentCacheAdapter: Sendable {
  func read(key: String) async throws -> Data?
  func writeAtomically(key: String, data: Data) async throws
}

public protocol BundledTranslationAdapter: Sendable {
  func translation(locale: String, namespace: String, key: String) -> String?
}

public protocol BundledPluralTranslationAdapter: BundledTranslationAdapter {
  func pluralTranslation(
    locale: String,
    namespace: String,
    key: String
  ) -> OTAPluralMessage?
}

public struct URLSessionTransport: OTATransport {
  private let session: URLSession

  public init(session: URLSession = .shared) {
    self.session = session
  }

  public func get(
    url: URL,
    headers: [String: String],
    timeout: TimeInterval
  ) async throws -> OTAHTTPResponse {
    var request = URLRequest(url: url, timeoutInterval: timeout)
    request.httpMethod = "GET"
    for (name, value) in headers {
      request.setValue(value, forHTTPHeaderField: name)
    }
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw SDKError.invalidPayload("OTA response was not HTTP")
    }
    var responseHeaders: [String: String] = [:]
    for (name, value) in http.allHeaderFields {
      responseHeaders[String(describing: name).lowercased()] = String(describing: value)
    }
    return OTAHTTPResponse(status: http.statusCode, headers: responseHeaders, body: data)
  }
}

public actor MemoryCacheAdapter: PersistentCacheAdapter {
  private var values: [String: Data] = [:]

  public init() {}

  public func read(key: String) -> Data? {
    values[key]
  }

  public func writeAtomically(key: String, data: Data) {
    values[key] = data
  }
}

public struct FileCacheAdapter: PersistentCacheAdapter {
  private let directory: URL

  public init(directory: URL) throws {
    self.directory = directory
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
  }

  public func read(key: String) async throws -> Data? {
    let url = fileURL(key)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try Data(contentsOf: url)
  }

  public func writeAtomically(key: String, data: Data) async throws {
    try data.write(to: fileURL(key), options: [.atomic])
  }

  private func fileURL(_ key: String) -> URL {
    let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    return directory.appendingPathComponent("\(digest).json", isDirectory: false)
  }
}

public struct DictionaryBundledTranslations: BundledTranslationAdapter {
  private let values: [String: [String: [String: String]]]

  public init(_ values: [String: [String: [String: String]]]) {
    self.values = values
  }

  public func translation(locale: String, namespace: String, key: String) -> String? {
    values[locale]?[namespace]?[key]
  }
}
