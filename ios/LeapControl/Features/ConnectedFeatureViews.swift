import SwiftUI
import UIKit
import WidgetKit

struct ActionButtonGuideView: View {
    @Environment(VehicleStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isPressing = false
    @State private var selectedControl = 0

    private let controls: [(title: String, symbol: String, tint: Color)] = [
        ("上锁车辆", ControlActivityAction.lock.symbol, LeapStyle.accent),
        ("解锁车辆", ControlActivityAction.unlock.symbol, LeapStyle.caution),
        ("车锁", "car.side.lock.fill", LeapStyle.accent),
        ("鸣笛寻车", "speaker.wave.2.fill", LeapStyle.cool)
    ]

    var body: some View {
        @Bindable var store = store
        ZStack {
            LeapBackground(tint: LeapStyle.cool)
            ScrollView {
                VStack(spacing: 20) {
                    actionButtonVisual
                    GlassCard {
                        Toggle(isOn: $store.widgetControlEnabled) {
                            Label("允许侧边按钮直接控车", systemImage: "button.programmable")
                        }
                        .tint(LeapStyle.accent)
                        .disabled(!SnapshotStore.hasSharedContainer || (!store.widgetControlEnabled && !store.hasSavedPassword))
                    }
                    setupTimeline
                    limitationNote
                }
                .padding(16)
                .padding(.bottom, 24)
            }
        }
        .navigationTitle("侧边按钮")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: reduceMotion) {
            guard !reduceMotion else {
                isPressing = false
                return
            }

            // 只循环长按演示，不代用户切换控制；选哪个由下方胶囊手动决定。
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(0.8))
                withAnimation(.easeInOut(duration: 0.45)) {
                    isPressing = true
                }
                try? await Task.sleep(for: .seconds(1.1))
                withAnimation(.snappy(duration: 0.45)) {
                    isPressing = false
                }
                try? await Task.sleep(for: .seconds(1.0))
            }
        }
    }

    private var actionButtonVisual: some View {
        VStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 46, style: .continuous)
                    .fill(.primary.opacity(0.08))
                    .overlay {
                        RoundedRectangle(cornerRadius: 46, style: .continuous)
                            .stroke(.primary.opacity(0.14), lineWidth: 1)
                    }
                    .frame(width: 184, height: 306)

                VStack(spacing: 18) {
                    ZStack {
                        Circle()
                            .fill(controls[selectedControl].tint.opacity(isPressing ? 0.22 : 0.10))
                            .frame(width: isPressing ? 98 : 82, height: isPressing ? 98 : 82)
                            .shadow(
                                color: controls[selectedControl].tint.opacity(isPressing ? 0.65 : 0),
                                radius: isPressing ? 24 : 0
                            )

                        Image(systemName: isPressing ? controls[selectedControl].symbol : "switch.2")
                            .font(.system(size: isPressing ? 32 : 30, weight: .semibold))
                            .foregroundStyle(controls[selectedControl].tint)
                            .contentTransition(.symbolEffect(.replace))
                    }

                    Text(isPressing ? controls[selectedControl].title : "控制")
                        .font(.subheadline.weight(.semibold))
                        .contentTransition(.numericText())
                }

                Capsule()
                    .fill(controls[selectedControl].tint)
                    .frame(width: isPressing ? 10 : 7, height: isPressing ? 72 : 54)
                    .offset(x: -92, y: -60)
                    .shadow(
                        color: controls[selectedControl].tint.opacity(isPressing ? 0.9 : 0.35),
                        radius: isPressing ? 16 : 7
                    )
                    .scaleEffect(y: isPressing ? 0.88 : 1)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("长按侧边按钮，打开壹跑车辆控制")

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                controlOptions
            }

            Text("长按侧边按钮 · 打开车辆控制")
                .font(.headline)
        }
        .padding(.vertical, 16)
        // 手机轮廓是示意模型，不承载正文；限制字号避免辅助字体挤破固定尺寸的模型。
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    @ViewBuilder
    private var controlOptions: some View {
        ForEach(Array(controls.enumerated()), id: \.offset) { index, control in
            Button {
                withAnimation(.snappy(duration: 0.35)) {
                    selectedControl = index
                }
            } label: {
                Label(control.title, systemImage: control.symbol)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                    .foregroundStyle(index == selectedControl ? Color.primary : Color.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .fill(control.tint.opacity(index == selectedControl ? 0.14 : 0.04))
                    )
                    .overlay {
                        Capsule()
                            .stroke(control.tint.opacity(index == selectedControl ? 0.28 : 0.08))
                    }
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(index == selectedControl ? .isSelected : [])
        }
    }

    private var setupTimeline: some View {
        VStack(alignment: .leading, spacing: 0) {
            setupStep(1, "打开系统设置", detail: "点下方按钮，到设置首页后选“操作按钮”")
            setupStep(2, "选择“控制”", detail: "滑动到控制，而不是快捷指令")
            setupStep(3, "选择壹跑", detail: "上锁车辆、解锁车辆、车锁或鸣笛寻车", showsLine: false)

            Button(action: openSystemSettings) {
                Label("打开系统设置", systemImage: "arrow.up.forward.app.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(LeapStyle.cool)
            .padding(.top, 14)
        }
        .padding(16)
        .leapGlass(.regular, in: .rect(cornerRadius: LeapStyle.tileRadius))
    }

    private func openSystemSettings() {
        // iOS 18 起三方 App 进不了「操作按钮」具体页（深链被系统降级），
        // 能承诺的只有设置首页——「操作按钮」就在首页第一屏。打不开再退到本 App 设置页。
        guard let url = URL(string: "App-prefs:") else { return }
        UIApplication.shared.open(url) { success in
            guard !success, let fallback = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(fallback)
        }
    }

    private func setupStep(_ number: Int, _ title: String, detail: String, showsLine: Bool = true) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Text("\(number)")
                    .font(.caption.weight(.bold))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(LeapStyle.cool.opacity(0.18)))
                if showsLine {
                    Rectangle().fill(.quaternary).frame(width: 1, height: 38)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.top, 4)
            Spacer()
        }
    }

    private var limitationNote: some View {
        Label {
            Text("Apple 要求操作按钮由用户在系统设置中选择，App 不能代改；选择一次后即可长按使用。")
                .font(.caption)
                .foregroundStyle(.secondary)
        } icon: {
            Image(systemName: "checkmark.shield.fill")
                .foregroundStyle(LeapStyle.accent)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .leapGlass(.regular, in: .rect(cornerRadius: LeapStyle.tileRadius))
    }
}

