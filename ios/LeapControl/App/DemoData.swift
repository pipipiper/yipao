#if DEBUG
import Foundation

/// 仅用于本地预览界面：真实链路需要零跑账号 + 短信验证码，
/// 带 `-demo` 启动参数时用一份固定车况把 UI 跑起来，不会发出任何网络请求。
enum DemoData {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-demo")
    }

    /// `-screen climate|charge|map|parking|settings|ble|windows|trunk|cabin|fridge|climateplan|charging|roof|unlocked|features` 直接打开某一屏。
    static var initialScreen: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-screen"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    /// 数据在 `ReviewDemo` 里——演示账号在 Release 构建也要能用，
    /// 而这个文件整个是 Debug 限定的。这里只做转发，免得两处数据慢慢跑偏。
    static var session: LeapSession { ReviewDemo.session }

    static var vehicleState: VehicleState {
        var state = ReviewDemo.vehicleState
        // 舒适座舱 / 车载冰箱 / 充电控制的本地核对：**只在** `-screen cabin|fridge|charging` 时叠一层信号。
        // 不写进 `ReviewDemo`——那份在 Release 下也给 App 审核用，演示车立的是 C11，
        // 凭空给它加二排座椅和冰箱就是在造车况。值取自一台 C16 的真实信号 ID，
        // 档位是随手摆的几种状态（有开有关），方便一屏看全。
        switch initialScreen {
        case "cabin":
            state.signalMap.merge([
                "2100": "3", "2101": "0",   // 主驾加热 3 档
                "2118": "1", "2119": "2",   // 副驾加热 1 档、通风 2 档
                "1879": "0", "3727": "0",
                "1880": "2", "3728": "0",   // 二排右加热 2 档
                "1816": "1", "1624": "12",  // 方向盘弱档，约剩 12 分钟
                "49": "1", "50": "1", "1946": "1"
            ]) { _, new in new }
        case "fridge":
            state.signalMap.merge([
                "10709": "1", "10708": "0", "10707": "4", "10711": "0", "10712": "0",
                "11190": "1", "11189": "2", "11191": "0",
                "11260": String(Int(Date.now.timeIntervalSince1970) + 2 * 3600)
            ]) { _, new in new }
        case "charging":
            // 插着慢充枪、没在充：能源页应该摆出「开始充电」+「解锁充电枪」。
            state.signalMap.merge(["47": "1", "1149": "0"]) { _, new in new }
        case "features":
            // 功能页：把座舱、冰箱信号都叠上，让「座舱」组两个入口都出来，看全 8 项（要带 `-lab`）。
            state.signalMap.merge([
                "2100": "0", "2101": "0", "2118": "0", "2119": "0",
                "1816": "0", "49": "0", "50": "0",
                "10709": "0", "10708": "0", "10707": "4"
            ]) { _, new in new }
        case "unlocked":
            // 首页控车条：车没锁时「解锁」那格亮琥珀色、「上锁」不上色。
            state.signalMap.merge(["1298": "0"]) { _, new in new }
        case "roof":
            // 首页天窗 / 遮阳帘徽章：天窗开到底（1718=10）、遮阳帘全开（1724=100），右后窗开着。
            state.signalMap.merge(["1718": "10", "1724": "100", "1696": "2"]) { _, new in new }
        default:
            break
        }
        return state
    }
}

import SwiftUI

/// 把 `-screen` 指定的页面直接推到最前，仅用于本地逐屏核对。
struct DemoScreenHost: View {
    var screen: String
    @State private var showWindows = false
    @State private var trunkSheetHeight: CGFloat = 200

