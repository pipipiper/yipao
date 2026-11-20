import CoreLocation
import SwiftUI
import WidgetKit

/// App 与桌面卡片共享的一小份车况快照。
///
/// 主 App 每次刷新车况后写一份；卡片刷新时也会自己拉一次车况并写回同一份，
/// 拉不到就沿用上一份，并如实标出数据有多旧。
struct VehicleSnapshot: Codable, Equatable, Sendable {
    var vehicleName: String
    var soc: Int?
    /// 增程车的油量百分比；纯电车为 nil（卡片据此决定要不要画油量条）。
    /// Codable 的可选字段，老快照没有这个键会解成 nil，向后兼容。
    var gasolinePercent: Int?
    /// 来自车辆能力码；旧快照缺失时才用已有的电油分项兼容判断。
    var isExtendRange: Bool?
    var rangeKm: Int?
    /// 增程车的纯电续航（km）。纯电车为 nil——纯电车的续航就是 `rangeKm`，不重复存一份。
    /// Codable 的可选字段，老快照没有这个键会解成 nil，向后兼容。
    var energyRangeKm: Int?
    /// 增程车的燃油续航（km）。纯电车为 nil。
    /// 车端本来就把电和油分成两个数报，官方也不给综合续航，所以卡片上分两段显示。
    var fuelRangeKm: Int?
    var isLocked: Bool?
    var isDriving: Bool
    var isCharging: Bool
    var chargeLimit: Int?
    var chargeRemainMinutes: Int?
    var chargePowerKW: Double?
    var indoorTemp: Double?
    var climateOn: Bool
    var windowsClosed: Bool?
    var anyDoorOpen: Bool
    /// 尾门开着。
    ///
    /// 注意 `anyDoorOpen` **不含**尾门（它只看四个车门），所以这一项必须单独带过来，
    /// 否则卡片上的尾门键永远是灰的、顶部那句话也永远不提尾门。
    /// 读不到是 nil，一律按「不亮、不提」处理——不亮只是中性外观，
    /// 不像文字那样会替车编出一个「已关」。
    /// Codable 的可选字段，老快照没有这个键会解成 nil，向后兼容。
    var trunkOpen: Bool?
    var hasTireWarning: Bool
    var locationName: String?
    var latitude: Double?
    var longitude: Double?
    /// 本机什么时候把这份车况拉下来的。注意不是车端采集时刻，那个看 `reportedAt`。
    var updatedAt: Date
    /// 车端采集这份车况的时刻。读不到（某些车型不报 `collectTime`）时是 nil。
    ///
    /// 卡片刷得再勤 `updatedAt` 都是「刚刚」；车休眠着不上报时，服务端会把同一份旧数据
    /// 一直发回来，只有这个字段能看出车况到底有多旧。
    /// Codable 的可选字段，老快照没有这个键会解成 nil，向后兼容。
    var reportedAt: Date?

    var hasFuel: Bool {
        isExtendRange ?? (gasolinePercent != nil || energyRangeKm != nil || fuelRangeKm != nil)
    }

