import Foundation

/// Money as the panel spells it, over the person's own locale (`SentenceStyle`). Every time and
/// every percent the panel says is Kit's, through `TimeWords` and `Whole`.
public nonisolated enum PanelWords {
    /// "£12.40" — money in the provider's currency, never a hardcoded dollar.
    public static func money(_ amount: Double, currency: String?, style: SentenceStyle) -> String {
        amount.formatted(.currency(code: currency ?? "USD").locale(style.locale))
    }
}
