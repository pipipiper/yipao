import SwiftUI

/// 舒适座舱：座椅加热 / 通风、方向盘加热、后视镜加热。
///
/// 和空调页最大的不同是**这一页的状态是真的**：八个座椅信号、方向盘的 `1816`、
/// 后视镜的 `49`/`50` 全在一台 C16 的真实 signalMap 里，档位能直接回显、指令成败能靠信号确认。
/// 所以这里没有「高亮的是本机记录」那种免责声明——草稿只活在点击到车确认之间。
struct ComfortCabinView: View {
    @Environment(VehicleStore.self) private var store
    @State private var confirmingCloseAll = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if hasAnySeat { seatMap }
                if store.steeringWheelLevel != nil { steeringWheelCard }
                if store.mirrorHeatingOn != nil { mirrorCard }
                if !hasAnything { emptyNotice }
            }
            .padding(16)
            .padding(.bottom, 8)
        }
        .scrollIndicators(.hidden)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    confirmingCloseAll = true
                } label: {
                    Image(systemName: "power")
                        .font(.system(size: 15, weight: .bold))
                        .frame(width: 32, height: 32)
                }
                .disabled(!hasAnythingOn)
                .accessibilityLabel("全部关闭")
            }
        }
        .confirmationDialog(
            "关闭所有座舱加热与通风？",
            isPresented: $confirmingCloseAll,
            titleVisibility: .visible
        ) {
            Button("全部关闭", role: .destructive) { store.closeAllCabinComfort() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会把当前开着的座椅、方向盘和后视镜逐条关掉。")
        }
    }

    // MARK: - 有没有东西可显示

    private var hasAnySeat: Bool {
        SeatPosition.allCases.contains(where: hasControls)
    }

    private func hasControls(_ position: SeatPosition) -> Bool {
        SeatComfortChannel.allCases.contains { store.seatLevel(position, $0) != nil }
    }

    private var hasAnything: Bool {
        hasAnySeat || store.steeringWheelLevel != nil || store.mirrorHeatingOn != nil
    }

    private var hasAnythingOn: Bool {
        let seatOn = SeatComfortChannel.allCases.contains { channel in
            SeatPosition.allCases.contains { (store.seatLevel($0, channel) ?? 0) > 0 }
        }
        return seatOn || (store.steeringWheelLevel ?? 0) > 0 || store.mirrorHeatingOn == true
    }

    private var emptyNotice: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 6) {
                if store.cabinComfortSupported {
                    Label("暂时读不到座舱状态", systemImage: "moon.zzz.fill")
                        .font(.subheadline.weight(.medium))
                    Text("座舱控制会在车况刷新后显示。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Label("当前车辆暂无可用的座舱控制", systemImage: "carseat.right")
                        .font(.subheadline.weight(.medium))
                }
            }
        }
    }

    // MARK: - 座椅

    private var seatMap: some View {
        GlassCard(radius: LeapStyle.cardRadius) {
            VStack(spacing: 18) {
                HStack(spacing: 16) {
                    Image(systemName: "steeringwheel")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                    Color.clear.frame(maxWidth: .infinity).frame(height: 1)
                }
                .accessibilityHidden(true)

                if SeatPosition.front.contains(where: hasControls) {
                    seatRow(SeatPosition.front)
                }
                if SeatPosition.rear.contains(where: hasControls) {
                    seatRow(SeatPosition.rear)
                }
            }
            .frame(maxWidth: 292)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
    }

    private func seatRow(_ row: [SeatPosition]) -> some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach(row) { position in
                Group {
                    if hasControls(position) {
                        seatTile(position)
                    } else {
                        Color.clear
                            .frame(height: 92)
                            .accessibilityHidden(true)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func seatTile(_ position: SeatPosition) -> some View {
        VStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 6)
                .fill(.primary.opacity(0.12))
                .frame(height: 12)
                .padding(.horizontal, 10)
                .accessibilityHidden(true)

            HStack(spacing: 4) {
                ForEach(SeatComfortChannel.allCases) { channel in
                    if let level = store.seatLevel(position, channel) {
                        seatControl(position, channel: channel, level: level)
                    }
                }
            }
            .padding(4)
            .background(.primary.opacity(0.07), in: .rect(cornerRadius: 14))

            Text(position.label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: 126)
    }

    private func seatControl(_ position: SeatPosition, channel: SeatComfortChannel, level: Int) -> some View {
        let tint = channel == .heating ? LeapStyle.warm : LeapStyle.cool
        let isOn = level > 0

        return Button {
            store.cycleSeat(position, channel)
        } label: {
            VStack(spacing: 2) {
                Image(systemName: channel.symbol)
                    .font(.system(size: 16, weight: .semibold))
                Text(level.formatted())
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .contentTransition(.numericText())
            }
            .foregroundStyle(isOn ? AnyShapeStyle(tint) : AnyShapeStyle(.secondary))
            .frame(minWidth: 44, maxWidth: .infinity, minHeight: 44)
            .background(isOn ? tint.opacity(0.18) : .clear, in: .rect(cornerRadius: 10))
            .contentShape(.rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .animation(.snappy, value: level)
        .sensoryFeedback(.selection, trigger: level)
        .accessibilityLabel("\(position.label)座椅\(channel.label)")
        .accessibilityValue(isOn ? "\(level) 档" : "已关闭")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: store.setSeat(position, channel, level: min(channel.maxLevel, level + 1))
            case .decrement: store.setSeat(position, channel, level: max(0, level - 1))
            @unknown default: return
            }
        }
    }

    // MARK: - 方向盘加热

    private var steeringWheelCard: some View {
        let level = store.steeringWheelLevel ?? 0
        return GlassCard(radius: LeapStyle.tileRadius, tint: level > 0 ? LeapStyle.warm : nil) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("方向盘加热", systemImage: "steeringwheel")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    // 剩余分钟只在加热确实开着时才给——信号 1624 在关闭时也非 0，
                    // 取值判据收在 `VehicleState.steeringWheelHeatMinutes` 里。
                    if let minutes = store.steeringWheelHeatMinutes {
                        Text("约剩 \(minutes) 分钟")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                steeringWheelLevels(current: level)
            }
        }
    }

    /// 方向盘只有两档（弱 / 强），和座椅的三档不是一套量程。
    private func steeringWheelLevels(current: Int) -> some View {
        let options: [(level: Int, label: String)] = [(0, "关"), (1, "弱"), (2, "强")]
        return HStack(spacing: 6) {
            ForEach(options, id: \.level) { option in
                Button {
                    store.setSteeringWheelHeat(level: option.level)
                } label: {
                    Text(option.label)
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .foregroundStyle(current == option.level ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .background {
                    if current == option.level {
                        Capsule().fill(.primary.opacity(0.14))
                    }
                }
                .accessibilityAddTraits(current == option.level ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(4)
        .leapGlass(.regular, in: .capsule)
        .animation(.snappy, value: current)
        .sensoryFeedback(.selection, trigger: current)
    }

    // MARK: - 后视镜加热

    private var mirrorCard: some View {
        let on = store.mirrorHeatingOn ?? false
        return GlassActionCard(radius: LeapStyle.tileRadius, tint: on ? LeapStyle.frost : nil) {
            store.toggleMirrorHeating()
        } content: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    // 车端那个信号（1946）本来就是「后风挡**及外后视镜**电加热除雾」，
                    // 用后风挡加热这个字形比任何后视镜字形都贴。
                    Label("后视镜加热", systemImage: "windshield.rear.and.heat.waves")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Text(on ? "已开启" : "已关闭")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(on ? AnyShapeStyle(LeapStyle.frost) : AnyShapeStyle(.secondary))
                }
                // 这是五项里唯一官方 App 自己都没做的功能：内部码 440 在官方包里连中文文案都没有。
                // 按下去没反应时，用户该先知道这件事，而不是以为我们坏了。
                Text(store.state?.mirrorHeatingMismatched == true
                     ? "左右状态不一致 · 该指令未经官方 App 验证"
                     : "轻点切换 · 该指令未经官方 App 验证")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .commandBusy(store.isSendingCommand)
    }
}
