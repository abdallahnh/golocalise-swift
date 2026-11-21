import Foundation

// MARK: - Lookup in .strings form

extension GoLocaliseClient {

  /// The text of `key` exactly as this project's iOS `.strings` export writes it,
  /// from the current OTA release, or `nil` when the release does not have it.
  ///
  /// It is meant to sit in front of an app's own `Localizable.strings` lookup
  /// (for example inside a `Bundle.localizedString(forKey:value:table:)`
  /// override), so code that formats strings with `String(format:)` keeps
  /// working unchanged:
  ///
  /// - Placeholders come back in iOS form: `{0}` is `%@` (or `%1$@` when the
  ///   arguments are not in order), `{0:number}` is `%d`, `{0:decimal:2}` is
  ///   `%.2f`, and a literal `%` is `%%`. Plural forms are always numbered.
  /// - Plurals read like the flat export: `key` is the "other" text and
  ///   `key.one`, `key.few`… are the forms. A form the plural lacks is `nil`.
  /// - `namespaces` are searched in order; the first that has the key wins.
  ///
  /// Never touches the network; safe to call from any thread.
  public func appleString(forKey key: String, namespaces: [String]) -> String? {
    lock.lock()
    defer { lock.unlock() }
    guard let artifact = state?.artifact else { return nil }
    let cacheKey = namespaces.joined(separator: "\u{1F}") + "\u{1E}" + key
    if let cached = appleStringCache[cacheKey] { return cached }
    let value = resolveAppleString(key: key, namespaces: namespaces, artifact: artifact)
    appleStringCache[cacheKey] = .some(value)
    return value
  }

  /// `appleString(forKey:namespaces:)`, kept only when it is safe to format
  /// with the arguments the app passes for `reference`, the text the app was
  /// built with (usually its development-language `Localizable.strings` value).
  ///
  /// Returns `nil`, so the app reads its bundled text, when the release's text
  /// reads an argument `reference` does not, reads one as another kind
  /// (`%d` where the app passes `%@`), or is not a valid format. A release can
  /// then never make `String(format:)` crash or print garbage. Reading fewer
  /// arguments than `reference` is allowed. With no `reference`, only text
  /// that reads no arguments is returned.
  public func appleString(forKey key: String, namespaces: [String], formatOf reference: String?) -> String? {
    guard let value = appleString(forKey: key, namespaces: namespaces) else { return nil }
    return appleFormat(value, fits: reference) ? value : nil
  }
}

private let pluralFormNames: Set<String> = ["zero", "one", "two", "few", "many", "other"]

func resolveAppleString(key: String, namespaces: [String], artifact: OTAArtifact) -> String? {
  for namespace in namespaces {
    if let plural = artifact.pluralMessages[namespace]?[key] {
      return applePluralForm(plural, form: "other")
    }
    if let text = artifact.namespaces[namespace]?[key] {
      return appleStringsValue(text)
    }
  }
  // "days_full.few": a form of the plural "days_full".
  guard let dot = key.lastIndex(of: ".") else { return nil }
  let base = String(key[..<dot])
  let form = String(key[key.index(after: dot)...])
  guard pluralFormNames.contains(form) else { return nil }
  for namespace in namespaces {
    if let plural = artifact.pluralMessages[namespace]?[base] {
      return applePluralForm(plural, form: form)
    }
  }
  return nil
}

private func applePluralForm(_ plural: OTAPluralMessage, form: String) -> String? {
  guard let text = plural.forms[form] else { return nil }
  let reference = plural.forms["other"] ?? text
  let shows = plural.forms.values.contains { $0.contains("{\(plural.variable)}") }
  let order = placeholderOrder(reference, pluralVariable: shows ? plural.variable : nil)
  return convertApplePlaceholders(text, reference: order, numbered: true)
}

/// A translation's text with GoLocalise placeholders written for iOS, as in
/// the `.strings` export with "Arguments: auto".
func appleStringsValue(_ text: String) -> String {
  convertApplePlaceholders(text, reference: placeholderOrder(text, pluralVariable: nil), numbered: false)
}

// MARK: - Placeholders (same rules as the GoLocalise iOS export)

private enum PlaceholderSpec: Equatable {
  case string, number, decimal(Int)
}

private struct PlaceholderOrder {
  var order: [String]
  var types: [String: PlaceholderSpec]
}

