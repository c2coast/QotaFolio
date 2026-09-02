import Foundation

nonisolated enum AnthropicOAuthErrorCode: Equatable, Sendable {
  case invalidGrant
  case other

  static func decode(from body: Data) -> Self? {
    guard let envelope = try? JSONDecoder().decode(AnthropicOAuthErrorEnvelopeDTO.self, from: body) else {
      return nil
    }
    switch envelope.error {
    case "invalid_grant":
      return .invalidGrant
    case .some:
      return .other
    case .none:
      return nil
    }
  }
}

private nonisolated struct AnthropicOAuthErrorEnvelopeDTO: Decodable, Sendable {
  let error: String?
}
