import SwiftUI

struct ChargeView: View {
    @Environment(VehicleStore.self) private var store
    @State private var confirmingStop = false
    @State private var confirmingUnlock = false

    private var state: VehicleState? { store.state }

    var body: some View {
        ZStack {
            LeapBackground(tint: state?.isCharging == true ? LeapStyle.accent : LeapStyle.cool)

            GeometryReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 16) {
                        socHeader(size: socSize(in: proxy.size.height))
                        chargingControls
                        if let plan = state?.chargePlan {
                            chargePlanCard(plan)
                        }
                        metricsGrid
                        ChargingHistorySection(embedded: true)
                            .padding(.top, 8)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
                .refreshable { await store.refresh(refreshConfig: true) }
            }
        }
        .navigationTitle("能源")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - 启停充电 / 解锁充电枪

    /// 按车况只摆当下用得上的按钮：充电中给「停止」；插着枪没在充给「开始」+「解锁」；
    /// 没插枪整行不出现。
    ///
    /// S01 / T03 不给：cmdid 193 / 192 的依据全来自数字口径的车（leapauto 的 C16 抓包），
    /// 老车型那套没有任何样本，摆出来大概率是点了等不到确认。
    @ViewBuilder
    private var chargingControls: some View {
        if let state, !CarTypeFamily.isLegacyFamily(store.session.selectedCarType) {
            if state.isCharging {
                HStack(spacing: 10) {
                    chargeButton("停止充电", systemImage: "stop.fill", tint: LeapStyle.caution) {
                        confirmingStop = true
                    }
                    // 弹框直接挂在它自己的按钮上：iOS 26 的确认框是从锚点弹出的气泡，
                    // 挂在整页或整行上，箭头会指着别处，看不出是哪个按钮在问。
                    // 停充之后要重新插枪或回车机才能再充，不好撤回，所以先问一句。
                    .confirmationDialog("停止充电？", isPresented: $confirmingStop, titleVisibility: .visible) {
                        Button("停止充电", role: .destructive) { store.setCharging(start: false) }
                        Button("取消", role: .cancel) {}
                    } message: {
                        Text("停止后需要重新插枪或在车机上操作才能继续充电。")
                    }
                }
            } else if state.chargeGunConnected == true {
                HStack(spacing: 10) {
                    chargeButton("开始充电", systemImage: "bolt.fill", tint: LeapStyle.accent, prominent: true) {
                        store.setCharging(start: true)
                    }
                    chargeButton("解锁充电枪", systemImage: "lock.open.fill", tint: LeapStyle.secondaryLabel) {
                        confirmingUnlock = true
                    }
                    // 解锁之后线缆可以被直接拔走，同样先问。开始充电不问——发错了再停就是。
                    .confirmationDialog("解锁充电枪？", isPresented: $confirmingUnlock, titleVisibility: .visible) {
                        Button("解锁", role: .destructive) { store.unlockChargingGun() }
                        Button("取消", role: .cancel) {}
                    } message: {
                        Text("解锁后充电线可以被直接拔下。车辆不上报解锁结果，发出后无法确认是否生效。")
                    }
                }
            }
        }
    }

    private func chargeButton(
        _ title: String,
        systemImage: String,
        tint: Color,
        prominent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .leapGlassButton(prominent: prominent)
        .tint(tint)
        .commandBusy(store.isSendingCommand)
    }

    // MARK: - SOC

    /// 电量数字占屏高的 11.5%，夹在 86…116 之间。和首页车图一个道理：
    /// 主视觉长大去占多出来的高度，空白才像呼吸而不像没排满。
    private func socSize(in height: CGFloat) -> CGFloat {
        min(116, max(86, height * 0.115))
    }

