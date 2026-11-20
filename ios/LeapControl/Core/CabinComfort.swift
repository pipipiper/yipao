import Foundation

// MARK: - 座椅

/// 可远控的座位。协议里 `position` 字段只认这四个值，第三排没有任何对应值与信号。
///
/// 下发走 cmdid `301`（加热）/ `370`（通风），state 是 `{"position":"left_front","level":"2"}`。
/// 两个 cmdid 在我们自己从官方 `CarPerManager` 解出的能力码全表里都在
/// （`21/85/93 → 301`、`42/43 → 370`），但官方 APK 里一个中文名都没解出来——
/// 官方 App 自己没做这个功能。语义来自 leapauto，对照本项目能力码表与一台 C16 的
/// `abilities` 双向印证。
enum SeatPosition: String, CaseIterable, Identifiable, Sendable {
    case driver
    case passenger
    case leftRear
    case rightRear

    var id: String { rawValue }

    /// 下发用的 `position` 值。
    var wireValue: String {
        switch self {
        case .driver: "left_front"
        case .passenger: "right_front"
        case .leftRear: "left_rear"
        case .rightRear: "right_rear"
        }
    }

    var label: String {
        switch self {
        case .driver: "主驾"
        case .passenger: "副驾"
        case .leftRear: "二排左"
        case .rightRear: "二排右"
        }
    }

    var isRear: Bool { self == .leftRear || self == .rightRear }

    static let front: [SeatPosition] = [.driver, .passenger]
    static let rear: [SeatPosition] = [.leftRear, .rightRear]
}

/// 座椅的加热和通风通道，各自上报档位。
enum SeatComfortChannel: String, CaseIterable, Identifiable, Sendable {
    case heating
    case ventilation

    var id: String { rawValue }

    var label: String {
        switch self {
        case .heating: "加热"
        case .ventilation: "通风"
        }
    }

    var symbol: String {
        switch self {
        case .heating: "heat.waves"
        case .ventilation: "wind"
        }
    }

    /// 座椅两条通道都是 0…3 档。
    var maxLevel: Int { 3 }

    var cmdid: String {
        switch self {
        case .heating: "301"
        case .ventilation: "370"
        }
    }

    /// 这个座位 + 这条通道对应的车况信号。
    func signal(for position: SeatPosition) -> VehicleSignal {
        switch (self, position) {
        case (.heating, .driver): .driverSeatHeating
        case (.heating, .passenger): .passengerSeatHeating
        case (.heating, .leftRear): .leftRearSeatHeating
        case (.heating, .rightRear): .rightRearSeatHeating
        case (.ventilation, .driver): .driverSeatVentilation
        case (.ventilation, .passenger): .passengerSeatVentilation
        case (.ventilation, .leftRear): .leftRearSeatVentilation
        case (.ventilation, .rightRear): .rightRearSeatVentilation
        }
    }
}

// MARK: - 车载冰箱

/// 冰箱运行模式。协议里**只有两个值**——没有独立的「冷冻」模式，
/// 「冷藏 / 冷冻」是同一个 `cold` 模式下的不同目标温度（见 `FridgePreset`）。
enum FridgeMode: String, CaseIterable, Sendable {
    case cold
    case hot

    var label: String {
        switch self {
        case .cold: "制冷"
        case .hot: "保温"
        }
    }

    /// 上报信号 `10708`：0 = 制冷、1 = 保温暖食。
    static func fromSignal(_ raw: Int?) -> FridgeMode { raw == 1 ? .hot : .cold }
}

/// 制冷风格。
///
/// ⚠️ leapauto 的接口文档写 `fast`、它自己的代码写 `turbo`，两者只能有一个对。
/// 这里按**代码**走（代码更接近他们实际跑的东西）；真车发了不认时，
/// 第一个要试的替代值就是 `fast`。
enum FridgeStyle: String, CaseIterable, Sendable {
    case normal
    case turbo

    var label: String {
        switch self {
        case .normal: "标准"
        case .turbo: "急速"
        }
    }

    /// 上报信号 `10711`：0 = 标准、1 = 急速。
    static func fromSignal(_ raw: Int?) -> FridgeStyle { raw == 1 ? .turbo : .normal }
}

