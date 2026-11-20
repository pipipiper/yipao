import SwiftUI
import WidgetKit

struct ReadOnlyVehicleWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let status: WidgetStatusSnapshot?

    private var batteryText: String { status?.soc.map { "\($0)%" } ?? "—%" }
    private var chargeIcon: String { status?.chargeState == 1 ? "bolt.fill" : "bolt.slash" }

    var body: some View {
        content
            .widgetURL(LeapDeepLink.home)
            .privacySensitive()
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryCircular:
            VStack(spacing: 3) {
                Image(systemName: status?.chargeState == 1 ? "bolt.fill" : "battery.50percent")
                Text(batteryText)
                    .font(.caption2.monospacedDigit())
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("电量")
            .accessibilityValue(status?.soc.map { "\($0)%" } ?? "未知")
        case .accessoryInline:
            if let status {
                Label {
                    Text([batteryText, status.rangeText, status.chargeLabel].compactMap { $0 }.joined(separator: " · "))
                } icon: {
                    Image(systemName: "car")
                }
            } else {
                Label("打开壹跑更新车况", systemImage: "car")
            }
        case .accessoryRectangular:
            if let status {
                VStack(alignment: .leading, spacing: 2) {
                    Text([batteryText, status.rangeText].compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                    Label(status.chargeLabel, systemImage: chargeIcon)
                        .font(.caption)
                    updated(status)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            } else {
                Label("打开壹跑更新车况", systemImage: "car")
                    .font(.caption)
            }
        default:
            VStack(alignment: .leading, spacing: 8) {
                Label("车辆状态", systemImage: "car.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let status {
                    Spacer(minLength: 0)
                    Text(batteryText)
                        .font(.system(.title, design: .rounded, weight: .semibold))
                        .monospacedDigit()
                        .accessibilityLabel("电量 \(batteryText)")
                    Text(status.rangeText ?? "续航未知")
                        .font(.subheadline.monospacedDigit())
                    Label(status.chargeLabel, systemImage: chargeIcon)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(status.chargeState == 1 ? AnyShapeStyle(LeapPalette.accent) : AnyShapeStyle(.secondary))
                    Spacer(minLength: 0)
                    updated(status)
                } else {
                    Spacer(minLength: 0)
                    Text("打开壹跑更新车况")
                        .font(.subheadline)
                    Spacer(minLength: 0)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(VehicleWidgetView.contentPadding(for: family) ?? 15)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    private func updated(_ status: WidgetStatusSnapshot) -> some View {
        Text("更新于 \(status.updatedAt, format: .dateTime.month().day().hour().minute())")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
    }
}