    private func socHeader(size: CGFloat) -> some View {
        VStack(spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(state?.soc.map(String.init) ?? "--")
                    .font(.system(size: size, weight: .ultraLight, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("%")
                    .font(.system(size: size * 0.3, weight: .light))
                    .foregroundStyle(.secondary)
            }
            .animation(.smooth, value: state?.soc)

            Text(chargeStateLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            BatteryBar(
                soc: state?.soc ?? 0,
                limit: state?.chargeLimit,
                charging: state?.isCharging ?? false
            )
            .frame(height: 10)
            .padding(.top, 4)

            // 车端没报就整行不出现。回退到本地草稿的默认值 90% 是错的——车主实际
            // 设的可能是 95%，凭空显示一个错数字比不显示糟得多；而写一个「充电上限 --」
            // 摆在那儿，也只是把一件读不到的事天天摆到眼前，不如让位置留给别的。
            if let limit = state?.chargeLimit {
                HStack {
                    CardLabel(text: "充电上限")
                    Spacer()
                    Text("\(limit)%")
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                }
                .padding(.top, 6)
            }
        }
        .padding(.vertical, 18)
    }

    /// 充电计划卡：展示 commonConfig 里 config."3" 的真实预约设置，点一下跳到功能中心的
    /// 充电计划预览页（仍是只读预览，不下发）。跳转走深链，理由见 `MainTabView`。
    private func chargePlanCard(_ plan: ChargePlan) -> some View {
        GlassActionCard(radius: LeapStyle.tileRadius) {
            store.pendingDeepLink = ControlFeature.chargePlan.rawValue
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    CardLabel(text: "充电计划")
                    Spacer()
                    Text(plan.isEnable ? "预约开" : "预约关")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(plan.isEnable ? LeapStyle.accent : .secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(plan.beginTime.isEmpty || plan.endTime.isEmpty
                         ? "--" : "\(plan.beginTime) - \(plan.endTime)")
                        .font(.system(size: 22, weight: .medium, design: .rounded))
                        .monospacedDigit()
                    Spacer()
                    Text("充至 \(plan.percent)%")
                        .font(.subheadline.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                // cyclesDescription 读不到（空串）就不摆这一行，别留个空图标。
                if !plan.cyclesDescription.isEmpty {
                    HStack(spacing: 5) {
                        Image(systemName: "repeat")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(plan.cyclesDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var chargeStateLine: String {
        guard let state else { return "读取车况中" }
        // 车端没报充电状态，不等于没插枪。原来 nil 会落进 default 说成「未连接充电枪」，
        // 车正在充电时也是这句，等于凭空断言。
        guard let charging = state.chargeState else { return "充电状态未上报" }
        switch charging {
        case 1:
            let kind = state.isFastCharging ? "直流快充" : "交流慢充"
            guard let remain = state.chargeRemainMinutes, remain > 0 else { return "\(kind)中" }
            // 充电上限读不到就别说"充至几%"。原来这里没读到会写死 100%，
            // 而车主实际设的是 95——凭空多出来的那 5% 会让预计时间显得对不上。
            guard let limit = state.chargeLimit else {
                return "\(kind) · 预计还需 \(Self.duration(remain))"
            }
            return "\(kind) · 预计 \(Self.duration(remain))充至 \(limit)%"
        case 2: return "充电完成"
        case 3: return "充电故障，请检查充电枪"
        case 4: return "预约充电等待中"
        case 6: return "充电已暂停"
        default:
            // 充电状态的 0 只说明「没在充」，插没插枪是另一个字段。
            // 报了枪已连接就照说，没报（S01 / T03 没有这一项）才回到原来那句。
            return state.chargeGunConnected == true ? "充电枪已连接 · 等待充电" : "未连接充电枪"
        }
    }

    /// 分钟数写成"2 小时 20 分"。不满一小时就只写分钟，别写"0 小时 40 分"。
    static func duration(_ minutes: Int) -> String {
        let hours = minutes / 60
        let rest = minutes % 60
        if hours == 0 { return "\(rest) 分" }
        return rest == 0 ? "\(hours) 小时" : "\(hours) 小时 \(rest) 分"
    }

    // MARK: - 指标

    /// 六格全摆着，读不到的写 `--`。
    ///
    /// 格子该在的位置就得在——某项这次读不到就把卡片抽走，下次读到了又冒出来，
    /// 整页会跟着重排，比留个横杠更让人摸不着头脑。底下那行小字负责说明横杠是什么意思。
    private var metricsGrid: some View {
        VStack(spacing: 10) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                // 充电时把"还要多久"和"多快"顶到最前——这时候它俩就是最该被看到的数。
                if state?.isCharging == true {
                    if let remain = state?.chargeRemainMinutes, remain > 0 {
                        metricTile(label: "充电剩余时间", value: Self.duration(remain), unit: nil)
                    }
                    if let power = state?.chargePowerKW {
                        metricTile(label: "充电功率", value: String(format: "%.1f", power), unit: "kW")
                    }
                }
                // 这台车压根没有剩余能量这个字段时，格子整个不摆。
                // 「这次读不到」摆个横杠是有意义的，「这辈子都读不到」摆着就只是占地方。
                if reportsRemainingEnergy {
                    metricTile(
                        label: "剩余能量",
                        value: state?.dumpEnergyWh.map { String(format: "%.1f", $0 / 1000) } ?? "--",
                        unit: "kWh"
                    )
                }
                // 增程车的续航是电、油两个数，官方也是分开列的。纯电车照旧一个「估算续航」。
                if let state, state.hasFuel {
                    metricTile(
                        label: "纯电续航",
                        value: state.energyRange.map(String.init) ?? "--",
                        unit: "km"
                    )
                    metricTile(
                        label: "汽油续航",
                        value: state.gasolineRange.map(String.init) ?? "--",
                        unit: "km"
                    )
                    metricTile(
                        label: "综合续航",
                        value: state.totalRange.map(String.init) ?? "--",
                        unit: "km"
                    )
                    metricTile(
                        label: "油量",
                        value: state.gasolinePercent.map(String.init) ?? "--",
                        unit: "%"
                    )
                    // 燃油加热是间歇性的，加热时才摆——常驻一格「未加热」是每天报告
                    // 一件没发生的事。
                    if state.isFuelHeating {
                        metricTile(label: "燃油加热", value: "加热中", unit: nil)
                    }
                } else {
                    metricTile(
                        label: "估算续航",
                        value: state?.expectedMileage.map(String.init) ?? "--",
                        unit: "km"
                    )
                }
                metricTile(label: "电压 / 电流", text: voltageText)
                metricTile(
                    label: "最低单体温度",
                    value: state?.minSingleTemp.map(String.init) ?? "--",
                    unit: "°C"
                )
                metricTile(
                    label: "总里程",
                    value: state?.totalMileage.map(String.init) ?? "--",
                    unit: "km"
                )
                // 和首页空调卡同一套：车内读不到就退车外，标签跟着改口。
                // 车外是另一个真实的值，但绝不许它冒充车内——见 `HomeView.temperatureLabel`。
                // T03 实测整张表没有 `indoorTemp`，只有 `outdoorTemp`。
                metricTile(
                    label: state?.indoorTemp == nil && state?.outdoorTemp != nil ? "车外温度" : "车内温度",
                    value: (state?.indoorTemp ?? state?.outdoorTemp).map(LeapFormat.temperature) ?? "--",
                    unit: "°C"
                )
            }

        }
    }

    /// 这台车的字段体系里到底有没有"剩余能量"这一项。
    ///
    /// C11 那套数字 ID 里没有：81.9 kWh 的包、SOC 77.5%，该是 63.5 kWh，
    /// 而 55–70 / 550–700 / 55000–70000 三个量级在 96 个字段里一个候选都没有。
    private var reportsRemainingEnergy: Bool {
        guard let state else { return true }
        return !state.schema.candidates(for: .dumpEnergy).isEmpty
    }

    /// 这一格是两个数各带一个单位，单位得跟在自己那个数后面，
    /// 没法像别的格子那样把单位甩到最后交给 MetricValue，只好用 Text 拼。
    /// 字号照抄 MetricValue：数字 20、单位 11（`max(11, 20 * 0.38)` 就是 11）。
    private var voltageText: Text {
        let big = Font.system(size: 20, weight: .medium, design: .rounded)
        let small = Font.system(size: 11, weight: .medium)

        func part(_ number: Double?, _ unit: String) -> Text {
            Text(number.map { String(format: "%.0f", $0) } ?? "--")
                .font(big)
                .monospacedDigit()
            + Text(unit).font(small).foregroundStyle(.secondary)
        }

        return part(state?.batteryVoltage, "V")
            + Text(" · ").font(big).foregroundStyle(.secondary)
            + part(state?.batteryCurrent, "A")
    }

    private func metricTile(label: String, value: String, unit: String?) -> some View {
        metricTile(label: label) {
            MetricValue(value: value, unit: unit, size: 20)
        }
    }

    private func metricTile(label: String, text: Text) -> some View {
        metricTile(label: label) {
            text.contentTransition(.numericText())
        }
    }

    private func metricTile<Value: View>(
        label: String,
        @ViewBuilder value: () -> Value
    ) -> some View {
        GlassCard(radius: LeapStyle.tileRadius) {
            VStack(alignment: .leading, spacing: 10) {
                CardLabel(text: label)
                value()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
        }
    }
}