    /// 增程车的 2188 可能停留在旧值（真机 254），中卡必须使用当前工况的电油分项。
    /// 分项缺失时只显示已知项，不能退回那个无关的数，也不自行相加。
    var mediumRangeText: String? {
        if !hasFuel { return rangeKm.flatMap { $0 >= 0 ? "\($0) km" : nil } }
        var parts: [String] = []
        if let energyRangeKm, energyRangeKm >= 0 { parts.append("电 \(energyRangeKm)") }
        if let fuelRangeKm, fuelRangeKm >= 0 { parts.append("油 \(fuelRangeKm)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ") + " km"
    }

    private enum CodingKeys: String, CodingKey {
        case vehicleName, soc, gasolinePercent, isExtendRange, rangeKm, energyRangeKm, fuelRangeKm,
             isLocked, isDriving, isCharging,
             chargeLimit, chargeRemainMinutes, chargePowerKW, indoorTemp, climateOn, windowsClosed, anyDoorOpen, trunkOpen,
             hasTireWarning, locationName, latitude, longitude, updatedAt, reportedAt
    }

    init(
        vehicleName: String,
        soc: Int?,
        gasolinePercent: Int?,
        isExtendRange: Bool? = nil,
        rangeKm: Int?,
        energyRangeKm: Int? = nil,
        fuelRangeKm: Int? = nil,
        isLocked: Bool?,
        isDriving: Bool,
        isCharging: Bool,
        chargeLimit: Int?,
        chargeRemainMinutes: Int?,
        chargePowerKW: Double?,
        indoorTemp: Double?,
        climateOn: Bool,
        windowsClosed: Bool?,
        anyDoorOpen: Bool,
        trunkOpen: Bool?,
        hasTireWarning: Bool,
        locationName: String?,
        latitude: Double?,
        longitude: Double?,
        updatedAt: Date,
        reportedAt: Date?
    ) {
        self.vehicleName = vehicleName
        self.soc = soc
        self.gasolinePercent = gasolinePercent
        self.isExtendRange = isExtendRange
        self.rangeKm = rangeKm
        self.energyRangeKm = energyRangeKm
        self.fuelRangeKm = fuelRangeKm
        self.isLocked = isLocked
        self.isDriving = isDriving
        self.isCharging = isCharging
        self.chargeLimit = chargeLimit
        self.chargeRemainMinutes = chargeRemainMinutes
        self.chargePowerKW = chargePowerKW
        self.indoorTemp = indoorTemp
        self.climateOn = climateOn
        self.windowsClosed = windowsClosed
        self.anyDoorOpen = anyDoorOpen
        self.trunkOpen = trunkOpen
        self.hasTireWarning = hasTireWarning
        self.locationName = locationName
        self.latitude = latitude
        self.longitude = longitude
        self.updatedAt = updatedAt
        self.reportedAt = reportedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        vehicleName = try c.decode(String.self, forKey: .vehicleName)
        soc = try c.decodeIfPresent(Int.self, forKey: .soc)
        gasolinePercent = try c.decodeIfPresent(Int.self, forKey: .gasolinePercent)
        isExtendRange = try c.decodeIfPresent(Bool.self, forKey: .isExtendRange)
        rangeKm = try c.decodeIfPresent(Int.self, forKey: .rangeKm)
        energyRangeKm = try c.decodeIfPresent(Int.self, forKey: .energyRangeKm)
        fuelRangeKm = try c.decodeIfPresent(Int.self, forKey: .fuelRangeKm)
        isLocked = try c.decodeIfPresent(Bool.self, forKey: .isLocked)
        isDriving = try c.decodeIfPresent(Bool.self, forKey: .isDriving) ?? false
        isCharging = try c.decode(Bool.self, forKey: .isCharging)
        chargeLimit = try c.decodeIfPresent(Int.self, forKey: .chargeLimit)
        chargeRemainMinutes = try c.decodeIfPresent(Int.self, forKey: .chargeRemainMinutes)
        chargePowerKW = try c.decodeIfPresent(Double.self, forKey: .chargePowerKW)
        indoorTemp = try c.decodeIfPresent(Double.self, forKey: .indoorTemp)
        climateOn = try c.decode(Bool.self, forKey: .climateOn)
        windowsClosed = try c.decodeIfPresent(Bool.self, forKey: .windowsClosed)
        anyDoorOpen = try c.decode(Bool.self, forKey: .anyDoorOpen)
        trunkOpen = try c.decodeIfPresent(Bool.self, forKey: .trunkOpen)
        hasTireWarning = try c.decode(Bool.self, forKey: .hasTireWarning)
        locationName = try c.decodeIfPresent(String.self, forKey: .locationName)
        latitude = try c.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try c.decodeIfPresent(Double.self, forKey: .longitude)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        reportedAt = try c.decodeIfPresent(Date.self, forKey: .reportedAt)
    }

    static let placeholder = VehicleSnapshot(
        vehicleName: "S01",
        soc: 76,
        gasolinePercent: nil,
        rangeKm: 312,
        isLocked: true,
        isDriving: false,
        isCharging: false,
        chargeLimit: 90,
        chargeRemainMinutes: nil,
        chargePowerKW: nil,
        indoorTemp: 26,
        climateOn: false,
        windowsClosed: true,
        anyDoorOpen: false,
        trunkOpen: false,
        hasTireWarning: false,
        locationName: "杭州市滨江区",
        latitude: 30.18682,
        longitude: 120.19551,
        updatedAt: .now,
        reportedAt: .now
    )

    /// 从车况构造快照。App 和卡片两边都要写这份文件，字段映射必须是同一套，
    /// 所以放在共享层而不是各写一遍。
    static func make(
        state: VehicleState,
        vehicleName: String,
        locationName: String?,
        updatedAt: Date = .now
    ) -> VehicleSnapshot {
        // 判据统一收在 `anyWindowOpen` 里：开合状态位优先、开度兜底。
        // 只看开度的那版对不报开度的车（C11 增程版）恒为 nil，卡片上这一项永远是空的。
        let windowsClosed: Bool? = state.anyWindowOpen.map { !$0 }
        let coordinate = state.shareableCoordinate
        let snapshot = VehicleSnapshot(
            vehicleName: vehicleName,
            soc: state.soc,
            gasolinePercent: state.gasolinePercent,
            isExtendRange: state.hasFuel,
            rangeKm: state.expectedMileage,
            energyRangeKm: state.hasFuel ? state.energyRange : nil,
            fuelRangeKm: state.hasFuel ? state.gasolineRange : nil,
            isLocked: state.isLocked,
            isDriving: state.isDriving,
            isCharging: state.isCharging,
            chargeLimit: state.chargeLimit,
            chargeRemainMinutes: state.chargeRemainMinutes,
            chargePowerKW: state.chargePowerKW,
            indoorTemp: state.indoorTemp,
            climateOn: state.acOn,
            windowsClosed: windowsClosed,
            anyDoorOpen: state.anyDoorOpen,
            trunkOpen: state.trunkOpen,
            hasTireWarning: state.hasTireWarning,
            locationName: locationName,
            latitude: coordinate?.latitude,
            longitude: coordinate?.longitude,
            updatedAt: updatedAt,
            reportedAt: state.reportedAt
        )
        return snapshot
    }

    /// 这份车况实际有多旧。车端报了采集时刻就以它为准，读不到才退回本机拉取时间。
    private var moment: Date { reportedAt ?? updatedAt }

    /// 卡片上那句「多久前」的措辞。
    ///
    /// 带动词，而且**车端时刻读不到时动词要改口**：那时这句话只能保证「几分钟前问过」，
    /// 保证不了「车况就是那时候的」，不能拿同一种说法混过去。和首页副标题同一套口径。
    ///
    /// 系统的相对时间会说出「2 秒钟前」这种别扭的说法，所以一分钟内直接说「刚刚」。
    var freshnessText: String {
        let verb = reportedAt == nil ? "读取" : "更新"
        let elapsed = max(0, Int(Date.now.timeIntervalSince(moment)))
        if elapsed < 60 { return "刚刚\(verb)" }
        if elapsed < 3600 { return "\(verb)于 \(elapsed / 60) 分钟前" }
        if elapsed < 86400 { return "\(verb)于 \(elapsed / 3600) 小时前" }
        return "\(verb)于 \(elapsed / 86400) 天前"
    }

    /// 大卡上那句「多久前」的短版：只有时间，不带动词。
    ///
    /// 那一行右边已经站着一句状态（地名或「车窗未关闭」），再拼一个「更新于」
    /// 就长到要缩字号了。动词丢掉之后车端时刻和本机拉取时间的区别也跟着丢了——
    /// 这一行本来就只承诺「这个数字有多新」，要追究是哪一种「新」，首页副标题里说得全。
    var freshnessCompact: String {
        let elapsed = max(0, Int(Date.now.timeIntervalSince(moment)))
        if elapsed < 60 { return "刚刚" }
        if elapsed < 3600 { return "\(elapsed / 60) 分钟前" }
        if elapsed < 86400 { return "\(elapsed / 3600) 小时前" }
        return "\(elapsed / 86400) 天前"
    }

    /// 超过半小时的数据不该让用户以为是实时的。
    ///
    /// 按车端采集时刻算：车休眠着的时候本机每次都拉得到东西，但那是同一份旧数据，
    /// 按拉取时间算的话它永远不会过期。
    var isStale: Bool { isOlderThan(1800) }

    /// 这份车况有没有旧过给定的时长。按车端采集时刻算，理由同 `isStale`。
    ///
    /// 抽出来是因为"多旧才算旧"在不同地方不是一个数：显示上半小时才提醒，
    /// 而按下车锁键时要不要重新联网确认，用的是更短的一档。
    func isOlderThan(_ seconds: TimeInterval) -> Bool {
        Date.now.timeIntervalSince(moment) > seconds
    }

    /// 还能拿来**决定按下去发哪个方向**的锁状态。过期就是 nil，不做断言。
    ///
    /// 和 `isLocked` 的区别只在时效，但用错地方后果不一样：卡片是拿它显示的，旧一点
    /// 顶多是信息旧了，旁边那句「多久前」已经说清楚；而锁屏控件是个开关，系统把"拨过去
    /// 之后的值"当目标态发下去，**显示什么就决定了按下去发哪个方向**——显示「已锁车」
    /// 时按一下发的是解锁。快照几十分钟没人刷的情况下，那一按就是把车打开。
    ///
    /// 所以凡是"这个值会变成一条指令"的地方都读这一个，不要自己再写一遍 `isStale`
    /// 判断：判据分叉过一次（`lockText` 那条注释里记着），同一台车两个表面两个说法。
    var trustedLock: Bool? { isStale ? nil : isLocked }

    /// 照着这份快照，按一下车锁键该把车变成什么状态（`true` = 锁上）。
    ///
    /// **凡是要把快照翻译成一条锁车指令的地方都读这一个。** 原来这件事各处各写一遍，
    /// 而且写反了：「只管锁车」卡是 `!(isLocked ?? false)`（读不到就锁车），
    /// 卡片按钮那条却是 `(isLocked ?? true) ? .unlock : .lock`（读不到就**解锁**）——
    /// 同一台车、同一个"读不到"，两个表面按出两个相反的方向。
    ///
    /// 统一成：**只有确知车锁着的时候才发解锁，其余一律锁车。** 读不到、旧到不该再当真，
    /// 都归进"其余"。两个方向里这个是安全的那个——多锁一次没有损失，
    /// 而按反了就是在停车场里把车打开。
    var lockActionTarget: Bool { trustedLock != true }

    /// 按下车锁键时，这份快照还够不够格直接拿来定方向——够格就不必再跑一趟网络。
    ///
    /// 两个条件缺一不可：锁状态得读到过，而且不能旧过给定的窗口。
    /// 差任何一条都得联网重新确认（见 `WidgetControlRunner.resolvedLockTarget`），
    /// 因为那一按的方向就是照它算的，宁可让用户多等几秒也不能按反。
    func canDecideLockTarget(within seconds: TimeInterval) -> Bool {
        isLocked != nil && !isOlderThan(seconds)
    }

    /// 卡片上只留一句最该被看到的话。
    var headline: String {
        if anyDoorOpen { return "有车门未关闭" }
        if trunkOpen == true { return "尾门未关闭" }
        if hasTireWarning { return "胎压异常" }
        if windowsClosed == false { return "车窗未关闭" }
        if isCharging {
            if let limit = chargeLimit { return "充电中 · 上限 \(limit)%" }
            return "充电中"
        }
        if climateOn { return "空调运行中" }
        if let name = locationName, !name.isEmpty { return name }
        return isLocked == false ? "已解锁" : "已锁车"
    }

    var chargeRemainingText: String? {
        guard let minutes = chargeRemainMinutes, minutes > 0 else { return nil }
        let hours = minutes / 60
        let rest = minutes % 60
        if hours == 0 { return "还需 \(rest) 分" }
        return rest == 0 ? "还需 \(hours) 小时" : "还需 \(hours) 小时 \(rest) 分"
    }

    var chargePowerText: String? {
        guard let power = chargePowerKW, power.isFinite, power >= 0 else { return nil }
        return String(format: "%.1f kW", power)
    }

    /// 充电那一行有没有东西可说。两个都读不到就整行别出现——摆一行「剩余时间 --
    /// 功率 --」等于用两个占位符告诉用户「我不知道」，卡片上的每一行都该是信息。
    /// SOC 那种主数字读不到才用 `--` 顶着，因为不占位卡片会空一块；这一行不是。
    var hasChargeMetrics: Bool {
        chargeRemainingText != nil || chargePowerText != nil
    }

    /// 锁状态在卡片上的统一说法和图标。
    ///
    /// **别在各处各写一遍。** 判据分叉过一次：状态卡写的是 `isLocked != false`，
    /// 于是车端没报锁状态时画出一个绿色闭锁——等于替车说了句「锁好了」；
    /// 而同一时刻单功能锁车卡显示的是「状态未知」。同一台车，两张卡两个说法。
    /// 读不到就如实说读不到，这和「读不到的车况整行不显示」是同一条规矩。
    var lockText: String {
        switch isLocked {
        case true: "已锁车"
        case false: "已解锁"
        case nil: "状态未知"
        }
    }

    /// 读不到那个曾经写成 `lock.badge.questionmark`——**这个符号不存在**，
    /// SF Symbols 里没有它，运行时不报错，那个位置直接画成空白。凭印象写符号名
    /// 编译器不会拦，只能一个个验过：`NSImage(systemSymbolName:)` 返回非 nil 才算数。
    /// 一律用 `car.side.*` 这一家：光一把挂锁在锁屏上是**车锁还是手机锁**分不出来，
    /// 尤其是控制中心和锁屏底部那两个圆钮——那一片全是系统自己的开关，一把裸锁
    /// 混在里面读起来像"锁定屏幕"。带上车身之后歧义就没了。
    /// 读不到时用同家族的 `car.side.and.exclamationmark.fill`：形状和另外两个差得够远
    /// （锁 vs 叹号），而且它不对锁状态做任何断言。
    var lockSymbol: String { Self.lockSymbol(for: isLocked) }

    /// 锁屏控件手里只有一个 `Bool?`、没有整份快照，但它画的必须是同一个字形，
    /// 所以判据做成静态的给两边共用，而不是在控件那边再抄一遍这三行。
    static func lockSymbol(for isLocked: Bool?) -> String {
        switch isLocked {
        case true: "car.side.lock.fill"
        case false: "car.side.lock.open.fill"
        case nil: "car.side.and.exclamationmark.fill"
        }
    }

    /// 需要提醒用户的状态，卡片上要用警示色。
    var needsAttention: Bool {
        anyDoorOpen || trunkOpen == true || hasTireWarning || isLocked == false || windowsClosed == false
    }
}

/// 快照存放在 App Group 容器里，卡片进程才读得到。
/// 这里只放非敏感的展示数据——token 和操作密码始终留在 Keychain，不进这个文件。
struct SnapshotStore: Sendable {
    static let appGroup = "group.org.yipao.app"
    /// 车辆状态卡片（小/中/大 + 三种锁屏样式）。
    static let widgetKind = "LeapVehicleWidget"
    /// 只管锁车的单功能卡片（仅小尺寸）。
    static let lockWidgetKind = "LeapLockWidget"
    static let lockOnlyWidgetKind = "LeapLockOnlyWidget"
    static let unlockWidgetKind = "LeapUnlockWidget"
    /// 锁屏**最底部**那两个圆按钮位 / 控制中心 / 操作按钮上的控件。这些 kind 归 ControlCenter 管，
    /// 不是 WidgetCenter——刷错了那边不会有任何反应，也不会报错。
    static let lockControlKind = "LeapLockControl"
    static let lockOnlyControlKind = "LeapLockOnlyControl"
    static let unlockControlKind = "LeapUnlockControl"
    static let hornControlKind = "LeapHornControl"

