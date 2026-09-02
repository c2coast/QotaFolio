import Foundation

public nonisolated enum RetryAfter {
  public static func parse(_ headerValue: String?, now: Date) -> Duration? {
    guard let raw = headerValue?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
      return nil
    }

    if raw.allSatisfy(\.isASCII), raw.allSatisfy({ $0.isNumber }), let seconds = Int64(raw) {
      return .seconds(seconds)
    }

    guard let date = parseHTTPDate(raw) else { return nil }
    return .seconds(max(0, date.timeIntervalSince(now)))
  }

  private static func parseHTTPDate(_ value: String) -> Date? {
    let formats = [
      "EEE, dd MMM yyyy HH:mm:ss zzz",
      "EEEE, dd-MMM-yy HH:mm:ss zzz",
      "EEE MMM d HH:mm:ss yyyy",
    ]

    for format in formats {
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = TimeZone(identifier: "GMT")
      formatter.dateFormat = format
      if let date = formatter.date(from: value) {
        return date
      }
    }
    return nil
  }
}
