import SwiftUI

struct CabinClimateView: View {
    enum Tab: String, CaseIterable {
        case climate = "空调控制"
        case comfort = "舒适座舱"
    }

    @Environment(VehicleStore.self) private var store
    @State private var selection: Tab
    @State private var temperaturePush: Task<Void, Never>?

    init(initialTab: Tab = .climate) {
        _selection = State(initialValue: initialTab)
    }

    private var tint: Color {
        if selection == .comfort { return LeapStyle.frost }
        guard store.climateOn else { return LeapStyle.cool.opacity(0.6) }
        return store.climateMode == .hot ? LeapStyle.warm : LeapStyle.cool
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("座舱控制", selection: $selection) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            switch selection {
            case .climate:
                ClimateView(temperaturePush: $temperaturePush)
            case .comfort:
                ComfortCabinView()
            }
        }
        .background { LeapBackground(tint: tint) }
        .navigationTitle("座舱控制")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            temperaturePush?.cancel()
            store.cancelPendingCabinPushes()
        }
    }
}

private struct ClimateView: View {
    @Environment(VehicleStore.self) private var store

    /// 只由温度按钮启动。切换顶部页签后仍可完成这一次调温。
    @Binding var temperaturePush: Task<Void, Never>?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// 到了无障碍字号，横排的东西基本都放不下了，几处布局要换成竖排。
    private var isAccessibilitySize: Bool { dynamicTypeSize.isAccessibilitySize }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 14) {
                    Spacer(minLength: 0)
                    temperatureDial
                    Spacer(minLength: 0)
                    modePicker
                    modeNotice
                    fanControl
                    circulationRow
                    Spacer(minLength: 12)
                    quickActions
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
                .frame(minHeight: proxy.size.height)
            }
            .scrollIndicators(.hidden)
        }
        .toolbar {
            // 预约空调（cmdid 171）。用视图型 NavigationLink 而不是 value 型：
            // 这棵 NavigationStack 走数组路径，二级页注册的 navigationDestination 会被吞掉，
            // 点了没反应也不报错。
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    ClimateAppointmentView()
                } label: {
                    Image(systemName: "calendar.badge.clock")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel("预约空调")
            }
            ToolbarItem(placement: .topBarTrailing) {
                // 工具栏里的 Toggle 会退化成带标题的按钮，这里用电源按钮表达开关更清楚。
                Button {
                    store.applyClimate(on: !store.climateOn)
                } label: {
                    Image(systemName: "power")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(store.climateOn ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                        .frame(width: 32, height: 32)
                        .background {
                            Circle().fill(store.climateOn ? AnyShapeStyle(LeapStyle.accent) : AnyShapeStyle(.clear))
                        }
                }
                .accessibilityLabel(store.climateOn ? "关闭空调" : "开启空调")
                .commandBusy(store.isSendingCommand)
            }
        }
    }

    // MARK: - 温度

    private var temperatureDial: some View {
        VStack(spacing: 12) {
            Text(stateLine)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 26) {
                stepButton(systemImage: "minus", label: "降低温度") {
                    store.climateTemperature = max(18, store.climateTemperature - 1)
                    scheduleTemperaturePush()
                }

                Text("\(store.climateTemperature)")
                    .font(.system(size: 78, weight: .ultraLight, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(store.climateOn ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                    // 全 App 只有这里用裸「°」：78pt 的目标温度旁边再挂个 C 会打断视觉，
                    // 而且这个符号是手动定位到右上角的，位置本来就对。
                    // 其余所有温度读数都写「°C」，见 HomeView 里的说明。
                    .overlay(alignment: .topTrailing) {
                        Text("°")
                            .font(.system(size: 28, weight: .light))
                            .foregroundStyle(.secondary)
                            .offset(x: 20, y: 10)
                    }
                    .animation(.snappy, value: store.climateTemperature)
                    .accessibilityLabel("设定温度")
                    .accessibilityValue("\(store.climateTemperature) 摄氏度")

                stepButton(systemImage: "plus", label: "升高温度") {
                    store.climateTemperature = min(32, store.climateTemperature + 1)
                    scheduleTemperaturePush()
                }
            }

            // 无障碍字号下两条并排放不下，「°C」会被挤到下一行去，改成竖排。
            ambientReadings
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
    }

    @ViewBuilder
    private var ambientReadings: some View {
        let indoor = store.state?.indoorTemp.map {
            Label("车内 \(LeapFormat.temperature($0)) °C", systemImage: "car.fill")
        }
        let outdoor = store.state?.outdoorTemp.map { Label("车外 \(Int($0)) °C", systemImage: "thermometer.medium") }
        if isAccessibilitySize {
            VStack(spacing: 6) { indoor; outdoor }
        } else {
            HStack(spacing: 14) { indoor; outdoor }
        }
    }

    /// 松手 0.8 秒后再下发，避免连点 +/- 打出一串远控请求。
    private func scheduleTemperaturePush() {
        temperaturePush?.cancel()
        temperaturePush = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            store.pushClimateIfRunning()
        }
    }

    private var stateLine: String {
        guard store.climateOn else { return "空调已关闭 · 保留上次设定" }
        // 只有车真报上来的模式才敢写进这句。读不到就只说「运行中」，
        // 不拿本机草稿冒充车上正在跑的模式。
        guard let mode = confirmedMode else { return "空调运行中" }
        return "空调运行中 · \(mode.label)"
    }

    /// 车况里能确认的模式。读不到返回 nil。
    private var confirmedMode: ClimateMode? {
        if let mode = store.state?.climateMode { return mode }
        return store.state?.acAutoMode == true ? .auto : nil
    }

    /// 这一档要不要高亮。
    ///
    /// 车说了算：能确认就按车上的；车明确说「不在自动」时，哪怕本机草稿是自动也不许高亮——
    /// 用户点了「自动」车却没接受，界面还亮着自动，那就是在骗人。
    /// 剩下确实无从确认的（手动时的冷热），才退回本机草稿。
    private func isSelected(_ mode: ClimateMode) -> Bool {
        if let confirmed = confirmedMode { return confirmed == mode }
        if store.state?.acAutoMode == false, mode == .auto { return false }
        return store.climateMode == mode
    }

    /// 模式选择器下面那句：说清楚高亮的那一档是车报的还是本机记的。
    ///
    /// C11 只报「自动 / 手动」，冷热一次都没报过。不说明的话，用户会以为
    /// 「App 高亮着制冷」等于「车上正在制冷」。
    @ViewBuilder
    private var modeNotice: some View {
        if store.climateOn, store.state?.acModeRaw == nil {
            Text(store.state?.acAutoMode == nil
                 ? "这台车不上报空调模式，上面选中的是本机记录的上次设定。"
                 : "这台车只上报是不是自动模式，制冷还是制热它不报——那两档高亮的是本机记录。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
        }
    }

    /// 只有图标没有文字的按钮，VoiceOver 念的是字形名（「加号」），所以标签必须手写。
    private func stepButton(
        systemImage: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .medium))
                .frame(width: 54, height: 54)
                .contentShape(.circle)
        }
        .leapGlassButton()
        .clipShape(.circle)
        .accessibilityLabel(label)
        .sensoryFeedback(.selection, trigger: store.climateTemperature)
    }

    // MARK: - 模式

    /// 无障碍字号下「制冷 / 制热 / 自动」三段并排会各折成两行，
    /// 把胶囊撑到 250 点高、占掉四分之一屏。到那个字号就改成竖排三行。
    private var modePicker: some View {
        LeapGlassContainer(spacing: 10) {
            Group {
                if isAccessibilitySize {
                    VStack(spacing: 4) { modeButtons }
                } else {
                    HStack(spacing: 6) { modeButtons }
                }
            }
            .padding(5)
            // 竖排时不能再用胶囊：三行高的胶囊会鼓成一个大椭圆，两头空一片。
            // 两个分支的形状类型不同，得用 AnyShape 抹平。
            .leapGlass(.regular, in: isAccessibilitySize
                         ? AnyShape(.rect(cornerRadius: LeapStyle.cardRadius))
                         : AnyShape(.capsule))
        }
        .animation(.snappy, value: store.climateMode)
    }

    @ViewBuilder
    private var modeButtons: some View {
        ForEach(ClimateMode.allCases) { mode in
            Button {
                store.climateMode = mode
                store.pushClimateIfRunning()
            } label: {
                Label(mode.label, systemImage: mode.symbol)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .foregroundStyle(isSelected(mode) ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .background {
                if isSelected(mode) {
                    if isAccessibilitySize {
                        RoundedRectangle(cornerRadius: 18).fill(.primary.opacity(0.14))
                    } else {
                        Capsule().fill(.primary.opacity(0.14))
                    }
                }
            }
            .accessibilityAddTraits(isSelected(mode) ? [.isButton, .isSelected] : .isButton)
        }
    }

    // MARK: - 风量

    private var fanControl: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    CardLabel(text: "风量")
                    Spacer()
                    Text("\(store.climateFanLevel) 档")
                        .font(.caption.weight(.medium))
                }
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(1...7, id: \.self) { level in
                        Button {
                            store.climateFanLevel = level
                            store.pushClimateIfRunning()
                        } label: {
                            // 上方留白把柱子压到底部对齐，形成递增的阶梯。
                            VStack(spacing: 0) {
                                Color.clear.frame(height: 44 - (12 + CGFloat(level) * 4.5))
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(level <= store.climateFanLevel
                                          ? (store.climateOn ? LeapStyle.cool : LeapStyle.mutedFill)
                                          : Color.primary.opacity(0.12))
                                    .frame(height: 12 + CGFloat(level) * 4.5)
                            }
                            .frame(maxWidth: .infinity)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(height: 44)
                .animation(.snappy, value: store.climateFanLevel)
                .sensoryFeedback(.selection, trigger: store.climateFanLevel)
                // 七根光秃秃的色柱在 VoiceOver 里全都念作「按钮」，一模一样，没法用。
                // 合成一个可调元素：上下轻扫加减档位，跟系统音量条一个用法。
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("风量")
                .accessibilityValue("\(store.climateFanLevel) 档")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: store.climateFanLevel = min(7, store.climateFanLevel + 1)
                    case .decrement: store.climateFanLevel = max(1, store.climateFanLevel - 1)
                    @unknown default: return
                    }
                    store.pushClimateIfRunning()
                }
            }
        }
    }

    // MARK: - 循环模式

    /// 这里原来还并排放着一张「自动温控 / 手动温控」卡（车况字段 `acTempMode`）。
    /// 它是只读的——`cmdid 170` 的 state 只有 operate/temperature/windlevel/mode/circle/wshld/position
    /// 七个字段，demo 里 `operate` 只出现过 `manual` 和 `off`，没有切换温控模式的入口。
    /// 但它长得和旁边可点的「内循环」一模一样，用户点了没反应只会以为是坏了，所以撤掉。
    ///
    /// 上色的条件带上 `climateOn`：空调关着的时候温度数字是灰的、风量柱是灰的，
    /// 这张卡再亮着蓝色就成了整页唯一还带色的控件，看上去像空调其实开着。
    /// 内循环的设定值仍然保留（和温度、风量一样是"下次开机用的设定"），只是不再高亮。
    private var circulationRow: some View {
        let active = store.climateOn && store.climateCircleIn
        return GlassActionCard(radius: LeapStyle.tileRadius, tint: active ? LeapStyle.cool : nil) {
            store.climateCircleIn.toggle()
            store.pushClimateIfRunning()
        } content: {
            VStack(alignment: .leading, spacing: 6) {
                Label(store.climateCircleIn ? "内循环" : "外循环",
                      systemImage: store.climateCircleIn ? "arrow.triangle.2.circlepath" : "wind")
                    .font(.subheadline.weight(.medium))
                Text("轻点切换")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 快捷动作

    private var quickActions: some View {
        HStack(spacing: 10) {
            quickAction(title: "快速降温", systemImage: "snowflake", tint: LeapStyle.cool) {
                store.quickCool()
            }
            quickAction(title: "快速制热", systemImage: "flame.fill", tint: LeapStyle.warm) {
                store.quickHeat()
            }
            quickAction(title: "除霜", systemImage: "windshield.front.and.wiper", tint: LeapStyle.frost) {
                store.defrost()
            }
            quickAction(title: "除味", systemImage: "wind", tint: LeapStyle.accent) {
                store.deodorize()
            }
        }
        .commandBusy(store.isSendingCommand)
    }

    /// 四个按钮等宽：宽度约束加在 Button 上，图标在上文字在下，中文不会被挤断。
    private func quickAction(
        title: String,
        systemImage: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .medium))
                Text(title)
                    .font(.caption)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
        .leapGlassButton()
        .tint(tint)
        .frame(maxWidth: .infinity)
    }
}