    private static let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    static var hasSharedContainer: Bool { container != nil }

    private var fileURL: URL? {
        Self.container?.appendingPathComponent("vehicle-snapshot.json")
    }

    func read() -> VehicleSnapshot? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(VehicleSnapshot.self, from: data)
    }

    func write(_ snapshot: VehicleSnapshot) {
        guard let fileURL, let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func clear() {
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }
}

/// 桌面卡片和锁屏控件的刷新入口。
///
/// 单独收成一个地方是因为这两类表面归**两个不同的中心**管：卡片是 `WidgetCenter`，
/// 控件是 `ControlCenter`。只刷一边的话另一边会一直停在旧状态，而且不会有任何报错——
/// 表现是「App 里车已经锁上了，锁屏控件还是开锁的样子」。
enum LeapWidgets {
    /// 车况变了：卡片和控件一起刷。
    nonisolated static func reloadAll() {
        WidgetCenter.shared.reloadAllTimelines()
        ControlCenter.shared.reloadAllControls()
    }

    /// 只刷控件，一个时间线都不碰。
    ///
    /// 专给桌面卡片的时间线自己用：它每一轮都会拉一次车况、写回共享快照，
    /// 而控件读的是同一份文件却**收不到任何通知**——控件没有时间线，系统只在要渲染它的
    /// 时候问一次 `currentValue()`，没人叫它就一直停在上一次渲染的画面上。
    /// 锁屏上那个开关显示着几十分钟前的锁状态，一半原因在这儿：卡片的 10 分钟节奏
    /// 原来只服务卡片自己，控件搭不上便车。
    ///
    /// **不能在时间线里调 `reloadVehicleSurfaces`**：那个会连时间线一起刷，
    /// 等于在自己的时间线里请求刷新自己。
    nonisolated static func reloadControlsOnly() {
        ControlCenter.shared.reloadControls(ofKind: SnapshotStore.lockControlKind)
        ControlCenter.shared.reloadControls(ofKind: SnapshotStore.lockOnlyControlKind)
        ControlCenter.shared.reloadControls(ofKind: SnapshotStore.unlockControlKind)
        ControlCenter.shared.reloadControls(ofKind: SnapshotStore.hornControlKind)
    }