/// 界面上的三个预设。协议侧只是 `mode` + `temp` 的两种组合，
/// 「冷冻」是制冷模式压到量程下限，不是另一个模式。
enum FridgePreset: String, CaseIterable, Identifiable, Sendable {
    case chill
    case freeze
    case keepWarm

    var id: String { rawValue }

    var label: String {
        switch self {
        case .chill: "冷藏"
        case .freeze: "冷冻"
        case .keepWarm: "保温"
        }
    }

    var symbol: String {
        switch self {
        case .chill: "snowflake"
        case .freeze: "snowflake.circle.fill"
        case .keepWarm: "cup.and.saucer.fill"
        }
    }

    var mode: FridgeMode {
        switch self {
        case .chill, .freeze: .cold
        case .keepWarm: .hot
        }
    }

    var temperature: Int {
        switch self {
        case .chill: FridgeSetting.chillTemp
        case .freeze: FridgeSetting.minTemp
        case .keepWarm: FridgeSetting.hotTemp
        }
    }

    /// 当前设定落在哪个预设上。都不落就是 nil（三个都不高亮）。
    static func matching(mode: FridgeMode, temperature: Int) -> FridgePreset? {
        switch mode {
        case .hot: return .keepWarm
        case .cold:
            if temperature == FridgeSetting.chillTemp { return .chill }
            if temperature == FridgeSetting.minTemp { return .freeze }
            return nil
        }
    }
}

/// 一份完整的冰箱设定。cmdid `500` 的 state 是**全量**的——
/// 改一项也要把八个字段一起发出去，所以界面那边维护的是整份草稿，不是增量。
struct FridgeSetting: Equatable, Sendable {
    /// 制冷目标温度量程，协议给的是 −6…15 ℃。
    static let minTemp = -6
    static let maxTemp = 15
    /// 冷藏预设温度。
    static let chillTemp = 4
    /// 保温模式固定下发这个温度（协议写死 50 ℃ 恒温）。
    static let hotTemp = 50
    /// 离车工作时长下限：leapauto 的实现把 `duration` 夹到 ≥1800 秒，照搬。
    static let minDurationSeconds = 1800

    var enabled: Bool = true
    var mode: FridgeMode = .cold
    /// 制冷目标温度。`mode == .hot` 时下发前会被换成 `hotTemp`，这里存的仍是用户调的制冷温度，
    /// 这样从保温切回制冷不会把他调好的温度弄丢。
    var temperature: Int = FridgeSetting.chillTemp
    var style: FridgeStyle = .normal
    var parkEnabled: Bool = false
    var parkHours: Int = 1

    /// 真正下发的温度值。
    var wireTemperature: Int {
        mode == .hot ? Self.hotTemp : min(Self.maxTemp, max(Self.minTemp, temperature))
    }

    var durationSeconds: Int { max(Self.minDurationSeconds, parkHours * 3600) }

    var preset: FridgePreset? { FridgePreset.matching(mode: mode, temperature: wireTemperature) }

    /// 套用一个预设。保温不覆盖用户调过的制冷温度（见 `temperature` 的说明）。
    mutating func apply(_ preset: FridgePreset) {
        mode = preset.mode
        if preset.mode == .cold { temperature = preset.temperature }
    }

