import Foundation

public nonisolated enum ProductUserAgent {
  public static func value(appVersion: String) -> String? {
    guard !appVersion.isEmpty else { return nil }
    guard appVersion.utf8.allSatisfy(isAllowedVersionByte) else { return nil }
    return "QotaFolio/\(appVersion) (macOS)"
  }

  private static func isAllowedVersionByte(_ byte: UInt8) -> Bool {
    switch byte {
    case 45, 43, 46, 48...57, 65...90, 97...122:
      true
    default:
      false
    }
  }
}
