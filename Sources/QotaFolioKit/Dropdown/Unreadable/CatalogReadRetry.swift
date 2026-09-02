import QotaFolioCore

/// Makes the catalog's read-retry state reachable from the surface that offers the retry.
///
/// `AccountCatalog.canRetryLoad` is the answer, and it is module-internal, while the panel holds
/// `any AccountCataloging`. The protocol declares the question; this answers it for the
/// production catalog.
///
/// It lives beside the recovery takeover because the takeover is the only reader — it is the
/// surface that decides between "this list is damaged" and "we could not read it just now", and
/// the only one that offers the second a way back.
extension AccountCatalog {
    public var loadCanBeRetried: Bool { canRetryLoad }
}
