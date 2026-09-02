import Foundation

public nonisolated enum ProviderTransportEndpoint: CaseIterable, Sendable {
  case anthropicToken
  case anthropicRevoke
  case anthropicUsage
  case anthropicProfile
  case openAIDeviceStart
  case openAIDevicePoll
  case openAIToken
  case openAIUsage

  public var method: String {
    switch self {
    case .anthropicUsage, .anthropicProfile, .openAIUsage:
      "GET"
    case .anthropicToken, .anthropicRevoke, .openAIDeviceStart, .openAIDevicePoll, .openAIToken:
      "POST"
    }
  }

  public var host: String {
    switch self {
    case .anthropicToken, .anthropicRevoke:
      "platform.claude.com"
    case .anthropicUsage, .anthropicProfile:
      "api.anthropic.com"
    case .openAIDeviceStart, .openAIDevicePoll, .openAIToken:
      "auth.openai.com"
    case .openAIUsage:
      "chatgpt.com"
    }
  }

  public var path: String {
    switch self {
    case .anthropicToken:
      "/v1/oauth/token"
    case .anthropicRevoke:
      "/v1/oauth/token/revoke"
    case .anthropicUsage:
      "/api/oauth/usage"
    case .anthropicProfile:
      "/api/oauth/profile"
    case .openAIDeviceStart:
      "/api/accounts/deviceauth/usercode"
    case .openAIDevicePoll:
      "/api/accounts/deviceauth/token"
    case .openAIToken:
      "/oauth/token"
    case .openAIUsage:
      "/backend-api/wham/usage"
    }
  }
}

public nonisolated enum ProviderEndpointPolicy {
  public static func permittedEndpoint(
    for request: URLRequest
  ) -> ProviderTransportEndpoint? {
    ProviderTransportEndpoint.allCases.first { endpoint in
      permits(request, endpoint: endpoint)
    }
  }

  public static func permits(
    _ request: URLRequest,
    endpoint: ProviderTransportEndpoint
  ) -> Bool {
    guard request.httpMethod == endpoint.method else { return false }
    guard let url = request.url,
          url.baseURL == nil,
          let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else {
      return false
    }

    // Compare both decoded and percent-encoded components. Foundation intentionally normalizes
    // escaped host/path bytes for decoded accessors; accepting only one view would let an encoded
    // alias reach the same network destination without matching the fixed wire spelling.
    guard components.scheme == "https" else { return false }
    guard components.host == endpoint.host,
          components.percentEncodedHost == endpoint.host
    else {
      return false
    }
    guard components.port == nil || components.port == 443 else { return false }
    guard components.path == endpoint.path,
          components.percentEncodedPath == endpoint.path
    else {
      return false
    }
    guard components.user == nil,
          components.percentEncodedUser == nil,
          components.password == nil,
          components.percentEncodedPassword == nil
    else {
      return false
    }
    guard components.query == nil,
          components.percentEncodedQuery == nil,
          components.fragment == nil,
          components.percentEncodedFragment == nil
    else {
      return false
    }
    return true
  }
}

/// What a usage poll is allowed to spend on the network it finds itself on.
///
/// `URLRequest.allowsConstrainedNetworkAccess` and `.allowsExpensiveNetworkAccess` both default
/// to `true`, which means a MacBook tethered to a phone, or one whose Wi-Fi is in Low Data
/// Mode, polls both providers at the ordinary cadence over the path the user asked the system
/// to spare. This is the one finding in the energy audit a user could feel, and it is the one
/// place in the app where the user has already stated a preference to the operating system and
/// the app was not asking.
///
/// The line is the line `PollingPolicy.isAttention(_:)` already draws, because it is the same
/// question: is somebody waiting for this number? A poll the user asked for — the panel opened,
/// Refresh pressed, an account added, a wake, a network coming back — goes out whatever the
/// path costs, because refusing it would answer a person with a blank. A `.scheduled` or
/// `.contextChanged` poll of a menu bar nobody is looking at does not, and the refusal arrives
/// as `URLError.networkUnavailableReason`, which the existing failure backoff already treats as
/// transient. The next attention trigger — including the `.networkRestored` one `NWPathMonitor`
/// delivers — refills the panel.
///
/// **Set per request, not on the session.** A session-wide setting would refuse the poll the
/// user is watching for as readily as the one nobody asked for, and those are exactly the two
/// cases that must differ.
///
/// **Only the usage GET carries this.** Token refresh, revoke, and both halves of the device
/// flow are user-initiated by construction or ride inside a poll that has already been
/// admitted; none of them recurs on a cadence, so constraining them would risk a sign-in on a
/// tethered laptop to save roughly one POST an hour.
public nonisolated enum ProviderNetworkConstraints {
  public static func apply(to request: inout URLRequest, trigger: PollTrigger) {
    let userIsWaiting = PollingPolicy.isAttention(trigger)
    request.allowsConstrainedNetworkAccess = userIsWaiting
    request.allowsExpensiveNetworkAccess = userIsWaiting
  }
}

public nonisolated enum ProviderUsageResponseDisposition: Sendable {
  case parseBody
  case fail(UsageProviderError)
}

public nonisolated enum ProviderUsageErrorPolicy {
  public static func disposition(
    status: Int,
    retryAfter: Duration?
  ) -> ProviderUsageResponseDisposition {
    switch status {
    case 200:
      .parseBody
    case 201...299:
      .fail(.invalidPayload)
    case 401:
      .fail(.unauthorized)
    case 429:
      .fail(.rateLimited(retryAfter: retryAfter))
    default:
      .fail(.temporarilyUnavailable)
    }
  }

  public static func mapTransportError(_ error: HTTPTransportError) -> UsageProviderError {
    switch error {
    case .responseTooLarge:
      .invalidPayload
    case .redirectNotFollowed, .transport, .invalidResponse:
      .temporarilyUnavailable
    }
  }
}
