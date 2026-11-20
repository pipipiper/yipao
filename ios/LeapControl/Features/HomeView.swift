import MapKit
import SwiftUI
import UIKit

/// 首页的地图缩略图。不可交互，点整张卡片进详情页。
struct LocationThumbnail: View {
    /// 车端原样的 **GCJ-02**，不转——大陆的 MapKit 底图就是 GCJ-02（见 `CoordinateTransform`）。
    var coordinate: CLLocationCoordinate2D?

    var body: some View {
        Group {
            if let coordinate {
                Map(
                    initialPosition: .region(MKCoordinateRegion(
                        center: coordinate,
                        span: MKCoordinateSpan(latitudeDelta: 0.004, longitudeDelta: 0.004)
                    )),
                    interactionModes: []
                ) {
                    Annotation("", coordinate: coordinate) {
                        Image(systemName: "car.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(LeapStyle.cool))
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                            .shadow(color: LeapStyle.cool.opacity(0.7), radius: 6)
                    }
                }
                .mapStyle(.standard(pointsOfInterest: .excludingAll))
                .allowsHitTesting(false)
            } else {
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: "location.slash")
                        .font(.system(size: 20))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

struct HomeView: View {
    /// 电量卡 / 空调卡顶行的高度。
    ///
    /// 空调卡那行里挂着一个 34 的电源按钮，电量卡只有一行 caption 标题。两边都垫到这个高度，
    /// 标题和底下的大数字才落在同一条线上——不垫的话空调卡整块被按钮往下推大半行，
    /// 「电量」和「车内温度」、「91」和「29」全都错开。
    ///
    /// 用 `minHeight` 不用固定 `height`：无障碍字号下标题自己会超过 34，
    /// 那时候宁可两张卡各自长高，也不能把字裁掉。
    private static let tileHeaderHeight: CGFloat = 34
    /// 电量卡 / 空调卡末行的高度。电量条只有 10 高，「空调设置」那行是 17，
    /// 给两边同一个下限并各自居中，末行的底边才对得齐。
    private static let tileFooterHeight: CGFloat = 18

    @Environment(VehicleStore.self) private var store
    @AppStorage("vehicleHomeTheme") private var homeTheme = VehicleHomeTheme.automatic
    @State private var showWindows = false
    @State private var showTrunk = false
    @State private var showSunshade = false
    @State private var showSunroof = false
    @State private var showFrunk = false
    @State private var showTires = false
    /// 尾门弹窗量出来的高度，给个接近真实值的初值，省得开合那一下高度先跳一次。
    @State private var trunkSheetHeight: CGFloat = 200
    /// 遮阳帘 / 天窗 / 前备箱三个弹层结构相同，共用一个量出来的高度。
    @State private var twoStateSheetHeight: CGFloat = 200
    /// 胎压弹窗量出来的高度。给个接近真实值的初值，省得开合那一下高度先跳一次。
    @State private var tireSheetHeight: CGFloat = 300
    /// 用 `NavigationPath` 而不是 `[HomeRoute]`。
    ///
    /// 同构路径（`[HomeRoute]`）下 SwiftUI 只认**根上**注册的 `navigationDestination`，
    /// 二级页自己注册的一概无效（日志里是那句「Only root-level navigation destinations
    /// are effective for a navigation stack with a homogeneous path.」）。异构路径下
    /// 二级页可以自己注册目的地。
    @State private var path = NavigationPath()
    @Namespace private var glassNamespace
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// 到了无障碍字号，横排的东西基本都放不下了，几处布局要换成竖排。
    private var isAccessibilitySize: Bool { dynamicTypeSize.isAccessibilitySize }

    private var state: VehicleState? { store.state }

    /// 背景色随车辆当前最显著的状态走。
    private var backgroundTint: Color {
        if let tint = homeTheme.tint { return tint }
        if state?.isCharging == true { return LeapStyle.accent }
        if store.climateOn { return store.climateMode == .hot ? LeapStyle.warm : LeapStyle.cool }
        return LeapStyle.cool
    }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                LeapBackground(tint: backgroundTint)

                // 高频控车属于车辆内容，而不是第二层导航。它跟着车辆舞台一起滚动，
                // 底部只保留系统 Tab Bar，小屏或大字号则自然滚动查看其余车况。
                GeometryReader { proxy in
                    ScrollView {
                        VStack(spacing: 12) {
                            dashboardHeader
                            VehicleHero(size: heroSize, badges: statusBadges)
                            QuickControlBar(
                                showTrunk: $showTrunk,
                                showSunshade: $showSunshade,
                                showSunroof: $showSunroof,
                                showFrunk: $showFrunk
                            )
                            summaryRow
                            statusStrip
                            locationCard
                            privacyNote
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, headerTopInset)
                        .padding(.bottom, 10)
                        .frame(minHeight: proxy.size.height, alignment: .top)
                    }
                    .scrollIndicators(.hidden)
                    .refreshable { await store.refresh(refreshConfig: true) }
                }
            }
            // 首页大标题在内容区里,系统那条空的内联导航栏只会占约 44pt 的死白——
            // 大屏尤其明显。直接隐藏它,顶部间距改由 headerTopInset 自适应地给。
            // 只作用于根页,push 进去的子页各自带返回栏,不受影响。
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showWindows) {
                WindowControlSheet()
                    .presentationDetents([
                        .height(WindowControlSheet.sheetHeight(carType: store.session.selectedCarType))
                    ])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(.regularMaterial)
            }
            .sheet(isPresented: $showTrunk) {
                TrunkControlSheet()
                    .fittedSheetHeight($trunkSheetHeight)
                    .presentationDragIndicator(.visible)
                    .presentationBackground(.regularMaterial)
            }
            .sheet(isPresented: $showSunshade) {
                TwoStateControlSheet(kind: .sunshade)
                    .fittedSheetHeight($twoStateSheetHeight)
                    .presentationDragIndicator(.visible)
                    .presentationBackground(.regularMaterial)
            }
            .sheet(isPresented: $showSunroof) {
                TwoStateControlSheet(kind: .sunroof)
                    .fittedSheetHeight($twoStateSheetHeight)
                    .presentationDragIndicator(.visible)
                    .presentationBackground(.regularMaterial)
            }
            .sheet(isPresented: $showFrunk) {
                TwoStateControlSheet(kind: .frunk)
                    .fittedSheetHeight($twoStateSheetHeight)
                    .presentationDragIndicator(.visible)
                    .presentationBackground(.regularMaterial)
            }
            .sheet(isPresented: $showTires) {
                TirePressureSheet()
                    .fittedSheetHeight($tireSheetHeight)
                    .presentationDragIndicator(.visible)
                    .presentationBackground(.regularMaterial)
            }
            .navigationDestination(for: HomeRoute.self) { route in
                Group {
                    switch route {
                    case .charge: ChargeView()
                    case .climate: ClimateView()
                    case .location: VehicleLocationView()
                    case .trips: MileageStatsView()
                    case .settings: SettingsView()
                    }
                }
                .toolbar(.hidden, for: .tabBar)
            }
        }
        .onChange(of: store.pendingDeepLink, initial: true) { _, link in
            guard let link, let route = HomeRoute(deepLink: link) else { return }
            path = NavigationPath([route])
            store.pendingDeepLink = nil
        }
    }

