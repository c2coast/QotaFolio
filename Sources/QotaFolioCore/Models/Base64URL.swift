import Foundation

public nonisolated enum Base64URL {
  public static func encode(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
  public static func decode(_ string: String) -> Data? {
    var s = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    if s.count % 4 != 0 { s += String(repeating: "=", count: 4 - s.count % 4) }
    return Data(base64Encoded: s) } }
