import Foundation

public let goLocaliseProtocolVersion = 1

public struct OTAManifestLocale: Codable, Equatable, Sendable {
  public let hash: String
  public let url: String
  public let size: Int
}

public struct OTAManifest: Codable, Equatable, Sendable {
  public let protocolVersion: Int
  public let projectId: String
  public let environment: String
  public let release: Int
  public let generatedAt: String
  public let locales: [String: OTAManifestLocale]
}

public struct OTAArtifact: Codable, Equatable, Sendable {
  public let protocolVersion: Int
  public let projectId: String
  public let environment: String
  public let release: Int
  public let locale: String
  public let namespaces: [String: [String: String]]
  public let pluralMessages: [String: [String: OTAPluralMessage]]

  public init(
    protocolVersion: Int,
    projectId: String,
    environment: String,
    release: Int,
    locale: String,
    namespaces: [String: [String: String]],
    pluralMessages: [String: [String: OTAPluralMessage]] = [:]
  ) {
    self.protocolVersion = protocolVersion
    self.projectId = projectId
    self.environment = environment
    self.release = release
    self.locale = locale
    self.namespaces = namespaces
    self.pluralMessages = pluralMessages
  }

  private enum CodingKeys: String, CodingKey {
    case protocolVersion, projectId, environment, release, locale, namespaces
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
    projectId = try container.decode(String.self, forKey: .projectId)
    environment = try container.decode(String.self, forKey: .environment)
    release = try container.decode(Int.self, forKey: .release)
    locale = try container.decode(String.self, forKey: .locale)
    let messages = try container.decode(
      [String: [String: OTALocalizedMessage]].self,
      forKey: .namespaces
    )
    namespaces = messages.mapValues { entries in
      entries.mapValues { message in
        switch message {
        case .text(let value): value
        case .plural(let value): value.forms["other"] ?? ""
        }
      }
    }
    pluralMessages = messages.mapValues { entries in
      entries.compactMapValues { message in
        if case .plural(let value) = message { return value }
        return nil
      }
    }.filter { !$0.value.isEmpty }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(protocolVersion, forKey: .protocolVersion)
    try container.encode(projectId, forKey: .projectId)
    try container.encode(environment, forKey: .environment)
    try container.encode(release, forKey: .release)
    try container.encode(locale, forKey: .locale)
    var messages = namespaces.mapValues { entries in
      entries.mapValues(OTALocalizedMessage.text)
    }
    for (namespace, entries) in pluralMessages {
      var namespaceMessages = messages[namespace] ?? [:]
      for (key, plural) in entries { namespaceMessages[key] = .plural(plural) }
      messages[namespace] = namespaceMessages
    }
    try container.encode(messages, forKey: .namespaces)
  }
}

public struct OTAPluralMessage: Codable, Equatable, Sendable {
  public let type: String
  public let variable: String
  public let forms: [String: String]

  public init(variable: String, forms: [String: String]) {
    type = "plural"
    self.variable = variable
    self.forms = forms
  }
}

private enum OTALocalizedMessage: Codable {
  case text(String)
  case plural(OTAPluralMessage)

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let value = try? container.decode(String.self) {
      self = .text(value)
      return
    }
    let plural = try container.decode(OTAPluralMessage.self)
    guard plural.type == "plural", plural.forms["other"] != nil else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Plural messages require type plural and an other form"
      )
    }
    self = .plural(plural)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .text(let value): try container.encode(value)
    case .plural(let value): try container.encode(value)
    }
  }
}

struct CacheEnvelope: Codable, Sendable {
  let manifest: OTAManifest
  let manifestETag: String?
  let artifact: OTAArtifact
}

public enum RefreshResult: Equatable, Sendable {
  case updated(release: Int)
  case unchanged(release: Int?)
  case failed(message: String)
}

enum SDKError: Error, LocalizedError {
  case invalidConfiguration(String)
  case http(resource: String, status: Int)
  case invalidPayload(String)

  var errorDescription: String? {
    switch self {
    case .invalidConfiguration(let message), .invalidPayload(let message):
      message
    case .http(let resource, let status):
      "\(resource) request failed with HTTP \(status)"
    }
  }
}
