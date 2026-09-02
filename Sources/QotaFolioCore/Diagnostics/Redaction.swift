import CryptoKit
import Foundation

public nonisolated enum DiagOperation: String, Sendable { case performStore, refresh, revoke, usageGET, profileGET, deviceAuthStart, deviceAuthPoll, exchange, keychainRead, keychainWrite, catalogLoad, catalogPersist, reconcile, quiesce, updateCheck, leaseAcquire, endpointAdmission, containerMigrate }

public nonisolated enum DiagOutcome: String, Sendable { case ok, transient, permanent, refused, contractViolation }

public nonisolated struct DiagEvent: Sendable { public let provider: AccountProvider?; public let operation: DiagOperation; public let outcome: DiagOutcome; public let host: StaticString?; public let path: StaticString?; public let httpStatus: Int?; public let durationMS: Int?; public let sizeBucket: Int?; public let schemaFamily: StaticString?; public let machineErrorCode: StaticString?; public let revision: CredentialRevision?; public let accountHash: String?; public init(provider: AccountProvider?, operation: DiagOperation, outcome: DiagOutcome, host: StaticString? = nil, path: StaticString? = nil, httpStatus: Int? = nil, durationMS: Int? = nil, sizeBucket: Int? = nil, schemaFamily: StaticString? = nil, machineErrorCode: StaticString? = nil, revision: CredentialRevision? = nil, accountHash: String? = nil) { self.provider = provider; self.operation = operation; self.outcome = outcome; self.host = host; self.path = path; self.httpStatus = httpStatus; self.durationMS = durationMS; self.sizeBucket = sizeBucket; self.schemaFamily = schemaFamily; self.machineErrorCode = machineErrorCode; self.revision = revision; self.accountHash = accountHash } }

public nonisolated protocol RedactingLog: Sendable { func emit(_ event: DiagEvent) }

public nonisolated func redactedAccountHash(_ id: AccountID) -> String {
  var input = Data(AccountHashRedaction.processSalt)
  input.append(contentsOf: id.rawValue.uuidString.utf8)

  let digest = SHA256.hash(data: input)
  var hexadecimal = [UInt8]()
  hexadecimal.reserveCapacity(AccountHashRedaction.digestByteCount * 2)
  for byte in digest.prefix(AccountHashRedaction.digestByteCount) {
    hexadecimal.append(AccountHashRedaction.hexAlphabet[Int(byte >> 4)])
    hexadecimal.append(AccountHashRedaction.hexAlphabet[Int(byte & 0x0f)])
  }
  return String(decoding: hexadecimal, as: UTF8.self)
}   // OURS: body

private nonisolated enum AccountHashRedaction {
  static let digestByteCount = 12
  static let hexAlphabet = Array("0123456789abcdef".utf8)
  static let processSalt: [UInt8] = {
    var generator = SystemRandomNumberGenerator()
    return (0..<32).map { _ in
      UInt8.random(in: .min ... .max, using: &generator)
    }
  }()
}

public nonisolated func diagnosticSizeBucket(forByteCount byteCount: Int) -> Int { precondition(byteCount >= 0); guard byteCount > 0 else { return 0 }; var upperBound = 1024; while upperBound < byteCount { let (next, overflow) = upperBound.multipliedReportingOverflow(by: 4); if overflow { return Int.max }; upperBound = next }; return upperBound }