    var body: some View {
        NavigationStack {
            switch screen {
            case "password":
                HomeView()
                    .sheet(isPresented: .constant(true)) {
                        OperationPasswordSheet(prompt: "解锁")
                            .presentationDetents([.height(520)])
                            .presentationBackground(.clear)
                    }
            case "widget": WidgetGalleryView()
            case "widgetlarge": WidgetGalleryView(focus: .large)
            case "widgetlock": WidgetGalleryView(focus: .lock)
            case "widgetcharge": WidgetGalleryView(focus: .charging)
            case "widgetsetup": WidgetControlSetupView()
            case "lockscreen": LockScreenControlSetupView()
            case "actionbutton": ActionButtonGuideView()
            case "climate": CabinClimateView()
            case "charge": ChargeView()
            case "map": VehicleLocationView()
            case "parking": ParkingPhotosPreviewView()
            case "settings": SettingsView()
            case "trips": MileageStatsView()
            case "cabin": CabinClimateView(initialTab: .comfort)
            case "climateplan": ClimateAppointmentView()
            case "charging": ChargeView()
            case "fridge": FridgeView()
            case "features": FeatureCenterView(path: .constant([]))
            case "trunk":
                HomeView()
                    .sheet(isPresented: .constant(true)) {
                        TrunkControlSheet()
                            // 和真实那条路径一样按内容量高度：写死的话大字号下
                            // 核对屏会把按钮裁掉，看到的就不是真机上的样子了。
                            .fittedSheetHeight($trunkSheetHeight)
                            .presentationDragIndicator(.visible)
                            .presentationBackground(.regularMaterial)
                    }
            case "tires":
                HomeView()
                    .sheet(isPresented: .constant(true)) {
                        TirePressureSheet()
                            .presentationDetents([.height(330)])
                            .presentationDragIndicator(.visible)
                            .presentationBackground(.regularMaterial)
                    }
            default:
                HomeView()
                    .sheet(isPresented: $showWindows) {
                        WindowControlSheet()
                            // 写死高度的话，核对用的这一屏和真机上那一屏会慢慢跑偏。
                            .presentationDetents([
                                .height(WindowControlSheet.sheetHeight(carType: DemoData.session.selectedCarType))
                            ])
                            .presentationDragIndicator(.visible)
                            .presentationBackground(.regularMaterial)
                    }
                    .onAppear { if screen == "windows" { showWindows = true } }
            }
        }
    }
}

/// 按真实尺寸摆出各规格卡片，用来核对排版。桌面上的卡片由扩展进程渲染，
/// 这里只是同一套视图在 App 内的镜像。
struct WidgetGalleryView: View {
    /// 单独核对某一种卡片。整页一起看的时候要滚很久，够不着最下面那几张。
    enum Focus { case large, lock, charging }