    /// 只刷跟车况有关的那几个表面。清会话、下发指令后都走它。
    nonisolated static func reloadVehicleStatus() {
        WidgetCenter.shared.reloadTimelines(ofKind: SnapshotStore.widgetKind)
    }

    nonisolated static func reloadVehicleSurfaces() {
        reloadVehicleStatus()
        WidgetCenter.shared.reloadTimelines(ofKind: SnapshotStore.lockWidgetKind)
        WidgetCenter.shared.reloadTimelines(ofKind: SnapshotStore.lockOnlyWidgetKind)
        WidgetCenter.shared.reloadTimelines(ofKind: SnapshotStore.unlockWidgetKind)
        reloadControlsOnly()
    }
}

/// 品牌色。App 和卡片都用这一份，避免两边慢慢跑偏。
enum LeapPalette {
    static let accent = Color(red: 0.30, green: 0.77, blue: 0.49)
    static let cool = Color(red: 0.42, green: 0.66, blue: 1.0)
    static let warm = Color(red: 1.0, green: 0.55, blue: 0.35)
    static let caution = Color(red: 1.0, green: 0.82, blue: 0.54)
}

/// App 与卡片共享的偏好。
enum SharedSettings {
    static var defaults: UserDefaults? { UserDefaults(suiteName: SnapshotStore.appGroup) }
    private static let widgetControlKey = "widgetControlEnabled"
    private static let directControlDefaultMigrationKey = "directControlDefaultEnabled.v1"