// `${name}` is a template variable the app fills itself (App Shortcuts' `${applicationName}`), kept as written.
private let tokenPattern = try! NSRegularExpression(pattern: #"\{\{|\}\}|(?<!\$)\{([^{}]+)\}"#)
private let indexedPattern = try! NSRegularExpression(pattern: #"^(\d+)(?::(number|decimal:(\d)))?$"#)
private let namedPattern = try! NSRegularExpression(
  pattern: #"^([A-Za-z_][A-Za-z0-9_]*)(?::(number|decimal:(\d)))?$"#)
// A literal % that is not already a format specifier ("% off" is text), or an
// existing `%%` pair (text brought over already escaped), which stays one literal %.
private let literalPercentPattern = try! NSRegularExpression(
  pattern: #"%%|%(?!(?:\d+\$)?[-+0]*\d*(?:\.\d+)?(?:hh|h|ll|l|q|z|t|j)?[@diuxXfFeEgGsScC])"#)

private struct ParsedToken {
  let id: String
  let spec: PlaceholderSpec
}

private func parseToken(_ name: String) -> (token: ParsedToken, indexed: Bool)? {
  let range = NSRange(name.startIndex..., in: name)
  for (pattern, indexed) in [(indexedPattern, true), (namedPattern, false)] {
    guard let match = pattern.firstMatch(in: name, range: range),
      let idRange = Range(match.range(at: 1), in: name)
    else { continue }
    var spec = PlaceholderSpec.string
    if let kind = Range(match.range(at: 2), in: name), name[kind] == "number" {
      spec = .number
    } else if let digits = Range(match.range(at: 3), in: name), let value = Int(name[digits]) {
      spec = .decimal(value)
    }
    return (ParsedToken(id: String(name[idRange]), spec: spec), indexed)
  }
  return nil
}

private func tokenMatches(_ text: String) -> [NSTextCheckingResult] {
  tokenPattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
}

/// Placeholder ids in argument order: the plural variable first, then `{0}`,
/// `{1}`… by number (gaps kept), then named ones in order of appearance.
private func placeholderOrder(_ text: String, pluralVariable: String?) -> PlaceholderOrder {
  var seen: [String] = []
  var types: [String: PlaceholderSpec] = [:]
  if let pluralVariable {
    seen.append(pluralVariable)
    types[pluralVariable] = .number
  }
  for match in tokenMatches(text) {
    guard let nameRange = Range(match.range(at: 1), in: text),
      let parsed = parseToken(String(text[nameRange]))
    else { continue }
    let id = parsed.token.id
    if !seen.contains(id) { seen.append(id) }
    if types[id] == nil || types[id] == .string { types[id] = parsed.token.spec }
  }
  let head = pluralVariable.map { [$0] } ?? []
  let rest = seen.filter { $0 != pluralVariable }
  let indexed = rest.compactMap(Int.init).sorted()
  let named = rest.filter { Int($0) == nil }
  var slots = head
  if let highest = indexed.last {
    for index in 0...highest {
      slots.append(indexed.contains(index) ? String(index) : "\u{0}gap\(index)")
    }
  }
  return PlaceholderOrder(order: slots + named, types: types)
}

private func convertApplePlaceholders(
  _ text: String,
  reference: PlaceholderOrder,
  numbered: Bool
) -> String {
  var order = reference.order
  enum Part {
    case text(String)
    case argument(position: Int, spec: PlaceholderSpec)
  }
  var parts: [Part] = []
  var used: [Int] = []
  var last = text.startIndex
  for match in tokenMatches(text) {
    guard let whole = Range(match.range, in: text) else { return text }
    parts.append(.text(String(text[last..<whole.lowerBound])))
    last = whole.upperBound
    let token = String(text[whole])
    if token == "{{" {
      parts.append(.text("{"))
      continue
    }
    if token == "}}" {
      parts.append(.text("}"))
      continue
    }
    guard let nameRange = Range(match.range(at: 1), in: text),
      let parsed = parseToken(String(text[nameRange]))
    else {
      return text  // Not a placeholder: leave the text as written.
    }
    let id = parsed.token.id
    if !order.contains(id) { order.append(id) }
    let spec = parsed.token.spec != .string ? parsed.token.spec : (reference.types[id] ?? .string)
    let position = (order.firstIndex(of: id) ?? 0) + 1
    used.append(position)
    parts.append(.argument(position: position, spec: spec))
  }
  parts.append(.text(String(text[last...])))
  guard !used.isEmpty else { return text }
  let inOrder = used.enumerated().allSatisfy { $0.element == $0.offset + 1 }
  let simple = !numbered && inOrder
  return parts.map { part -> String in
    switch part {
    case .text(let value):
      return literalPercentPattern.stringByReplacingMatches(
        in: value, range: NSRange(value.startIndex..., in: value), withTemplate: "%%")
    case .argument(let position, let spec):
      let letter: String
      switch spec {
      case .string: letter = "@"
      case .number: letter = "d"
      case .decimal(let digits): letter = ".\(digits)f"
      }
      return simple ? "%\(letter)" : "%\(position)$\(letter)"
    }
  }.joined()
}
