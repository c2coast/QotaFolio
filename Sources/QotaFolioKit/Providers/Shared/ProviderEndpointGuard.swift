import Foundation
import QotaFolioCore

/// The one place a provider request can reach the network, and the check it has to pass first.
///
/// Every credentialed request this app makes goes to an endpoint named in
/// `ProviderTransportEndpoint`, and that enumeration is the whole list — no prose beside it
/// carries a count, because a count written twice is a count that goes stale. Read
/// `ProviderTransportEndpoint.allCases` for the roster; `providerTransportEndpointRoster`
/// in the domain suite pins every case's method, host and path, so adding one is a decision
/// somebody makes rather than a line that slips through.
///
/// This wraps the transport and refuses anything else — wrong scheme, wrong host, wrong path, a
/// port, a query, a fragment, embedded credentials, or a percent-encoded alias of any of those.
/// `ProviderEndpointPolicy` holds the rule; this is what makes it apply at runtime rather than
/// being a fact about a comparison nobody performs.
public nonisolated final class ProviderEndpointGuard: CancellableHTTPTransport, Sendable {
  private let underlying: any CancellableHTTPTransport
  private let log: any RedactingLog

  /// The log is a required argument, not a defaulted one. A guard that can be built without one
  /// is a guard that can refuse in silence, and silence is the failure this parameter exists to
  /// prevent.
  public init(underlying: any CancellableHTTPTransport, log: any RedactingLog) {
    self.underlying = underlying
    self.log = log
  }

  public func start(
    _ request: URLRequest,
    id: UsageRequestID,
    maxResponseBytes: Int
  ) -> CancellableHTTPRequest {
    // A refused request is reported as cancelled and never reaches the transport, so no network
    // object is created and no header of it is ever serialized. That terminal is deliberately
    // indistinguishable from a user cancellation to every caller — which is why the refusal is
    // also written down here. Downstream a cancellation becomes `temporarilyUnavailable` and a
    // retry, so without this event a misrouted credentialed request looks exactly like weak
    // Wi-Fi and retries for as long as the app runs.
    guard ProviderEndpointPolicy.permittedEndpoint(for: request) != nil else {
      emitRefusal(for: request)
      return CancellableHTTPRequest(id: id, terminal: .cancelled)
    }
    return underlying.start(request, id: id, maxResponseBytes: maxResponseBytes)
  }

  /// Says that the boundary refused, and whether a credential was on the request it refused.
  ///
  /// Nothing runtime-authored reaches the log. The refused host and path are exactly what must
  /// not be written — `DiagEvent.host` and `.path` are `StaticString`, which makes that
  /// structural rather than a habit — so the event names the control that fired and the one bit
  /// that changes what a reader should do about it. A refused request carrying an
  /// `Authorization` header means credential material was addressed somewhere the policy does
  /// not allow; a refused request without one is an ordinary routing defect.
  private func emitRefusal(for request: URLRequest) {
    let carriedCredential = request.value(forHTTPHeaderField: "Authorization") != nil
    log.emit(
      DiagEvent(
        provider: nil,
        operation: .endpointAdmission,
        outcome: .contractViolation,
        machineErrorCode: carriedCredential ? "endpoint.refused.credentialed" : "endpoint.refused"
      )
    )
  }
}