struct LockScreenControlSetupView: View {
    @Environment(VehicleStore.self) private var store

    var body: some View {
        @Bindable var store = store

        ZStack {
            LeapBackground(tint: LeapStyle.frost)
            ScrollView {
                VStack(spacing: 18) {
                    lockScreenPreview
                    GlassCard {
                        Toggle(isOn: $store.widgetControlEnabled) {
                            Label {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("允许锁屏直接控车")
                                    Text("操作车锁时由系统验证面容或设备密码")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "lock.shield.fill")
                            }
                        }
                        .tint(LeapStyle.accent)
                        .disabled(!SnapshotStore.hasSharedContainer || (!store.widgetControlEnabled && !store.hasSavedPassword))
                    }
                    availableControls
                }
                .padding(16)
                .padding(.bottom, 24)
            }
        }
        .navigationTitle("锁屏控件")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var lockScreenPreview: some View {
        VStack(spacing: 18) {
            Text("9:41")
                .font(.system(size: 56, weight: .thin, design: .rounded))
            Text("8月12日 星期三")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 28)
            HStack(spacing: 44) {
                lockScreenButton(ControlActivityAction.lock.symbol, label: "上锁车辆")
                lockScreenButton(ControlActivityAction.unlock.symbol, label: "解锁车辆")
            }
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, minHeight: 330)
        .leapGlass(.regular, in: .rect(cornerRadius: LeapStyle.cardRadius))
    }

    private func lockScreenButton(_ symbol: String, label: String) -> some View {
        VStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .frame(width: 54, height: 54)
                .background(Circle().fill(.primary.opacity(0.12)))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var availableControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("可选控件").font(.headline)
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 16) {
                Label("上锁车辆", systemImage: ControlActivityAction.lock.symbol)
                Label("解锁车辆", systemImage: ControlActivityAction.unlock.symbol)
                Label("车锁切换", systemImage: "car.side.lock.fill")
                Label("鸣笛寻车", systemImage: "speaker.wave.2.fill")
            }
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }
}

