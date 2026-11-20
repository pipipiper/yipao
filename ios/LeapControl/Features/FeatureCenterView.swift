import SwiftUI

enum ControlFeature: String, CaseIterable, Identifiable, Hashable {
    case actionButton
    case lockScreen
    case widgets
    case bluetoothKey
    case batteryPreheat
    case chargePlan
    case chargingHistory
    case comfortCabin
    case fridge

    enum Group: String, CaseIterable {
        case access = "快捷控车"
        case cabin = "座舱"
        case energy = "能源"
    }

    var id: String { rawValue }

    var group: Group {
        switch self {
        case .actionButton, .lockScreen, .widgets, .bluetoothKey: .access
        case .comfortCabin, .fridge: .cabin
        case .batteryPreheat, .chargePlan, .chargingHistory: .energy
        }
    }

    var title: String {
        switch self {
        case .actionButton: "侧边按钮"
        case .lockScreen: "锁屏控件"
        case .widgets: "桌面小组件"
        case .bluetoothKey: "蓝牙钥匙"
        case .batteryPreheat: "电池预热"
        case .chargePlan: "充电计划"
        case .chargingHistory: "充电记录"
        case .comfortCabin: "舒适座舱"
        case .fridge: "车载冰箱"
        }
    }

    var detail: String {
        switch self {
        case .actionButton: "按住快速控车"
        case .lockScreen: "锁屏与控制中心"
        case .widgets: "主屏快速控车"
        case .bluetoothKey: "近车直连与无感解锁"
        case .batteryPreheat: "立即或预约加热"
        case .chargePlan: "预约时段、目标电量与循环日"
        case .chargingHistory: "周、月、年统计与明细"
        case .comfortCabin: "座椅加热通风、方向盘与后视镜"
        case .fridge: "制冷保温与离车保持"
        }
    }

    var symbol: String {
        switch self {
        case .actionButton: "button.programmable"
        case .lockScreen: "lock.rectangle"
        case .widgets: "square.grid.2x2"
        case .bluetoothKey: "key.radiowaves.forward.fill"
        case .batteryPreheat: "thermometer.high"
        case .chargePlan: "bolt.badge.clock"
        case .chargingHistory: "clock.arrow.circlepath"
        case .comfortCabin: "carseat.right.fill"
        case .fridge: "refrigerator.fill"
        }
    }

    static let hiddenFromCatalog: Set<ControlFeature> = []

    /// 功能页上真正摆出来的那些格子。
    static var catalog: [ControlFeature] {
        allCases.filter { !hiddenFromCatalog.contains($0) }
    }
}

/// 功能页（2026-11-19 重做两轮）。
///
/// 原先是一个功能一张 152pt 高的大玻璃卡，图标外再套玻璃圆框，10 个功能就是 10 个大框、
/// 滑好几屏。先改成「一组一张卡、卡里 4 列图标」，车主装上手机后嫌太空（去掉直进直出和
/// 驻车照片后只剩 7 个，4 列压得太紧，下半屏一大片空）；对比三版稿后定成现在这样：
/// **一组一张卡，卡里两列，每格是「图标 + 名字 + 一行说明」**。每行都能排满，说明文字也回来了。
///
/// 顶部只留一个会随滚动收进导航栏的大标题，原来叠着的「控车中心」和车名那行去掉了——
/// 车名首页已经有。
///
/// 同日去掉「车辆」组：「直进直出」整个下线（只删入口和页面，蓝牙底层
/// `CallCarController` 等留着，想恢复把入口加回来即可）；「驻车照片」地图页位置卡上已经有，
/// 这里不再重复一个入口。
struct FeatureCenterView: View {
    @Environment(VehicleStore.self) private var store
    @Binding var path: [ControlFeature]