    /// `-screen widgetlarge` / `-screen widgetlock` / `-screen widgetcharge`
    /// 各盯一种，nil 就是全都摆出来。
    var focus: Focus?
    private let snapshot = VehicleSnapshot.placeholder
    /// 卡片读的是 App Group 里那张。演示态没有车图（不下载资源），
    /// 所以这里为 nil，几张样品都会退回剪影——想核对带车图的排版，
    /// 先用真实账号跑一次首页把它写出来。
    @State private var carImage: Image?

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                if focus == nil {
                    sample("小尺寸", width: 165, height: 165) {
                        SmallVehicleWidgetPreview(snapshot: snapshot)
                    }
                    sample("中尺寸", width: 345, height: 165) {
                        MediumVehicleWidgetPreview(snapshot: snapshot)
                    }
                    // 车端没报锁状态时，这张和下面那张「只管锁车 · 状态未知」要说同一句话。
                    // 判据分叉过一次：这张画绿色闭锁（等于说「锁好了」），那张显示「状态未知」。
                    sample("中尺寸 · 锁状态未知", width: 345, height: 165) {
                        MediumVehicleWidgetPreview(snapshot: Self.snapshot(snapshot, isLocked: nil))
                    }
                }
                if focus == nil || focus == .lock {
                    HStack(spacing: 12) {
                        sample("上锁车辆", width: 165, height: 165) {
                            LockWidgetPreview(snapshot: snapshot, carImage: carImage, action: .lock)
                        }
                        sample("解锁车辆", width: 165, height: 165) {
                            LockWidgetPreview(snapshot: snapshot, carImage: carImage, action: .unlock)
                        }
                    }
                    // 单功能卡片各种状态一起摆。要核对两件事：徽标和淡底色能不能一眼分清，
                    // 以及取不到车图时退回的剪影是不是也立得住（3D 资源没下完、
                    // 关了「显示车模型」、演示态都会走到那一支）。
                    sample("单功能锁车 · 已锁", width: 165, height: 165) {
                        LockWidgetPreview(snapshot: snapshot, carImage: carImage)
                    }
                    sample("单功能锁车 · 已解锁", width: 165, height: 165) {
                        LockWidgetPreview(
                            snapshot: Self.snapshot(snapshot, isLocked: false),
                            carImage: carImage
                        )
                    }
                    sample("单功能锁车 · 车窗未关", width: 165, height: 165) {
                        LockWidgetPreview(
                            snapshot: Self.snapshot(snapshot, isLocked: true, windowsClosed: false),
                            carImage: carImage
                        )
                    }
                    sample("单功能锁车 · 尾门未关", width: 165, height: 165) {
                        LockWidgetPreview(
                            snapshot: Self.snapshot(snapshot, isLocked: true, trunkOpen: true),
                            carImage: carImage
                        )
                    }
                    sample("单功能锁车 · 状态未知", width: 165, height: 165) {
                        LockWidgetPreview(
                            snapshot: Self.snapshot(snapshot, isLocked: nil),
                            carImage: carImage
                        )
                    }
                    sample("单功能锁车 · 无车图（剪影）", width: 165, height: 165) {
                        LockWidgetPreview(snapshot: snapshot)
                    }
                }
                if focus == nil || focus == .large {
                    sample("大尺寸", width: 345, height: 345) {
                        LargeVehicleWidgetPreview(snapshot: snapshot, carImage: carImage)
                    }
                    // 尾门开着时那颗键要亮起来，和 App 内快控条同一个判据。
                    sample("大尺寸 · 尾门未关", width: 345, height: 345) {
                        LargeVehicleWidgetPreview(
                            snapshot: Self.snapshot(snapshot, isLocked: true, trunkOpen: true),
                            carImage: carImage
                        )
                    }
                }
                if focus == nil || focus == .charging {
                    // 「剩余时间 · 功率」那行是 `if snapshot.isCharging` 包着的，
                    // 车没插枪时整行不出现——不摆一份充电态就根本核对不到它的排版。
                    sample("小尺寸 · 充电中", width: 165, height: 165) {
                        SmallVehicleWidgetPreview(snapshot: Self.charging(snapshot))
                    }
                    // 小卡右上角那一格有两种样子，都得核对：有功率就显示功率，
                    // 读不到才退回闪电图标。剩余时间读不到时下面那行整行不摆。
                    sample("小尺寸 · 充电中 · 只有功率", width: 165, height: 165) {
                        SmallVehicleWidgetPreview(snapshot: Self.charging(snapshot, remainMinutes: nil))
                    }
                    sample("小尺寸 · 充电中 · 只有剩余时间", width: 165, height: 165) {
                        SmallVehicleWidgetPreview(snapshot: Self.charging(snapshot, powerKW: nil))
                    }
                    // 快充三位数功率，右上角那行最挤的情况——「充电功率」四个字加上它，
                    // 和车名抢的就是同一条横线。
                    sample("小尺寸 · 充电中 · 快充 120.5 kW", width: 165, height: 165) {
                        SmallVehicleWidgetPreview(snapshot: Self.charging(snapshot, powerKW: 120.5))
                    }
                    sample("中尺寸 · 充电中", width: 345, height: 165) {
                        MediumVehicleWidgetPreview(snapshot: Self.charging(snapshot))
                    }
                    sample("大尺寸 · 充电中", width: 345, height: 345) {
                        LargeVehicleWidgetPreview(
                            snapshot: Self.charging(snapshot),
                            carImage: carImage
                        )
                    }
                }
            }
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity)
        }
        .background { LeapBackground(tint: LeapStyle.accent) }
        .navigationTitle("桌面卡片")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            carImage = CarImageCache.shared().map { Image(uiImage: $0) }
        }
    }

    /// 复制一份快照，只改门窗相关的那几项——单功能卡片每种状态各要一份。
    private static func snapshot(
        _ base: VehicleSnapshot,
        isLocked: Bool?,
        windowsClosed: Bool? = nil,
        trunkOpen: Bool? = nil
    ) -> VehicleSnapshot {
        var copy = base
        copy.isLocked = isLocked
        if let windowsClosed { copy.windowsClosed = windowsClosed }
        if let trunkOpen { copy.trunkOpen = trunkOpen }
        return copy
    }

    /// 充电中的那一份。默认两项都给实值，核对的才是排得最挤的那种情况；
    /// 传 nil 进来就是车端没报那一项，用来核对少一项时各处怎么退。
    private static func charging(
        _ base: VehicleSnapshot,
        remainMinutes: Int? = 95,
        powerKW: Double? = 41.6
    ) -> VehicleSnapshot {
        var copy = base
        copy.isCharging = true
        copy.chargeRemainMinutes = remainMinutes
        copy.chargePowerKW = powerKW
        return copy
    }

    private func sample<Content: View>(
        _ title: String,
        width: CGFloat,
        height: CGFloat,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
                // 不在这里补内边距：预览走的就是 VehicleWidgetView，内边距由它自己给，
                // 这样画廊里量到的就是桌面上的真实间距。
                .frame(width: width, height: height)
                .background(.regularMaterial, in: .rect(cornerRadius: 24))
        }
    }
}
#endif
