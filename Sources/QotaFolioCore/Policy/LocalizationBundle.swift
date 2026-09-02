import Foundation

public nonisolated let qotaFolioStrings: Bundle = .module

public nonisolated func qfLocalized(
    _ key: StaticString,
    defaultValue: String.LocalizationValue,
    comment: StaticString
) -> String {
    String(
        localized: key,
        defaultValue: defaultValue,
        bundle: qotaFolioStrings,
        comment: comment
    )
}
