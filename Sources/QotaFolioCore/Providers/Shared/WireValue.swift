import Foundation

/// Reads values off an undocumented wire without insisting on their JSON type.
///
/// Neither usage endpoint nor the ChatGPT device-auth endpoint publishes a schema, and they
/// do not agree with themselves about types: `deviceauth/usercode` returns `interval` as the
/// JSON **string** `"5"`, and a strict `Double` decode of it throws `typeMismatch`, which a
/// `try?` turns into `nil` and a `guard` turns into "the transport failed". That one silent
/// type mismatch is enough to stop every ChatGPT sign-in.
///
/// So a number is read as a number or as the text of a number, and a date is read in both
/// the spellings these servers use. The value is what matters; its JSON type is not a
/// contract anybody wrote down.
public nonisolated enum WireValue {
  /// A JSON number, whether it arrived as a number or as a quoted number.
  public static func double<Key: CodingKey>(
    _ key: Key,
    from container: KeyedDecodingContainer<Key>
  ) -> Double? {
    guard container.contains(key) else { return nil }
    guard (try? container.decodeNil(forKey: key)) != true else { return nil }
    if let value = try? container.decode(Double.self, forKey: key) {
      return value
    }
    guard let text = try? container.decode(String.self, forKey: key) else { return nil }
    return Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  /// A JSON string, whether it arrived as a string or as a bare number.
  public static func string<Key: CodingKey>(
    _ key: Key,
    from container: KeyedDecodingContainer<Key>
  ) -> String? {
    guard container.contains(key) else { return nil }
    guard (try? container.decodeNil(forKey: key)) != true else { return nil }
    if let value = try? container.decode(String.self, forKey: key) {
      return value
    }
    guard let number = try? container.decode(Double.self, forKey: key) else { return nil }
    return number == number.rounded() ? String(Int64(number)) : String(number)
  }

  /// An ISO 8601 instant.
  ///
  /// Both spellings these servers use are accepted: with fractional seconds
  /// (`2026-08-27T13:07:23.215745+00:00`, which `deviceauth/usercode` sends) and without
  /// (`2033-05-18T03:33:20Z`, which `oauth/usage` sends). Neither formatter parses the
  /// other's, so both are tried.
  public static func date(fromISO8601 value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: value) { return date }

    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: value)
  }
}
