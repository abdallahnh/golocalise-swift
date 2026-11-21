import Foundation

// MARK: - Format safety

/// The kind of value a printf-style conversion reads from the argument list.
enum AppleFormatArgument: Equatable {
  case object  // %@
  case integer  // %d %i %u %x %X %o %c %C (any length)
  case double  // %f %e %g %a (any case)
  case cString  // %s %S
  case pointer  // %p
}

/// The arguments a format string reads, by position (1-based), or `nil` when
/// the string is not a format `String(format:)` can read safely: it mixes
/// numbered and unnumbered arguments, reads one position as two different
/// kinds, uses `*` widths, `%n`, or an unknown conversion.
///
/// A `%` that does not start a valid conversion makes the whole string unsafe,
/// exactly as `String(format:)` would misread it.
func appleFormatArguments(_ text: String) -> [Int: AppleFormatArgument]? {
  let characters = Array(text.unicodeScalars)
  var index = 0
  var arguments: [Int: AppleFormatArgument] = [:]
  var sequential = 0
  var usesNumbered = false
  var usesSequential = false

  func isDigit(_ i: Int) -> Bool { i < characters.count && ("0"..."9").contains(characters[i]) }

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

    // Argument number: "2$".
    var position: Int?
    let digitsStart = index
    while isDigit(index) { index += 1 }
    if index > digitsStart, index < characters.count, characters[index] == "$" {
      position = Int(String(String.UnicodeScalarView(characters[digitsStart..<index])))
      guard let position, position > 0 else { return nil }
      index += 1
    } else {
      index = digitsStart
    }
    // Flags, width, precision. `*` reads an argument too: refuse it.
    while index < characters.count, "-+ #0'".unicodeScalars.contains(characters[index]) { index += 1 }
    while isDigit(index) { index += 1 }
    if index < characters.count, characters[index] == "." {
      index += 1
      while isDigit(index) { index += 1 }
    }
    guard index < characters.count, characters[index] != "*" else { return nil }
    // Length modifiers.
    while index < characters.count, "hlqLzjt".unicodeScalars.contains(characters[index]) { index += 1 }
    guard index < characters.count else { return nil }

    let kind: AppleFormatArgument
    switch characters[index] {
    case "@": kind = .object
    case "d", "i", "u", "x", "X", "o", "c", "C", "D", "U", "O": kind = .integer
    case "f", "F", "e", "E", "g", "G", "a", "A": kind = .double
    case "s", "S": kind = .cString
    case "p": kind = .pointer
    default: return nil  // %n, or not a conversion at all
    }
    index += 1

    let slot: Int
    if let position {
      usesNumbered = true
      slot = position
    } else {
      usesSequential = true
      sequential += 1
      slot = sequential
    }
    if usesNumbered && usesSequential { return nil }
    if let existing = arguments[slot], existing != kind { return nil }
    arguments[slot] = kind
  }
  return arguments
}

/// Whether `text` can replace `reference` under `String(format:)` with the
/// arguments the app passes for `reference`: every argument `text` reads must
/// be one `reference` reads, of the same kind. Reading fewer is allowed (the
/// value is left out, nothing crashes). With no usable reference, only text
/// that reads no arguments fits.
func appleFormat(_ text: String, fits reference: String?) -> Bool {
  guard let used = appleFormatArguments(text) else { return false }
  if used.isEmpty { return true }
  guard let reference, let expected = appleFormatArguments(reference) else { return false }
  return used.allSatisfy { expected[$0.key] == $0.value }
}
