import Foundation

public nonisolated struct SecretString: Sendable, Codable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
  // Redacted in every description. Without the three conformances below, interpolation,
  // String(describing:), String(reflecting:) and dump() all print the raw secret; the three of them
  // ARE the carrier (CustomReflectable required: dump/Mirror bypass the other two).
  // SecretString is Codable through a SINGLE VALUE CONTAINER, so
  // it serialises as the bare string it wraps and is byte-identical to String on every encoder — the safe field type is
  // also the cheapest one, so nothing pushes an author towards a raw String. The
  // redaction suites prove the result by executing every rendering path against a populated value.
  public var description: String { "<redacted>" }
  public var debugDescription: String { "<redacted>" }
  public var customMirror: Mirror { Mirror(self, children: []) }
  private let rawValue: String
  public init(_ value: String) { self.rawValue = value }
  // The body returns NOTHING. A generic form that let `T` be `String` would let
  // `let raw = secret.withUnsafeRawValue { $0 }` type-check and hand back the bare secret — the wrapper defeated in one
  // expression, and invisible to the type system.
  // MEASURED, both forms: with the generic, that line binds a `String`; with this one it binds `()` and raises "expression of
  // type 'String' is unused" plus "constant inferred to have type '()'", which are build FAILURES under this project's
  // -warnings-as-errors. Every call site writes its product where the product belongs — a header, a body, a local — so the
  // secret is consumed in scope and only what was derived from it survives the closure.
  public func withUnsafeRawValue(_ body: (String) throws -> Void) rethrows { try body(rawValue) }
  public var isEmpty: Bool { rawValue.isEmpty }   // the one derived fact call sites need (every DTO validates non-emptiness); reveals nothing about the value

  // Wire transparency. A SecretString encodes and decodes exactly as the String it wraps: no wrapper key, no nesting.
  // Stored envelopes written before this type existed still decode.
  public init(from decoder: any Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
  public func encode(to encoder: any Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(rawValue) }

  // Byte equality, not canonical-equivalence equality: a credential is bytes, and two Unicode-equivalent spellings of a
  // token are NOT the same token. Non-short-circuiting, because one caller compares the live OAuth `state` at the loopback listener's CSRF gate.
  public static func == (lhs: SecretString, rhs: SecretString) -> Bool {
    let left = Array(lhs.rawValue.utf8)
    let right = Array(rhs.rawValue.utf8)
    guard left.count == right.count else { return false }
    var difference: UInt8 = 0
    for index in left.indices { difference |= left[index] ^ right[index] }
    return difference == 0 } }

public nonisolated enum OAuthTokenSet: Sendable, CustomStringConvertible {   // INITIAL OAuth issuance → vault input (produced ONCE at login; refresh instead yields OAuthTokenRefreshDelta, merged by the vault). Secret-carrying enums get their own redaction carrier — enum interpolation prints payloads otherwise.
  case anthropic(accessToken: SecretString, refreshToken: SecretString, expiresAt: Date)
  case openai(accessToken: SecretString, refreshToken: SecretString, chatGPTAccountID: SecretString, accessExpiresAt: Date?)
  public var description: String { "<redacted OAuthTokenSet>" } }

public nonisolated enum ValidAccessToken: Sendable, CustomStringConvertible {   // vault → provider output (refresh tokens NEVER leave the vault)
  case anthropic(accessToken: SecretString, revision: CredentialRevision)
  case openai(accessToken: SecretString, chatGPTAccountID: SecretString, revision: CredentialRevision)
  public var revision: CredentialRevision { switch self { case .anthropic(_, let r): r; case .openai(_, _, let r): r } }  // read as a property at the poller's 401-recovery gate
  public var description: String { "<redacted ValidAccessToken>" } }
