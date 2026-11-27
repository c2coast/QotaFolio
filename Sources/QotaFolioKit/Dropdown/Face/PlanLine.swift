import SwiftUI
import QotaFolioCore

/// What an opened card shows under its rows: the plan, and the account's own numbers, the extra
/// usage spent against its monthly cap or its prepaid credits.
struct PlanLine: View {
    let face: AccountFace
    let snapshot: UsageSnapshot?

    @Environment(\.sentenceStyle) private var style

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let plan = face.planName {
                Text(plan)
                    .font(PanelType.label)
                Text("·").foregroundStyle(.tertiary).accessibilityHidden(true)
            }
            Text(spendLine)
                .font(PanelType.bodyFigures)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var spendLine: String {
        if let extra = snapshot?.extraUsage, extra.isEnabled, let limit = extra.monthlyLimit {
            return PlanSentences.extraUsage(extra, limit: limit, style: style)
        }
        if let credits = snapshot?.credits, credits.count > 0 {
            return PlanSentences.credits(credits, style: style)
        }
        return PlanSentences.noExtraUsage()
    }
}