    /// 屏幕高度。车图和顶部间距都拿它当基准，**不能拿 `GeometryReader` 量到的可用高度**：
    /// 每个二级页都挂了 `.toolbar(.hidden, for: .tabBar)`，返回时 Tab Bar 是动画恢复的，
    /// pop 的第一帧首页量到的还是「没有 Tab Bar」那个大出约 49pt 的高度——车图先大 7%、
    /// 整块内容先高 13pt，再一起落回去，看着就是「返回时页面缩了一下」。
    /// App 锁竖屏（见 `project.yml`），屏幕高度是常量，按它算才稳；
    /// 顺带也免疫了弹窗、键盘这类临时改变可用高度的东西。
    private static let screenHeight: CGFloat = {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        // 兜底只会在没有窗口的环境（Preview）里用上，取 iPhone 15/16 那档。
        return scene?.screen.bounds.height ?? 852
    }()

    /// 首页的第一视觉永远是车辆。车图按屏幕高度取 16.7%，并把范围钉住，
    /// 避免小屏被挤没、长屏又只剩一大片空白。
    /// 上限是给车图留的余地——再大就顶到卡片上了；
    /// 下限保证小屏或超大字号把卡片撑高之后，车还认得出来是辆车。
    ///
    /// 16.7% 是原来那版「可用高度 × 20%」折算过来的：可用高度 ≈ 屏幕高 − 状态栏 − Tab Bar，
    /// 各机型折下来都落在 16.7% 附近，换基准后车图大小与原先一致（差 < 2pt）。
    private var heroSize: CGFloat {
        min(190, max(132, Self.screenHeight * 0.167))
    }

    /// 隐藏系统内联导航栏后,标题到状态栏的间距改由自己给,并按屏幕高度自适应:
    /// 小屏(SE / mini)维持原导航栏那段间距,标题位置几乎不变;屏越高收得越窄,
    /// 把原先浪费的空栏高度让给车辆内容,大屏仍留一点呼吸。只优化大屏、不动小屏。
    /// 812 / 945 是原来那对阈值(按可用高度的 680 / 800)折算到屏幕高度的结果:
    /// SE=667、mini=812、15/16=852、Pro Max=932,各档间距与原先差 < 2pt。
    private var headerTopInset: CGFloat {
        let t = min(1, max(0, (Self.screenHeight - 812) / (945 - 812)))
        return 42 - t * (42 - 10)   // 小屏 42(≈原导航栏)→ 大屏 10(留呼吸)
    }