    /// 桌面卡片、锁屏和侧边按钮共用直控偏好；车锁控件仍由系统验证身份。
    static var widgetControlEnabled: Bool {
        get { SnapshotStore.hasSharedContainer && (defaults?.object(forKey: widgetControlKey) as? Bool ?? true) }
        set { defaults?.set(newValue, forKey: widgetControlKey) }
    }

    /// 新版首次启动统一开启，后续启动保留用户选择。
    @discardableResult
    static func migrateDirectControlDefault(in preferences: UserDefaults) -> Bool {
        guard !preferences.bool(forKey: directControlDefaultMigrationKey) else { return false }
        preferences.set(true, forKey: widgetControlKey)
        preferences.set(true, forKey: directControlDefaultMigrationKey)
        return true
    }

    private static let hasPasswordKey = "hasSavedOperationPassword"

    /// 本机存过操作密码没有。**只是个布尔标记，密码本身始终只在钥匙串里。**
    ///
    /// 为什么不直接去读钥匙串：操作密码那条是 `WhenUnlockedThisDeviceOnly`，
    /// **设备锁着就读不到**。而锁屏底部两个控件恰恰是在设备锁着时渲染的，
    /// 于是"能不能直接下发"永远算成 false，按钮永远渲染成链接——
    /// 表现就是「锁屏上点一下，进了 App，没控车」。
    ///
    /// 判断"该渲染成按钮还是链接"必须用锁屏也读得到的东西，所以走 UserDefaults。
    /// 真正下发时仍然老老实实读钥匙串，读不到就报错（见 `WidgetControlRunner.dispatch`）。
    static var hasSavedOperationPassword: Bool {
        get { defaults?.bool(forKey: hasPasswordKey) ?? false }
        set { defaults?.set(newValue, forKey: hasPasswordKey) }
    }