    var body: some View {
        ZStack {
            LeapBackground(tint: LeapStyle.frost)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if !showsLabCatalog {
                        reviewSafeControls
                    } else {
                        // 整组都被挡掉时连标题一起不出现，否则会剩一个底下什么都没有的小标题。
                        ForEach(ControlFeature.Group.allCases.filter { group in
                            visibleCatalog.contains { $0.group == group }
                        }, id: \.self) { group in
                            FeatureGroupCard(title: group.rawValue) {
                                ForEach(visibleCatalog.filter { $0.group == group }) { feature in
                                    NavigationLink(value: feature) {
                                        FeatureGridCell(title: feature.title, detail: feature.detail, symbol: feature.symbol)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle("功能")
        .navigationBarTitleDisplayMode(.large)
    }

    /// 这台车真摆得出来的格子。
    ///
    /// 舒适座舱和车载冰箱按车走：车况信号在场、或能力码有，才给入口
    /// （判据见 `VehicleStore.cabinComfortSupported` / `fridgeSupported`）。
    /// 车主那台 C16 没装冰箱，这个格子在他车上整个不出现——照「读不到就别显示」，
    /// 而不是摆一个点进去一片空白的入口。
    private var visibleCatalog: [ControlFeature] {
        ControlFeature.catalog.filter { feature in
            switch feature {
            case .comfortCabin: store.cabinComfortSupported
            case .fridge: store.fridgeSupported
            default: true
            }
        }
    }

    /// 审核演示账号不展示未发布能力，但功能标签仍保留为纯控车入口。和正式目录同一套宫格。
    private var reviewSafeControls: some View {
        FeatureGroupCard(title: "常用功能") {
            NavigationLink {
                ClimateView().toolbar(.hidden, for: .tabBar)
            } label: {
                FeatureGridCell(title: "空调", detail: "温度、模式与风量", symbol: "fan.fill")
            }
            NavigationLink {
                ChargeView().toolbar(.hidden, for: .tabBar)
            } label: {
                FeatureGridCell(title: "能源", detail: "电量、续航与充电状态", symbol: "bolt.fill")
            }
            NavigationLink {
                VehicleLocationView().toolbar(.hidden, for: .tabBar)
            } label: {
                FeatureGridCell(title: "车辆位置", detail: "位置与导航", symbol: "location.fill")
            }
        }
        .buttonStyle(.plain)
    }

    /// App Review 演示账号不暴露尚未发布的能力；本地截图可显式带 `-lab` 核对全目录。
    private var showsLabCatalog: Bool {
        #if DEBUG
        return !store.isDemo || ProcessInfo.processInfo.arguments.contains("-lab")
        #else
        return !store.isDemo
        #endif
    }
}

/// 一组功能：小标题 + 一张玻璃卡，卡里两列。
private struct FeatureGroupCard<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    private let columns = [GridItem(.flexible(), spacing: 0), GridItem(.flexible(), spacing: 0)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 6)
                .accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: columns, spacing: 0) {
                content
            }
            .padding(4)
            .leapGlass(.regular, in: .rect(cornerRadius: LeapStyle.tileRadius))
        }
    }
}

/// 卡里的一格：图标在左，名字和一行说明在右。图标不套圆框，框里不再套框。
private struct FeatureGridCell: View {
    var title: String
    var detail: String
    var symbol: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(LeapStyle.accent)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

struct ControlFeatureDestination: View {
    var feature: ControlFeature

    @ViewBuilder
    var body: some View {
        Group {
            switch feature {
            case .actionButton: ActionButtonGuideView()
            case .lockScreen: LockScreenControlSetupView()
            case .widgets: WidgetControlSetupView()
            case .bluetoothKey: BluetoothFeatureOverview()
            case .batteryPreheat: BatteryPreheatPreviewView()
            case .chargePlan: ChargePlanPreviewView()
            case .chargingHistory: ChargingHistoryView()
            case .comfortCabin: ComfortCabinView()
            case .fridge: FridgeView()
            }
        }
        .toolbar(.hidden, for: .tabBar)
    }
}

struct FeatureAvailabilityBanner: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "hammer.fill")
                .foregroundStyle(LeapStyle.cool)
            VStack(alignment: .leading, spacing: 2) {
                Text("暂未接入")
                    .font(.subheadline.weight(.semibold))
                Text("只能预览操作页面，不会向车辆发送指令")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .leapGlass(.regular.tint(LeapStyle.cool.opacity(0.14)),
                   in: .rect(cornerRadius: LeapStyle.tileRadius))
    }
}