    private var dashboardHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(store.vehicleName)
                .font(.title2.weight(.semibold))
                .lineLimit(1)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 2)
    }

    /// 标题下面这一行既报车况新鲜度，也在有异常时优先报异常。
    private var subtitle: String {
        // 车要 5-10 秒才动作，这段时间必须明确说"在等"，否则看起来就是没反应，
        // 用户会反复点同一个按钮。
        if let confirming = store.confirmingLabel { return "\(confirming) · 等待车辆响应…" }
        guard let state else { return store.isRefreshing ? "正在读取车况…" : "等待车况" }
        if state.anyDoorOpen { return "有车门未关闭" }
        if state.hasTireWarning { return "胎压异常，请尽快检查" }
        guard let updated = store.lastUpdated else { return chargeLabel }
        return Self.freshnessText(reportedAt: store.reportedAt, fetchedAt: updated)
    }

    /// 车况新鲜度。
    ///
    /// 优先报车端自己采集这份数据的时刻：本机每 10 秒问一次服务端，但车休眠着不上报时，
    /// 服务端会把同一份旧数据一直发回来——按本机拉取时间算，屏幕上就永远写着「刚刚更新」，
    /// 而实际数据可能是半小时前的。这正是「刷新不及时」最常见的真身。
    ///
    /// 车端时间拿不到（某些车型不报 `collectTime`）时退回本机拉取时间，同时把措辞从
    /// 「更新」换成「读取」——那句话只能保证「几分钟前问过」，保证不了「车况就是那时候的」，
    /// 不能拿同一种说法混过去。
    ///
    /// 系统的相对时间会说出「2 秒钟前」这种别扭的说法，所以一分钟内直接说「刚刚」。
    static func freshnessText(reportedAt: Date?, fetchedAt: Date) -> String {
        let verb = reportedAt == nil ? "读取" : "更新"
        let moment = reportedAt ?? fetchedAt
        if elapsedSeconds(since: moment) < 60 { return "车况刚刚\(verb)" }
        return "车况\(verb)于 \(relativeText(moment))"
    }

    /// 「刚刚 / 12 分钟前 / 3 小时前」。不带主语，谁在什么时候发生由调用方自己说。
    static func relativeText(_ date: Date) -> String {
        let elapsed = elapsedSeconds(since: date)
        if elapsed < 60 { return "刚刚" }
        if elapsed < 3600 { return "\(elapsed / 60) 分钟前" }
        if elapsed < 86400 { return "\(elapsed / 3600) 小时前" }
        return "\(elapsed / 86400) 天前"
    }

    /// 时钟回拨或车端时间略微超前时会算出负数，一律当作 0，别说出「-2 分钟前」。
    private static func elapsedSeconds(since date: Date) -> Int {
        max(0, Int(Date.now.timeIntervalSince(date)))
    }

    /// 车图下面那排徽章。
    ///
    /// 车锁常驻——锁没锁上是每次看这一屏都想知道的事。车窗、尾门、前备箱只在开着时
    /// 才出现：关好是常态，天天挂一颗「尾门已关」的徽章等于每天报告一件没发生的事，
    /// 真出事那次反而淹在里面。哨兵同理只在开着时出现，但用冷静色不用告警色——
    /// 它是主动开启的功能，不是没关好的洞。
    ///
    /// 天窗和遮阳帘（2026-11-19 起，信号 `1718` / `1724`）只在车报了、且确实开着时出现。
    /// 天窗开着跟车窗没关是一类事——下雨会进水——所以用告警色；遮阳帘开着不是隐患，
    /// 跟哨兵一样用冷静色，只告诉你它开着。不报这两个信号的车（多数车型）照旧没有这两颗。
    ///
    /// 行驶中门锁本就是解锁的，这时再报一颗告警色的「已解锁」是误报——看着像出事，
    /// 其实只是在开车。所以行驶中把这颗徽章整个换成中性色的「行驶中」，停车后自然
    /// 恢复成锁/解锁。判据是官方那套挡位（见 `VehicleState.isDriving`）。
    ///
    /// 容器是居中的 `FlowLayout` 不是 `HStack`：装货那种场景（解锁 + 尾门 + 前备箱 +
    /// 车窗）四五颗一起亮，一行摆不下，挤在 `HStack` 里会溢出屏幕两侧。
    private var statusBadges: some View {
        let driving = state?.isDriving ?? false
        let locked = state?.isLocked ?? true
        return FlowLayout(spacing: 8, centersRows: true) {
            if driving {
                StatusPill(
                    text: "行驶中",
                    systemImage: "steeringwheel",
                    tint: LeapStyle.cool
                )
            } else {
                // 锁好了是常态，不给它上色——一颗常驻的绿徽章天天在报一件没发生的事，
                // 真解锁那次的琥珀色反而不显眼了。锁着只报事实，颜色留给异常。
                StatusPill(
                    text: locked ? "已锁车" : "已解锁",
                    systemImage: locked ? "car.side.lock.fill" : "car.side.lock.open.fill",
                    tint: locked ? .secondary : LeapStyle.caution
                )
            }
            if state?.trunkOpen == true {
                StatusPill(
                    text: "尾门开启",
                    // 和车辆遥控簇的尾门按钮用同一套「车尾特写」字形，
                    // 同一件事在两处不该长成两个样子。
                    systemImage: "car.side.rear.open.crop.fill",
                    tint: LeapStyle.caution
                )
            }
            if state?.frontTrunkOpen == true {
                StatusPill(
                    text: "前备箱开启",
                    // 同上，跟控制栏前备箱按钮的「车头特写」字形保持一套。
                    systemImage: "car.side.front.open.crop.fill",
                    tint: LeapStyle.caution
                )
            }
            if windowsOpen {
                StatusPill(
                    text: "车窗开启",
                    systemImage: "car.window.right",
                    tint: LeapStyle.caution
                )
            }
            if state?.sunroofOpen == true {
                StatusPill(
                    text: "天窗开启",
                    systemImage: "sun.max.fill",
                    tint: LeapStyle.caution
                )
            }
            if state?.sunshadeOpen == true {
                StatusPill(
                    text: "遮阳帘开启",
                    systemImage: "sun.horizon.fill",
                    tint: LeapStyle.cool
                )
            }
            if state?.sentinelOn == true {
                StatusPill(
                    text: "哨兵开启",
                    systemImage: "shield.fill",
                    tint: LeapStyle.cool
                )
            }
        }
        .animation(.smooth, value: driving)
        .animation(.smooth, value: locked)
        .animation(.smooth, value: state?.trunkOpen)
        .animation(.smooth, value: state?.frontTrunkOpen)
        .animation(.smooth, value: windowsOpen)
        .animation(.smooth, value: state?.sunroofOpen)
        .animation(.smooth, value: state?.sunshadeOpen)
        .animation(.smooth, value: state?.sentinelOn)
    }

    /// 有任何一扇上报的车窗没关严。读不到就不算开着——不知道不等于有事。
    ///
    /// 判据在 `VehicleState.anyWindowOpen` 里：状态位优先、开度兜底。
    /// 只看开度的那版对不报开度的车（C11 增程版）永远是 false，窗开着也不出徽章。
    private var windowsOpen: Bool { state?.anyWindowOpen == true }

    // MARK: - 电量 / 空调

    private var summaryRow: some View {
        LeapGlassContainer(spacing: 12) {
            // 增程车的电量卡多一条油量条，比空调卡高。两张卡不等高时右边那张会浮在
            // 中间、底下露出一截背景，很显眼。让两边都撑满这一行的高度。
            HStack(spacing: 12) {
                NavigationLink(value: HomeRoute.charge) { batteryTile }
                    .buttonStyle(.plain)
                    .leapGlass(.regular.interactive(), in: .rect(cornerRadius: LeapStyle.tileRadius))
                    .leapGlassID("battery", in: glassNamespace)

                // 哨兵进了控制栏（栏内 toggle），这一格固定回空调卡，不再二选一。
                climateTile
                    .leapGlass(.regular, in: .rect(cornerRadius: LeapStyle.tileRadius))
                    .leapGlassID("climate", in: glassNamespace)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var batteryTile: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 只有一行标题也要垫到 34：对面那行有个电源按钮撑着，见 ``tileHeaderHeight``。
            CardLabel(text:chargeLabel)
                .frame(minHeight: Self.tileHeaderHeight, alignment: .leading)
            // 无障碍字号下「76 %」和「312 km」并排放不下，续航会在数字和单位之间断行，
            // 变成「312」一行「km」一行。到那个字号就把续航挪到下面单独一行。
            //
            // 撑开中间这段而不是在末行前塞 Spacer：塞 Spacer 会连带多出两段 8 的行距，
            // 纯电车这张卡本来就刚好排满，多出来的间距会把电量条顶下去。
            socAndRange
                .frame(maxHeight: .infinity, alignment: .top)
            // 车端没报上限就不画那道刻度。原来这里回退到设置页滑杆的本地草稿值
            // （初值写死 90），于是在 90% 处画出一道车上根本没设过的刻度——同一台车
            // 充电页那行写的是 `--`，两处对不上。数字口径的车本来就不把上限当信号报，
            // 读不到是常态，不是异常。
            let battery = BatteryBar(
                soc: state?.soc ?? 0,
                limit: state?.chargeLimit,
                charging: state?.isCharging ?? false
            )
            // 增程车才有第二条。纯电车这一项恒缺，不会凭空多出一条空条。
            //
            // 两条一模一样的条并排着，看不出哪条是什么，只像同一个进度条画了两遍。
            // 各自左边给一个图标，一眼就分得开——纯电车只有一条，不需要这个区分，
            // 加了图标反而多一层缩进。
            if let fuel = state?.gasolinePercent {
                // 增程车两条并排，都改细到 4，比纯电单条的 6 清爽；电量条这里也重建成 4。
                let thinBattery = BatteryBar(
                    soc: state?.soc ?? 0,
                    limit: state?.chargeLimit,
                    charging: state?.isCharging ?? false,
                    height: 4
                )
                VStack(spacing: 5) {
                    labeledBar("bolt.fill", thinBattery)
                    labeledBar("fuelpump.fill", FuelBar(percent: fuel, height: 4))
                }
            } else {
                // 单条只有 10 高，垫到和空调卡「空调设置」那行一样并居中，两张卡的末行才共用一条底线。
                battery
                    .frame(minHeight: Self.tileFooterHeight)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .contentShape(.rect)
    }

    /// 一条能量条加左边一个小图标。图标固定宽度，两条的起点才对得齐。
    private func labeledBar(_ systemImage: String, _ bar: some View) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .frame(width: 10)
            bar
        }
    }

    @ViewBuilder
    private var socAndRange: some View {
        let soc = MetricValue(value: state?.soc.map(String.init) ?? "--", unit: "%", size: 32)
        let range = rangeText.map {
            Text($0).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        // 增程那行「电 312 · 油 380 km」比纯电的「312 km」长一倍，
        // 和「76 %」并排就放不下了（实测被截成「油 380…」）。
        // 和无障碍字号一个办法：放不下就自己占一行。
        if isAccessibilitySize || state?.hasFuel == true {
            VStack(alignment: .leading, spacing: 2) { soc; range }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 6) { soc; range }
        }
    }

    /// 续航那行。增程车把电和油分开写——官方也是分两个数，不给总续航。
    private var rangeText: String? {
        guard let state else { return nil }
        if state.hasFuel, let energy = state.energyRange, let fuel = state.gasolineRange {
            return "电 \(energy) · 油 \(fuel) km"
        }
        return state.expectedMileage.map { "\($0) km" }
    }

    private var chargeLabel: String {
        guard let state else { return "电量" }
        switch state.chargeState {
        case 1: return state.isFastCharging ? "充电中 · 直流快充" : "充电中"
        case 2: return "充电完成"
        case 3: return "充电故障"
        case 4: return "预约充电等待"
        case 6: return "充电暂停"
        // 不充电是常态，标题里天天挂着「未充电」等于每天报告一件没发生的事。
        // 有事才说，没事就只写「电量」。
        default: return "电量"
        }
    }

    /// 空调那行小字。读到哪项写哪项，一项都读不到就说清楚是没上报，不拿草稿凑数。
    private var climateDetail: String {
        var parts: [String] = []
        if let setting = state?.acSetting { parts.append("设定 \(setting) °C") }
        if let fan = state?.acFanLevel, fan > 0 { parts.append("\(fan) 档") }
        return parts.isEmpty ? "设定值未上报" : parts.joined(separator: " · ")
    }

    /// 大数字显示哪个温度。车内读不到就退车外——车外是**另一个真实的值**，
    /// 不是编出来的默认值，所以这不算「回退成假数据」；但标题必须跟着改口，
    /// 见 ``temperatureLabel``，绝不能让车外温度冒充车内温度。
    ///
    /// T03 实测（2026-08-10）整张表里没有 `indoorTemp`，只有 `outdoorTemp`——
    /// 这台车不上报车内温度，不是没读到。
    private var displayedTemp: Double? { state?.indoorTemp ?? state?.outdoorTemp }

    /// 空调卡的标题。
    ///
    /// 显示的是车外温度时，标题**必须**说车外，哪怕空调正开着——原来这里空调一开
    /// 就写「空调运行中」，那大数字是车内还是车外就没地方交代了。空调开没开
    /// 由下面那行小字（`climateDetail`，开着时是蓝色的「设定 x °C · x 档」）负责说。
    private var temperatureLabel: String {
        if state?.indoorTemp == nil, state?.outdoorTemp != nil { return "车外温度" }
        return store.climateOn ? "空调运行中" : "车内温度"
    }

    private var climateTile: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                CardLabel(text: temperatureLabel)
                    .lineLimit(1)
                Spacer(minLength: 0)
                // 开关，不是动作按钮：图标两态都是风扇，靠颜色和转不转表示"现在开着没有"。
                // 原来开着显示电源键、关着显示风扇，图标画的是"点下去会发生什么"，
                // 于是关着的时候是个蓝色风扇——看着比开着还像在吹。
                Button {
                    store.applyClimate(on: !store.climateOn)
                } label: {
                    FanGlyph(spinning: store.climateOn)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(store.climateOn ? Color.white : LeapStyle.mutedFill)
                        .frame(width: 34, height: 34)
                        .background {
                            Circle().fill(store.climateOn
                                          ? AnyShapeStyle(LeapStyle.cool)
                                          : AnyShapeStyle(.quaternary))
                        }
                }
                .leapGlass(
                    store.climateOn
                        ? .regular.tint(LeapStyle.cool.opacity(0.28)).interactive()
                        : .regular.interactive(),
                    in: .circle
                )
                .buttonStyle(.plain)
                .disabled(store.isSendingCommand)
                .accessibilityLabel(store.climateOn ? "关闭空调" : "开启空调")
                .sensoryFeedback(.impact(weight: .light), trigger: store.climateOn)
            }
            // 这行的高度本来就是那个 34 的按钮撑出来的，显式写上只是为了让电量卡照着垫平，
            // 见 ``tileHeaderHeight``。
            .frame(minHeight: Self.tileHeaderHeight)
            // 单位写「°C」而不是裸「°」：MetricValue 是按基线对齐的，
            // 而「°」这个字形本身就画在自己那一行的顶上，缩小后放到大数字的基线上
            // 会掉到数字的下半截去，和旁边电量卡的「%」明显对不齐。
            // 加个 C 就是个正常字母，基线对齐后位置才对。
            // 全 App 只有空调页那个大转盘用裸「°」——那里是手动定位的，位置本来就对。
            // 大数字始终是车里实际多少度。空调开不开都是同一件事，
            // 数字在「实测」和「设定」之间跳来跳去，看的人根本分不清眼前这个是哪个。
            // 设定温度和风量放到下面那行，本来就是一组。
            NavigationLink(value: HomeRoute.climate) {
                VStack(alignment: .leading, spacing: 8) {
                    // 大数字贴标题行、「空调设置」贴卡底，和电量卡分法一致：增程车的电量卡
                    // 比这张高，中间那段空白必须让给中间，两张卡的末行才共用一条底线。
                    MetricValue(
                        value: displayedTemp.map(LeapFormat.temperature) ?? "--",
                        unit: "°C",
                        size: 32
                    )
                    .frame(maxHeight: .infinity, alignment: .top)
                    HStack(spacing: 4) {
                        Text(store.climateOn ? climateDetail : "空调设置")
                            .font(.caption)
                            .foregroundStyle(store.climateOn ? LeapStyle.cool : Color.secondary)
                            .lineLimit(2)
                            .minimumScaleFactor(0.85)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(minHeight: Self.tileFooterHeight)
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .contentShape(.rect)
        // 吹出来的风。挂在 background 上而不是 overlay：粒子要在温度数字后面飘，
        // 盖在字上会让本来就小的数字更难认。关着时整个不渲染——`TimelineView` 一挂上
        // 就是每帧唤醒，空调没开还转着纯属白烧电。
        .background {
            if store.climateOn {
                AirflowParticles()
                    .clipShape(.rect(cornerRadius: LeapStyle.tileRadius))
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - 状态条

    /// 车门、车窗、胎压、里程压成一行四列。
    /// 原本这些占三张卡，首页要一屏放下就没有那个预算了。
    private var statusStrip: some View {
        GlassCard(radius: LeapStyle.tileRadius) {
            HStack(spacing: 0) {
                statusColumn(
                    title: "车门",
                    value: state?.anyDoorOpen == true ? "未关" : "已关",
                    systemImage: "car.top.door.front.left.and.front.right.open",
                    alert: state?.anyDoorOpen == true
                )
                columnDivider
                // 控不了车窗的车（部分 T03 没有电动升降窗）这一格退成纯状态显示，
                // 和左边「车门」那格一样不可点——开合状态位这些车照样报，看得到开没开，
                // 只是点进去也没有能下发的档位。判据见 `VehicleState.windowsRemoteSupported`。
                if store.windowsControllable {
                    Button { showWindows = true } label: {
                        statusColumn(
                            title: "车窗",
                            value: windowSummary,
                            systemImage: "car.window.right",
                            alert: false,
                            chevron: true
                        )
                    }
                    .buttonStyle(.plain)
                } else {
                    statusColumn(
                        title: "车窗",
                        value: windowSummary,
                        systemImage: "car.window.right",
                        alert: false
                    )
                }
                columnDivider
                Button { showTires = true } label: {
                    statusColumn(
                        title: "胎压",
                        value: tireSummary,
                        systemImage: "gauge.with.dots.needle.bottom.50percent",
                        alert: state?.hasTireWarning == true,
                        chevron: true
                    )
                }
                .buttonStyle(.plain)
                columnDivider
                NavigationLink(value: HomeRoute.trips) {
                    statusColumn(
                        title: "行程",
                        value: state?.totalMileage.map { "\($0) km" } ?? "--",
                        systemImage: "road.lanes",
                        alert: false,
                        chevron: true
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var columnDivider: some View {
        Rectangle()
            .fill(.quaternary)
            .frame(width: 1, height: 30)
    }

    /// 内容末尾的一行隐私说明。
    private var privacyNote: some View {
        Label("我们不会记录和上传零跑官方服务的会话信息，控车信息等其他信息。", systemImage: "lock.shield")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .labelStyle(.titleAndIcon)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.top, 2)
            .accessibilityElement(children: .combine)
    }

    private func statusColumn(
        title: String,
        value: String,
        systemImage: String,
        alert: Bool,
        chevron: Bool = false
    ) -> some View {
        VStack(spacing: 6) {
            // 四个符号的字形高矮不一（road.lanes 是扁的，车门那个带开门角要高出好几个点），
            // 高度交给字形自己定，下面的值和标题就跟着各差几个点，四列横着看全是错的。
            // 钉死这一行的高度，符号在里头居中，值和标题才从同一条线往下排。
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(alert ? AnyShapeStyle(LeapStyle.caution) : AnyShapeStyle(.secondary))
                .frame(height: 18)
            // 四格里只有车窗和胎压点得进去，可它们和车门、里程长得一模一样，
            // 唯一的区别是一个 8pt 的三级色箭头，等于没有。
            // 给能点的那两格套个胶囊底，箭头也提到二级色——一眼就能看出哪两格是门。
            HStack(spacing: 3) {
                Text(value)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(alert ? AnyShapeStyle(LeapStyle.caution) : AnyShapeStyle(.primary))
                if chevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, chevron ? 9 : 0)
            // 纵向留白四格一律给，不然有胶囊的两格会比另外两格高出一截，
            // 底下那行标题就对不齐了。
            .padding(.vertical, 4)
            .background {
                if chevron {
                    Capsule().fill(.primary.opacity(0.1))
                }
            }
            Text(title)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .contentShape(.rect)
        // 一格三段（图标／值／标题）会被 VoiceOver 拆成三条分开念，
        // 而且顺序是「已关、车窗」这种倒的。合成一条，标题当 label、值当 value。
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(alert ? "\(value)，异常" : value)
        .accessibilityAddTraits(chevron ? .isButton : [])
    }

    private var windowSummary: String {
        guard let state, let open = state.anyWindowOpen else { return "--" }
        // 有开度就说得具体些：四扇里开得最大的那个概括这一格。
        if let openness = state.maxWindowOpenness, openness > 0 {
            return WindowPosition.describe(openness)
        }
        // 只有开合状态位的车（C11 增程版就是）只能说到这儿——
        // 开了多少车根本没报，编一个百分比出来就是撒谎。
        return open ? "已开" : "已关"
    }

    private var tireSummary: String {
        guard let state, state.hasTireData else { return "--" }
        if state.hasTireWarning { return "异常" }
        return "正常"
    }

    // MARK: - 位置

    private var locationCard: some View {
        NavigationLink(value: HomeRoute.location) {
            VStack(spacing: 0) {
                LocationThumbnail(coordinate: store.coordinate)
                    .frame(height: 132)

                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        CardLabel(text: "车辆位置")
                        Text(locationSummary)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect(cornerRadius: LeapStyle.tileRadius))
        }
        .buttonStyle(.plain)
        .leapGlass(.regular.interactive(), in: .rect(cornerRadius: LeapStyle.tileRadius))
        .clipShape(.rect(cornerRadius: LeapStyle.tileRadius))
    }

    private var locationSummary: String {
        guard let state else { return "读取中" }
        guard state.privacyGPSAllowed else { return "隐私模式已开启" }
        guard store.coordinate != nil else { return "暂无定位" }
        return store.locationName ?? "正在解析位置"
    }

}

// MARK: - 车辆主视觉

private struct VehicleHero<Badge: View>: View {
    @Environment(VehicleStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme
    /// 车图跟着屏幕高度走，把上下多出来的空间吃掉。
    ///
    /// 原来车图是写死的 108，剩下的高度全被上下两个 Spacer 均分——
    /// 在 6.9 吋上就是车的上面空一块、下面空一块，各一百多点，
    /// 上半屏空荡荡，下半屏卡片挤成一团。让主视觉长大去占那块地方，
    /// 空白就不再是"没排满"，而是主视觉自己的呼吸。
    var size: CGFloat
    var badges: Badge

    /// 2D 车图的高度上限，相对 ``size``。
    ///
    /// 原来是 1.35，量下来它把图卡死了：官方图层是 1125×525（2.14:1），在 6.3 吋上
    /// 内容区有 370pt 宽，铺满需要 173pt 高，而 1.35 只给到 142pt——图被缩到 305pt 宽，
    /// 两侧各空 32pt。于是图层边缘那圈羽化过的痕迹落在画面中间偏内的位置，比贴着
    /// 屏幕边还显眼。
    ///
    /// 1.8 放它铺满整行。上限没有直接去掉：画布更方的车型（同一个包里就有 1125×1200
    /// 的图层）不设限会长到 230pt 以上，把下面的卡片顶下去。多出来的高度还是从上下
    /// 两个 Spacer 里拿，卡片位置不受影响。
    /// （`VehicleHero` 是泛型，存储型 static 不让写，只能是计算属性。）
    private static var staticHeightRatio: CGFloat { 1.8 }

    /// 3D 首帧出来之前先盖着占位图，避免露出一块空白的画布。
    @State private var is3DReady = false
    /// 3D 渲不出来（车型资源不全、WebGL 挂了）就别再试，安心用 2D。
    @State private var is3DFailed = false

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                // 三层回退：能渲 3D 就渲 3D，其次按车况叠出来的官方车图，最后才是剪影。
                if let root = store.carModelRoot, let param = store.carModel?.modelParam, !is3DFailed {
                    CarModel3DView(
                        root: root, param: param, assetAlias: store.carAssetAlias, state: store.state,
                        onReady: { withAnimation(.easeOut(duration: 0.35)) { is3DReady = true } },
                        onFailure: { is3DFailed = true; is3DReady = false },
                        // 3D 车的桌面卡片车图只能从这里来，包里没有 2D 图层可叠。
                        onSnapshot: { store.adoptRenderedCarImage($0) }
                    )
                    // 资源目录一换（换车、换账号）就整个重建 WebView：
                    // scheme handler 的 root 只在 makeUIView 时捕获一次，
                    // 不重建的话它会一直从旧车的目录里取文件。
                    .id(root)
                    // 画布比 2D 图那套高出一截，给 3D 的取景余量留位置。
                    // 车本身的大小靠 `radius`（相机距离）调，不靠撑画布。
                    //
                    // 1.35 不够：模型转到某些角度（车头朝下那侧）下沿会顶出画布被切掉。
                    // 多出来的高度是从上下两个 Spacer 里拿的，卡片位置不受影响。
                    .frame(height: size * 1.62)
                    .opacity(is3DReady && store.customVehiclePhoto == nil ? 1 : 0)
                    .allowsHitTesting(store.customVehiclePhoto == nil)
                    // 回调丢失的兜底在 CarModel3DView 里：从 newInit 真正调下去才计时。
                    // 原来这里从视图创建起算 8 秒，在设置页里刚打开开关时首页被盖着、
                    // 布局没跑，模型还没开始起就被判成失败了。
                }
                // 占位一直垫在底下：3D 渲不出来时（车型没适配、WebGL 挂了）
                // 它就是最终画面，而不是留一块空白。3D 出来后盖在它上面。
                if let photo = store.customVehiclePhoto {
                    layer(photo)
                        .frame(maxWidth: .infinity)
                        .frame(maxHeight: size * Self.staticHeightRatio)
                } else {
                    staticVehicle.opacity(is3DReady ? 0 : 1)
                }
            }
            // 纯装饰。锁车状态由下面那排徽章负责播报，这里再念一遍「汽车」是噪音。
            .accessibilityHidden(true)
            // 3D 资源被撤走或换成另一台车的目录时必须把就绪/失败位清掉：
            // 撤走后 is3DReady 还是 true 的话，占位那层会一直保持全透明——
            // 剪影明明在层里却什么都看不见；换目录后 WebView 已按 .id(root)
            // 重建，旧的就绪位不清则新模型加载期间盖着一块空画布。
            .onChange(of: store.carModelRoot) { _, _ in
                is3DReady = false
                is3DFailed = false
            }

            badges
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    /// 按车况叠出来的官方车图，没有就退回剪影。也充当 3D 加载期间的占位。
    @ViewBuilder
    private var staticVehicle: some View {
        if let composition = store.carComposition {
            // 三段是分开的：充电层夹在车身和充电口盖中间，充电中要逐帧换。
            // 每段都是同一张 1125×525 的画布，按同样规则缩放就自动对齐。
            ZStack {
                layer(composition.base)
                chargeLayer(composition)
                if let top = composition.top { layer(top) }
            }
            .frame(maxWidth: .infinity)
            .frame(maxHeight: size * Self.staticHeightRatio)
        } else if let carImage = store.carImage {
            // 冷启动缓存的那张，图层还没叠好时先顶上。
            layer(carImage)
                .frame(maxWidth: .infinity)
                .frame(maxHeight: size * Self.staticHeightRatio)
        } else {
            Image(systemName: "car.side.fill")
                .font(.system(size: size, weight: .thin))
                .foregroundStyle(LeapStyle.vehicleSilhouette)
                .symbolEffect(.bounce, value: store.state?.isLocked)
                // 剪影是纯色字形，没有自己的立体感，得靠投影撑起来。
                // 浅色下要轻得多，否则这辆车像贴在纸上的一张贴纸。
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.4 : 0.14), radius: 22, y: 14)
        }
    }

    /// 官方图层是透明背景的宽幅图（1125×525），车本身只占中间一条。
    /// 按高度约束会缩得很小，所以让它按宽度铺开，和官方 App 一样占满整行。
    /// 图层里自带渲染好的接地阴影，外面再叠 SwiftUI 阴影会沿着不透明像素
    /// 糊出一块灰白方块——所以这里不加任何阴影。
    private func layer(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
    }

    /// 充电层。充电中是 14–18 帧的循环动画（充电线一段段亮起来），
    /// 其余状态是一张静态图（插枪待机 / 已充满）。
    @ViewBuilder
    private func chargeLayer(_ composition: CarLayerComposer.ComposedCar) -> some View {
        if composition.isAnimated {
            let interval = CarLayerComposer.frameInterval
            let frames = composition.chargeFrames
            TimelineView(.periodic(from: .now, by: interval)) { context in
                // 用绝对时间取帧，视图重建（车况刷新）时动画不会跳回第一帧。
                let tick = Int(context.date.timeIntervalSinceReferenceDate / interval)
                layer(frames[((tick % frames.count) + frames.count) % frames.count])
            }
        } else if let single = composition.chargeFrames.first {
            layer(single)
        }
    }
}

// MARK: - 空调开关

/// 空调开关里的风扇。开着就一直转——这张卡上没有别的地方说得出「正在吹」这件事，
/// 大数字写的是车内实测温度，开不开都是同一个数。
private struct FanGlyph: View {
    var spinning: Bool

    var body: some View {
        // 转速慢到能看清扇叶。真风扇当然比这快，但这里是个状态指示不是仪表，
        // 转快了在小圆钮里只剩一团糊。
        if spinning {
            // 用 TimelineView 而不是 `.repeatForever` 的隐式动画：车况每次刷新都会
            // 重建这颗按钮，隐式动画会跟着从 0° 重来，转起来一顿一顿的。
            // 按绝对时间算角度就没有这个问题——重建多少次，算出来都是同一个角度。
            TimelineView(.animation) { context in
                Image(systemName: "fan")
                    .rotationEffect(.degrees(context.date.timeIntervalSinceReferenceDate * 90))
            }
        } else {
            Image(systemName: "fan")
        }
    }
}

/// 空调开着时，从右上角那个开关往卡片左下方飘散的风。
///
/// 用 `Canvas` 画而不是堆一二十个 `View`：这层纯粹是气氛，一次绘制比让布局系统
/// 每帧去算十几个子视图的位置便宜得多。
private struct AirflowParticles: View {
    /// 粒子数。再多就从「有风」变成「下雪」了。
    private static let count = 18
    /// 一颗粒子从冒头到淡尽的秒数。
    private static let lifetime: Double = 3.4

    var body: some View {
        TimelineView(.animation) { context in
            Canvas { ctx, size in
                let time = context.date.timeIntervalSinceReferenceDate
                // 出风口就是右上角那颗开关的圆心：卡片内边距 16/14 加上 34 圆钮的半径 17。
                let origin = CGPoint(x: size.width - 33, y: 31)
                let travel = hypot(size.width, size.height) * 0.95

                for index in 0..<Self.count {
                    // 每颗粒子的相位、角度、大小只跟序号有关，不用 `random()`：
                    // Canvas 每帧都会重算全部粒子，用随机数的话每帧都是重新撒一把点，
                    // 看到的是噪声不是飘动。三个无理数取小数部分，散得够开又完全可复现。
                    let phaseSeed = (Double(index) * 0.618_033_988_7).truncatingRemainder(dividingBy: 1)
                    let angleSeed = (Double(index) * 0.754_877_666_2).truncatingRemainder(dividingBy: 1)
                    let sizeSeed = (Double(index) * 0.414_213_562_4).truncatingRemainder(dividingBy: 1)

                    let phase = (time / Self.lifetime + phaseSeed).truncatingRemainder(dividingBy: 1)
                    // 135° 是屏幕坐标下的左下方（y 轴朝下），±23° 让这股风有点散。
                    let angle = .pi * 0.75 + (angleSeed - 0.5) * 0.8
                    let dx = cos(angle)
                    let dy = sin(angle)
                    // 从圆钮的边缘起步，不是圆心：圆心那一片被按钮自己盖着（粒子画在
                    // 卡片背景上，按钮在内容层），从中心出发的话前半程根本看不见，
                    // 看上去就成了卡片中间凭空冒点，而不是从出风口吹出来。
                    // 走得远近还不一样，否则十八颗粒子会排成一条整齐的直线一起冲出去。
                    let distance = 17 + phase * travel * (0.75 + sizeSeed * 0.5)
                    // 侧向摆一下，风才不像激光。摆动加在垂直于飞行方向上。
                    let sway = sin(phase * .pi * 2.4 + angleSeed * 6.283) * (4 + sizeSeed * 8)
                    let x = origin.x + dx * distance - dy * sway
                    let y = origin.y + dy * distance + dx * sway
                    let radius = 1.3 + sizeSeed * 2.0
                    // 两头淡、中间实，但淡入比淡出快得多：刚出风口就得看得见，
                    // 慢慢浮现的话最亮的一段已经飘到卡片中间了，风就不像从按钮来的。
                    let alpha = min(1, phase * 6) * min(1, (1 - phase) * 2.2) * 0.5

                    ctx.fill(
                        Path(ellipseIn: CGRect(
                            x: x - radius, y: y - radius,
                            width: radius * 2, height: radius * 2
                        )),
                        with: .color(LeapStyle.cool.opacity(alpha))
                    )
                }
            }
        }
    }
}

// MARK: - 电量条

struct BatteryBar: View {
    var soc: Int
    /// 读不到就不画那道刻度。画一个猜出来的位置，等于告诉用户车设的就是那个数。
    var limit: Int?
    var charging: Bool
    /// 条的粗细。增程车电量、油量两条并排，改细一点（4）更清爽；纯电车单条保持 6。
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)

                Capsule()
                    .fill(charging
                          ? AnyShapeStyle(LinearGradient(
                                colors: [LeapStyle.accent, LeapStyle.accent.opacity(0.65)],
                                startPoint: .leading, endPoint: .trailing))
                          : AnyShapeStyle(LeapStyle.accent))
                    .frame(width: proxy.size.width * CGFloat(min(100, max(0, soc))) / 100)
                    .animation(.smooth(duration: 0.6), value: soc)
            }
            // 条自己的高度必须在这里定死。刻度要比条高，从前它和这两个 Capsule 同在
            // 一个 ZStack 里，ZStack 就按最高的那个（height + 4）算尺寸，而底槽和填充
            // 都是柔性的，跟着一起长高——外层那个 `.frame(height:)` 只管得住
            // GeometryReader 自己，管不住溢出来的 ZStack。结果是：报了充电上限的车
            // 电量条被撑成 8，旁边没有刻度的油量条还是 4，看着就成了「电粗油细」，
            // 而两条明明传的是同一个 4。
            .frame(height: height)
            // 充电上限刻度。比条略高一点（上下各多 2）才看得出是刻度而不是填充的一段。
            // 放 overlay 里画：overlay 不参与本体布局，刻度想多高都不会再顶宽条子。
            .overlay(alignment: .leading) {
                if let limit {
                    Capsule()
                        .fill(.primary.opacity(0.55))
                        .frame(width: 2, height: height + 4)
                        .offset(x: proxy.size.width * CGFloat(min(100, max(0, limit))) / 100 - 1)
                }
            }
        }
        .frame(height: height)
        // 纯装饰。电量百分比和充电上限旁边都有文字，这条只是把同一个数画出来，
        // 让 VoiceOver 再念一遍是重复。
        .accessibilityHidden(true)
    }
}

// MARK: - 油量条

/// 增程车的油量。和电量条同宽同高并排叠着，一眼能比出「电还剩多少、油还剩多少」。
struct FuelBar: View {
    var percent: Int
    /// 和电量条一致的粗细。增程车两条并排时传 4，比默认 6 细。
    var height: CGFloat = 6

    /// 官方小组件按 ≤5 / 5–10 / >10 三档换图标来警示低油量，我们改成换颜色。
    ///
    /// 但**油量正常时和电量条同色**：两条颜色一深绿一深橙并排着，卡片会变得很吵，
    /// 而且"橙色"本身就是个警示信号，天天亮着等于每天警示一件没发生的事。
    /// 颜色留给真的低油量用，平时靠左边那个油枪图标区分就够了。
    private var tint: Color {
        switch percent {
        case ...5: return .red
        case ...10: return LeapStyle.warm
        default: return LeapStyle.accent
        }
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(tint)
                    .frame(width: proxy.size.width * CGFloat(min(100, max(0, percent))) / 100)
                    .animation(.smooth(duration: 0.6), value: percent)
            }
        }
        .frame(height: height)
        // 电量条是纯装饰（数字就在旁边），油量条不是——油量百分比在首页没有别处写，
        // 不念一遍 VoiceOver 用户就完全拿不到这个数。
        .accessibilityLabel("油量 \(percent)%")
    }
}

// MARK: - 车窗开度指示

/// 只画两个前窗。后窗在该车型上恒报 0，那不是"全开"而是占位值，画出来会误导。
struct WindowLevelIndicator: View {
    var leftFront: Int
    var rightFront: Int

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            bar(leftFront)
            bar(rightFront)
        }
        .frame(height: 26)
    }

    /// 值是开度百分比：0 关闭（最矮），100 全开（最高）。
    private func bar(_ value: Int) -> some View {
        let openness = CGFloat(min(100, max(0, value))) / 100
        return Capsule()
            .fill(openness > 0 ? LeapStyle.cool.opacity(0.85) : Color.primary.opacity(0.35))
            .frame(width: 8, height: 9 + openness * 17)
            .animation(.smooth, value: value)
    }
}

enum WindowPosition {
    /// 值是开度百分比：0 关闭、100 全开。各车型的原始刻度已经在 `WindowScale` 里换算过了。
    static func describe(_ value: Int) -> String {
        switch value {
        case ...0: return "已关"
        case 100...: return "全开"
        default: return "开 \(value)%"
        }
    }
}


/// 首页的导航目的地。用值驱动，桌面卡片的深链和手动点击才能走同一条路径。
enum HomeRoute: Hashable {
    case charge
    case climate
    case location
    /// 行程页：零跑官方的里程能耗（见 `MileageStatsView`）。
    /// 老深链 `mileage` / `mileageStats` 继续认，桌面上已经建好的快捷方式不能失效。
    case trips
    case settings

    init?(deepLink: String) {
        switch deepLink {
        case "charge": self = .charge
        case "climate": self = .climate
        case "location": self = .location
        case "trips", "mileage", "mileageStats": self = .trips
        case "settings": self = .settings
        default: return nil
        }
    }
}