struct WidgetControlSetupView: View {
    @Environment(VehicleStore.self) private var store
    @State private var smallButtons = SharedSettings.widgetButtons(small: true)
    @State private var buttons = SharedSettings.widgetButtons(small: false)
    @State private var editingSize: WidgetFamily?
    @State private var editingIndex = 0
    @State private var carImage = CarImageCache.shared().map { Image(uiImage: $0) }

    private var snapshot: VehicleSnapshot {
        if let state = store.state {
            return .make(state: state, vehicleName: store.vehicleName, locationName: store.locationName, updatedAt: store.lastUpdated ?? .now)
        }
        return SnapshotStore().read() ?? VehicleSnapshot(
            vehicleName: store.vehicleName, soc: nil, gasolinePercent: nil, rangeKm: nil,
            isLocked: nil, isDriving: false, isCharging: false, chargeLimit: nil,
            chargeRemainMinutes: nil, chargePowerKW: nil, indoorTemp: nil, climateOn: false,
            windowsClosed: nil, anyDoorOpen: false, trunkOpen: nil, hasTireWarning: false,
            locationName: nil, latitude: nil, longitude: nil, updatedAt: .now, reportedAt: nil
        )
    }

    var body: some View {
        @Bindable var store = store

        ZStack {
            LeapBackground(tint: LeapStyle.accent)
          ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 18) {
                    sizePreview(.systemSmall, dimensions: "2×2 · 2 个按钮")
                    sizePreview(.systemMedium, dimensions: "4×2 · 中大共用 4 个按钮")
                    sizePreview(.systemLarge, dimensions: "4×4 · 中大共用 4 个按钮")

                    VStack(alignment: .leading, spacing: 12) {
                        Text("独立控车卡片").font(.subheadline.weight(.semibold))
                        HStack(spacing: 12) {
                            ForEach([WidgetAction.lock, .unlock], id: \.rawValue) { action in
                                LockWidgetPreview(snapshot: snapshot, carImage: carImage, action: action)
                                    .aspectRatio(1, contentMode: .fit)
                                    .clipShape(.rect(cornerRadius: 24))
                                    .allowsHitTesting(false)
                            }
                        }
                    }

                    GlassCard {
                        Toggle(isOn: $store.widgetControlEnabled) {
                            Label {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("卡片直接控车")
                                    Text(SnapshotStore.hasSharedContainer
                                         ? "关闭时先打开 App 完成验证"
                                         : "此签名版本的小组件显示只读车况")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "bolt.shield.fill")
                            }
                        }
                        .tint(LeapStyle.accent)
                        .disabled(!SnapshotStore.hasSharedContainer || (!store.widgetControlEnabled && !store.hasSavedPassword))
                    }

                    Label {
                        Text("长按主屏空白处，轻点添加按钮并搜索“壹跑”。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "square.grid.2x2")
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .leapGlass(.regular, in: .rect(cornerRadius: LeapStyle.tileRadius))
                }
                .frame(maxWidth: 420)
                .padding(16)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: editingSize) { _, size in
                guard let size else { return }
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(size, anchor: .top) }
            }
          }
        }
        .navigationTitle("桌面小组件")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func sizeTitle(_ size: WidgetFamily) -> String {
        switch size {
        case .systemSmall: "小卡片"
        case .systemMedium: "中卡片"
        default: "大卡片"
        }
    }

    private func edit(_ size: WidgetFamily, index: Int) {
        editingSize = size
        editingIndex = index
    }

    private func sizePreview(_ size: WidgetFamily, dimensions: String) -> some View {
        let actions = size == .systemSmall ? smallButtons : buttons
        let active = editingSize == size
        return VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(sizeTitle(size)).font(.subheadline.weight(.semibold))
                    Text(dimensions).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    if active { editingSize = nil } else { edit(size, index: 0) }
                } label: {
                    Image(systemName: active ? "checkmark" : "pencil").frame(width: 44, height: 44)
                }
                .tint(.primary)
                .accessibilityLabel(active ? "完成配置" : "配置\(sizeTitle(size))按钮")
            }
            VehicleWidgetView(snapshot: snapshot, carImage: carImage, familyOverride: size)
                .environment(\.widgetPreviewEditor, WidgetPreviewEditor(actions: actions, select: { action in
                    if let index = actions.firstIndex(of: action) { edit(size, index: index) }
                }, selected: active ? actions[editingIndex] : nil, move: { source, target in
                    moveButton(source, to: target, size: size)
                }))
                .frame(width: size == .systemSmall ? 170 : nil, height: size == .systemLarge ? 350 : 170)
                .frame(maxWidth: size == .systemSmall ? nil : .infinity)
                .background(.regularMaterial, in: .rect(cornerRadius: 24))
                .clipShape(.rect(cornerRadius: 24))
                .overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(.primary.opacity(0.06)) }
            if active {
                actionPicker(actions: actions, small: size == .systemSmall)
            }
        }
        .id(size)
    }

    private func actionPicker(actions: [WidgetAction], small: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("更换\(actions[editingIndex].title)").font(.subheadline.weight(.semibold))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(WidgetAction.allCases, id: \.rawValue) { action in
                    actionChoice(action, actions: actions, small: small)
                }
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private func actionChoice(_ action: WidgetAction, actions: [WidgetAction], small: Bool) -> some View {
        let selected = actions[editingIndex] == action
        let symbol = action == .toggleLock ? snapshot.lockSymbol :
            action == .trunk && snapshot.trunkOpen == true ? "car.side.rear.open" :
            action == .toggleClimate && snapshot.climateOn ? "fan.fill" : action.symbol
        return Button {
            saveButtons(WidgetButtonLayout.replacing(actions, at: editingIndex, with: action), small: small)
        } label: {
            VStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 22)).frame(height: 26)
                Text(action.title).font(.caption.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 78)
            .background(selected ? LeapStyle.accent.opacity(0.12) : Color.primary.opacity(0.04), in: .rect(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? LeapStyle.accent : Color.primary.opacity(0.10), lineWidth: selected ? 2 : 1) }
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 14))
                        .foregroundStyle(LeapStyle.accent).padding(5)
                }
            }
        }
        .buttonStyle(.plain)
        .tint(.primary)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func moveButton(_ source: WidgetAction, to target: WidgetAction, size: WidgetFamily) {
        let small = size == .systemSmall
        let actions = small ? smallButtons : buttons
        guard let from = actions.firstIndex(of: source), let to = actions.firstIndex(of: target) else { return }
        let next = WidgetButtonLayout.moving(actions, from: from, to: to)
        withAnimation(.snappy(duration: 0.2)) {
            saveButtons(next, small: small)
            editingSize = size
            editingIndex = to
        }
    }

    private func saveButtons(_ actions: [WidgetAction], small: Bool) {
        SharedSettings.setWidgetButtons(actions, small: small)
        if small { smallButtons = actions } else { buttons = actions }
    }
}

struct BluetoothFeatureOverview: View {
    @Environment(VehicleStore.self) private var store

    var body: some View {
        ZStack {
            LeapBackground(tint: LeapStyle.cool)
            ScrollView {
                VStack(spacing: 18) {
                    VStack(spacing: 14) {
                        Image(systemName: "key.radiowaves.forward.fill")
                            .font(.system(size: 48, weight: .light))
                            .foregroundStyle(LeapStyle.cool)
                            .frame(width: 110, height: 110)
                            .leapGlass(.regular.tint(LeapStyle.cool.opacity(0.16)), in: .circle)
                        Text(store.bleController.runtimeState.label)
                            .font(.title3.weight(.semibold))
                        Text("可信车辆绑定 · 近车直连 · 无感解闭锁")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 26)

                    NavigationLink {
                        BluetoothKeySettingsView()
                    } label: {
                        Label("进入蓝牙钥匙设置", systemImage: "arrow.right.circle.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .leapGlassButton(prominent: true)
                    .tint(LeapStyle.cool)
                }
                .padding(16)
            }
        }
        .navigationTitle("蓝牙钥匙")
        .navigationBarTitleDisplayMode(.inline)
    }
}