    private static let controlErrorKey = "lastControlError"
    private static let controlErrorAtKey = "lastControlErrorAt"

    /// 扩展进程上一次直接下发失败的原因，和失败时刻。
    ///
    /// 扩展里下发失败是**没有任何出口**的：卡片弹不了 toast，控件也没法把 App 顶到前台
    /// （`openAppWhenRun` 被编译器逼成了常量 false，见 `LockControlIntent`）。
    /// 不记下来的话，用户按一下、屏幕上什么都不发生，连"是不是我没按到"都判断不了——
    /// 这正是「卡片上锁车按了没反应」那次的实际观感。
    static var lastControlError: (text: String, at: Date)? {
        guard let text = defaults?.string(forKey: controlErrorKey),
              let at = defaults?.object(forKey: controlErrorAtKey) as? Date
        else { return nil }
        return (text, at)
    }

    /// 记一条失败；传 nil 表示这次成功了，把上一条抹掉。
    static func recordControlError(_ text: String?) {
        guard let text else {
            defaults?.removeObject(forKey: controlErrorKey)
            defaults?.removeObject(forKey: controlErrorAtKey)
            return
        }
        defaults?.set(text, forKey: controlErrorKey)
        defaults?.set(Date.now, forKey: controlErrorAtKey)
    }
}

/// 卡片和控件上那句「刚才那下没成」。
enum WidgetControlFeedback {
    /// 过了这么久就不再顶在卡片上了。一条五分钟前的失败还占着卡片顶部那行字，
    /// 只会把真正的车况挤掉。
    static let window: TimeInterval = 300

    /// 还该被顶在卡片上的失败原因，没有就是 nil。
    static var recentFailure: String? {
        guard let (text, at) = SharedSettings.lastControlError,
              Date.now.timeIntervalSince(at) < window
        else { return nil }
        return text
    }
}

/// 卡片点击后要跳到哪一屏。
enum LeapDeepLink {
    static let scheme = "leapcontrol"

    static func url(_ screen: String) -> URL {
        URL(string: "\(scheme)://\(screen)")!
    }

    static let home = url("home")
    static let charge = url("charge")
    static let climate = url("climate")
    static let location = url("location")

    /// 卡片上的控车按钮点进来：leapcontrol://action?a=toggleLock
    private static let actionHost = "action"

    static func action(_ rawValue: String) -> URL {
        URL(string: "\(scheme)://\(actionHost)?a=\(rawValue)")!
    }

    /// 取出控车动作的原始值；不是控车链接就返回 nil。
    static func actionRawValue(from url: URL) -> String? {
        guard url.scheme == scheme, url.host() == actionHost else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == "a" }?
            .value
    }
}