    /// 全量 state JSON。字段顺序按 key 排序，和 `JSONSerialization` 的输出保持一致，便于比对。
    ///
    /// `cycles` 这一版固定发 `"1"`：下发口径（`"1"` / `"2"`）和上报口径（`0` / `1`）对不上，
    /// 哪个值是「仅本次离车」哪个是「每次离车」没有依据，所以不暴露这个开关。
    /// `value` 字段含义不明，协议样本里恒为 `"false"`，照常量发。
    var stateJSON: String {
        let payload: [String: Any] = [
            "cycles": "1",
            "duration": durationSeconds,
            "enable": enabled ? 1 : 0,
            "mode": mode.rawValue,
            "parkEnable": parkEnabled ? 1 : 0,
            "style": style.rawValue,
            "temp": wireTemperature,
            "value": "false"
        ]
        let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

/// 车端报回来的冰箱状态。`fridgeSwitch` 读不到就整个是 nil——
/// 没装这个选装件的车（车主那台 C16 就是）不该凭空得到一份默认值。
struct FridgeState: Equatable, Sendable {
    var enabled: Bool
    var mode: FridgeMode
    var targetTemp: Int?
    var style: FridgeStyle
    /// 自检故障码，0 为正常。
    var fault: Int
    var parkEnabled: Bool
    var parkHours: Int?
    /// 离车保温截止时刻。车端给的是秒级时间戳，0 当没有。
    var parkEndsAt: Date?

    var hasFault: Bool { fault != 0 }

    /// 把车况当成界面草稿的初值。目标温度读不到时退回冷藏预设，
    /// 这不是「伪造车况」——草稿本来就是本机要发的东西，必须有个值。
    var asSetting: FridgeSetting {
        FridgeSetting(
            enabled: enabled,
            mode: mode,
            temperature: mode == .hot
                ? FridgeSetting.chillTemp
                : (targetTemp ?? FridgeSetting.chillTemp),
            style: style,
            parkEnabled: parkEnabled,
            parkHours: parkHours ?? 1
        )
    }
}

// MARK: - 车况派生

extension VehicleState {
    /// 某个座位某条通道的当前档位。**读不到返回 nil**，界面整块隐藏，不退 0——
    /// 退 0 等于断言「这个座位有加热、现在是关的」，而实际可能是这车根本没这个座位。
    func seatLevel(_ position: SeatPosition, _ channel: SeatComfortChannel) -> Int? {
        guard let value = int(channel.signal(for: position)) else { return nil }
        return min(channel.maxLevel, max(0, value))
    }

    /// 这条通道上有档位可读的座位。空数组表示整条通道都读不到。
    func seats(with channel: SeatComfortChannel) -> [SeatPosition] {
        SeatPosition.allCases.filter { seatLevel($0, channel) != nil }
    }

    /// 二排两座里有任何一项可读。决定座位图画 2×2 还是只画前排。
    var hasRearSeatComfort: Bool {
        SeatComfortChannel.allCases.contains { channel in
            SeatPosition.rear.contains { seatLevel($0, channel) != nil }
        }
    }

    var hasSeatComfort: Bool {
        SeatComfortChannel.allCases.contains { !seats(with: $0).isEmpty }
    }

    /// 舒适座舱页上**至少有一块东西能显示**。整页的门控用它，
    /// 而不是用能力码——信号比能力码更贴车端，方向盘加热还压根没有能力码。
    var hasCabinComfort: Bool {
        hasSeatComfort || steeringWheelHeatLevel != nil || mirrorHeatingOn != nil
    }

    /// 方向盘加热档位：0 关、1 弱、2 强。读不到 nil。
    var steeringWheelHeatLevel: Int? {
        guard let value = int(.steeringWheelHeating) else { return nil }
        return min(2, max(0, value))
    }

    /// 方向盘加热剩余分钟。
    ///
    /// **只在加热确实开着时才给值。** 信号 `1624` 在加热关闭时也非 0——C16 实测
    /// `1816 = 0`（没开）而 `1624` 先是 `2`、后来跳到 `15`。拿它当「正在加热」的佐证
    /// 会在界面上凭空报出一个加热中，所以这里用 `1816` 把门。
    var steeringWheelHeatMinutes: Int? {
        guard let level = steeringWheelHeatLevel, level > 0 else { return nil }
        guard let minutes = int(.steeringWheelHeatMinutes), minutes > 0 else { return nil }
        return minutes
    }

    /// 后视镜加热开没开。两侧任一为开即算开；两侧都读不到返回 nil。
    var mirrorHeatingOn: Bool? {
        let left = int(.leftMirrorHeating)
        let right = int(.rightMirrorHeating)
        guard left != nil || right != nil else { return nil }
        return (left ?? 0) > 0 || (right ?? 0) > 0
    }

    /// 两侧后视镜加热状态不一致。只有两侧都读到才有意义。
    var mirrorHeatingMismatched: Bool {
        guard let left = int(.leftMirrorHeating), let right = int(.rightMirrorHeating) else { return false }
        return (left > 0) != (right > 0)
    }

    /// 后风挡（含外后视镜）电加热除雾。cmdid 440 的第三个候选确认位。
    var rearWindowHeatingOn: Bool? {
        guard let value = int(.rearWindowHeating) else { return nil }
        return value > 0
    }

    /// 冰箱状态。`fridgeSwitch` 读不到即 nil。
    var fridgeState: FridgeState? {
        guard let switchValue = int(.fridgeSwitch) else { return nil }
        let endSeconds = double(.fridgeParkEndTime) ?? 0
        return FridgeState(
            enabled: switchValue == 1,
            mode: FridgeMode.fromSignal(int(.fridgeMode)),
            targetTemp: int(.fridgeTargetTemp),
            style: FridgeStyle.fromSignal(int(.fridgeStyle)),
            fault: int(.fridgeFault) ?? 0,
            parkEnabled: int(.fridgeParkSwitch) == 1,
            parkHours: int(.fridgeParkDurationHours),
            parkEndsAt: endSeconds > 0 ? Date(timeIntervalSince1970: endSeconds) : nil
        )
    }
}

// MARK: - 指令

extension LeapCommand {
    /// 座椅加热 / 通风。`level` 0 就是关闭，没有单独的关闭指令。
    static func seatComfort(
        position: SeatPosition,
        channel: SeatComfortChannel,
        level: Int
    ) -> LeapCommand {
        let clamped = min(channel.maxLevel, max(0, level))
        let action = clamped == 0 ? "关闭" : " \(clamped) 档"
        return LeapCommand(
            cmdid: channel.cmdid,
            stateJSON: #"{"position":"\#(position.wireValue)","level":"\#(clamped)"}"#,
            label: "\(position.label)\(channel.label)\(action)",
            expectation: .seatLevel(position: position, channel: channel, level: clamped)
        )
    }

    /// 方向盘加热。`level` 0 关、1 弱、2 强——**只有两档**，和座椅不是一套量程。
    ///
    /// ⚠️ `level` 这里发的是 **JSON 数字**，不是座椅那样的字符串。leapauto 的代码发数字、
    /// 它自己的文档写字符串，两者只能有一个对，按代码走。真车不动时第一个要试的就是
    /// 换成 `{"level":"2"}`。
    static func steeringWheelHeating(level: Int) -> LeapCommand {
        let clamped = min(2, max(0, level))
        let action = switch clamped {
        case 0: "关闭"
        case 1: "弱档"
        default: "强档"
        }
        return LeapCommand(
            cmdid: "320",
            stateJSON: #"{"level":\#(clamped)}"#,
            label: "方向盘加热\(action)",
            expectation: .steeringWheelLevel(clamped)
        )
    }

    /// 后视镜加热。开 `"2"`、关 `"1"`——**不是 `"1"`/`"0"`**。
    ///
    /// 这是五项里唯一官方 App 自己都没做的：内部码 `440` 在官方 APK 里连中文文案都没有
    /// （见 `permission-codes-map.md` 的「APK 内确实无中文名的码」）。能力码 `59 → 440` 在
    /// 车主车上在场，信号 `49`/`50`/`1946` 也在报，但下发这条没有任何实车样本。
    static func mirrorHeating(on: Bool) -> LeapCommand {
        LeapCommand(
            cmdid: "440",
            stateJSON: on ? #"{"value":"2"}"# : #"{"value":"1"}"#,
            label: on ? "开启后视镜加热" : "关闭后视镜加热",
            expectation: .mirrorHeating(on)
        )
    }

    /// 车载冰箱。state 是全量的，见 `FridgeSetting.stateJSON`。
    static func fridge(_ setting: FridgeSetting) -> LeapCommand {
        let label: String
        if !setting.enabled {
            label = "关闭车载冰箱"
        } else if setting.mode == .hot {
            label = "冰箱保温 \(FridgeSetting.hotTemp) ℃"
        } else {
            label = "冰箱制冷 \(setting.wireTemperature) ℃ · \(setting.style.label)"
        }
        return LeapCommand(
            cmdid: "500",
            stateJSON: setting.stateJSON,
            label: label,
            expectation: .fridge(setting)
        )
    }
}
