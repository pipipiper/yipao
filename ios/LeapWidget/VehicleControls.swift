import AppIntents
import SwiftUI
import WidgetKit

/// 锁屏底部按钮位、控制中心、侧边操作按钮上的控件。
///
/// 这三处是同一样东西（`ControlWidget`），iOS 18 起用户可以把它拖到哪儿是哪儿。
/// 控件不是卡片：它没有时间线，系统要渲染时直接问 `ControlValueProvider` 要当前值。
///
/// **控件的车况从哪来。** 先看 App Group 里那份共享快照（卡片时间线和主 App 都写它），
/// 够新就直接用；旧了就当场拉一次，压 2.5 秒硬超时，拉不回来退回旧快照。
///
/// 原来这里是纯读快照、一个请求都不发的。理由是控制中心一拉开就要出结果，现跑
/// 「续期 token → 取路由 → 查车况」会让控件先空着再跳一下。但代价比那一下大得多：
/// 卡片时间线名义上 10 分钟一刷，实际给不给要看 WidgetKit 的预算，开车那一路手机
/// 没人看，快照可以几十分钟没人动。**而控件是个开关，显示什么就决定了按下去发哪个
/// 方向**（见 `LockControlIntent.value`）——车主实测：解锁后开了几十分钟，下车时
/// 控件上写着「已锁车」，按一下实际发出去的是解锁，车没锁上。
///
/// 所以现在是两道一起上：一是这里能拉就拉准，二是**按下去那一刻再拉一次**
/// （`WidgetControlRunner.resolvedLockTarget`）——渲染时读到的可以是旧的，但发出去的方向
/// 一定是照着刚拉回来的实时车况算的。显示和方向从此不共用一份数据。
///
/// **控件要能用，必须先在设置里打开「直接控车」。** 和桌面卡片不同，控件按下去没有
/// "打开 App 走一遍验证"这条退路——原因写在 `LockControlIntent` 上。所以开关关着时
/// 控件整个渲染成不可用，并在控件上写清楚为什么，而不是让人按了发现毫无反应。

// MARK: - 取值

/// 控件要用到的那一点点车况。
struct VehicleControlValue {
    /// 车端没报、或者手上这份已经旧到不该再当真，都是 nil——这里不替它做决定。
    var isLocked: Bool?
    var vehicleName: String
    var freshnessText: String
    /// 扩展进程此刻能不能真的把指令发出去。发不出去的话控件渲染成不可用。
    var canDispatch: Bool
    /// 上一次按下去没成的原因。锁屏上按一下毫无动静最让人心里没底——
    /// 车到底锁没锁？所以这条要顶到控件那行小字上。
    var failure: String?

    init(snapshot: VehicleSnapshot?, canDispatch: Bool, failure: String? = nil) {
        // **读到什么显示什么，多旧都照显示。** 旁边那行小字（`freshnessText`）会说清楚
        // 是"刚刚"还是"3 小时前"，由用户自己判断值不值得信——藏起来反而是替他做决定。
        //
        // 中间有一版不是这样：超过 30 分钟就把锁状态降级成"未知"（`trustedLock`）。
        // 那是在拿显示层兜方向层的底——控件是个开关，当时按下去发哪个方向是照着显示算的，
        // 显示「已锁车」按一下就是解锁，所以只能靠"显示不出笃定的样子"来避免按反。
        //
        // 现在方向不走这条路了：按下去那一刻会**先联网**拉一次实时车况、按车的真实状态
        // 定方向（判据在 `WidgetControlRunner.resolvedLockTarget`；手上这份够新且状态
        // 明确时才省掉那一趟）。
        // 显示旧不旧，和发出去的是锁还是解锁，从此是两件事。
        isLocked = snapshot?.isLocked
        vehicleName = snapshot?.vehicleName ?? "车辆"
        freshnessText = snapshot?.freshnessText ?? "尚未同步"
        self.canDispatch = canDispatch
        self.failure = failure
    }

    /// 控件底下那行小字。刚失败过就先说失败，其次说清楚缺什么，最后才是车况有多旧。
    var statusLine: String {
        if let failure { return failure }
        guard canDispatch else {
            return SharedSettings.widgetControlEnabled ? "需在 App 内保存操作密码" : "直接控车已关闭"
        }
        return "\(vehicleName) · \(freshnessText)"
    }

    /// 读不到锁状态时，控件按「未锁」渲染。
    ///
    /// 开关只有两态，nil 没地方放，总得挑一边。挑「未锁」是因为它对应的琥珀底色
    /// 是"你可能忘了点什么"，比一个笃定的闭锁图标更接近"我也不知道"。
    /// 同时用 `controlWidgetStatus` 如实写出"状态未知"，不让这个猜测冒充读到的数据。
    ///
    /// 这个猜测**不再决定按下去发什么**——那一步会自己去联网
    /// （见 `WidgetControlRunner.resolvedLockTarget`），只有联网也失败时才回落到这里。
    var showsLocked: Bool { isLocked ?? false }

    /// 控件上那个字形。锁屏那一片是单色渲染的，颜色传达不了信息，形状是唯一的载体，
    /// 所以读不到时画的是"不做断言"的那个，而不是跟着 `showsLocked` 画成开锁——
    /// 那个猜测只用来决定按钮亮不亮，不该冒充成读到的车况。
    var lockSymbol: String { VehicleSnapshot.lockSymbol(for: isLocked) }

    var statusText: String {
        switch isLocked {
        case true: "已锁车"
        case false: "已解锁"
        case nil: "状态未知"
        }
    }
}

struct VehicleControlValueProvider: ControlValueProvider {
    /// 添加控件时那一屏的预览值。这里一律按"可用"画，
    /// 挑控件的时候给人看一个灰掉的样品没有任何意义。
    var previewValue: VehicleControlValue {
        VehicleControlValue(snapshot: .placeholder, canDispatch: true)
    }

    func currentValue() async throws -> VehicleControlValue {
        await VehicleControlValue(
            snapshot: Self.snapshot(),
            canDispatch: WidgetControlRunner.canDispatchDirectly,
            failure: WidgetControlFeedback.recentFailure
        )
    }

    /// 控件要显示的那份车况：够新就用共享的，旧了当场拉一次。
    ///
    /// 复用窗口和卡片时间线共用一个（`reuseWindow`）：卡片刚拉过的那一份直接拿来用，
    /// 省一趟请求，顺带保证同一时刻控件和卡片说的是同一件事。
    ///
    /// 拉取用 `fetch` 而不是 `latest`：后者拉不到会退回 `.placeholder`，而占位值里的
    /// `isLocked` 是 `true`——卡片上无所谓，控件上那就是替一台没读到状态的车说了句
    /// 「锁好了」，而按下去的方向正是照着这句话算的。
    ///
    /// 超时取 2.5 秒：控件没有时间线，系统要渲染时当场问值，等太久整个控件会渲染不出来。
    /// 拉不回来就退回旧快照，由 `VehicleControlValue` 那道 `isStale` 兜住方向。
    private static func snapshot() async -> VehicleSnapshot? {
        guard SnapshotStore.hasSharedContainer else { return nil }
        let cached = SnapshotStore().read()
        if let cached, Date.now.timeIntervalSince(cached.updatedAt) < WidgetVehicleFetcher.reuseWindow {
            return cached
        }
        let fetched: VehicleSnapshot? = await WidgetTimeout.within(
            seconds: 2.5,
            fallback: nil
        ) {
            await WidgetVehicleFetcher.fetch(reusing: cached)
        }
        return fetched ?? cached
    }
}

// MARK: - 车锁

struct VehicleLockControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: SnapshotStore.lockControlKind,
            provider: VehicleControlValueProvider()
        ) { value in
            // 开关拨到哪一边，系统就把那个 Bool 填进 `LockControlIntent.value`，
            // 所以这里构造一个空的就行，不用自己算目标态。
            //
            // **"开"态是「已解锁」，不是「已锁车」。** 控件的底色只由 `isOn` 决定
            // （填色 / 透明，没有第三种），所以要哪一态亮就得把哪一态定义成"开"。
            // 亮的应该是解锁：锁着是常态，锁屏上一眼扫过去满屏都是亮着的按钮反而看不出
            // 哪个要紧；车开着才是那个"你可能忘了点什么"的状态，值得亮起来。
            // 代价是 `LockControlIntent.value` 的方向也得跟着是「解锁」，两边一起改。
            ControlWidgetToggle(isOn: !value.showsLocked, action: LockControlIntent()) {
                Label(value.statusText, systemImage: value.lockSymbol)
                    .controlWidgetStatus(value.statusLine)
            }
            // 琥珀而不是品牌绿：亮起来的是「车开着」，而 App 内外这件事一直是琥珀色
            // （`LockWidgetPalette.tint`）。这里用绿会让同一台车在卡片上和锁屏上说反话。
            .tint(LeapPalette.caution)
            .disabled(!value.canDispatch)
        }
        .displayName("车锁")
        .description("在锁屏或控制中心锁车、解锁。需先在 App 设置里打开「直接控车」。")
    }
}

struct VehicleLockOnlyControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: SnapshotStore.lockOnlyControlKind,
            provider: VehicleControlValueProvider()
        ) { value in
            ControlWidgetButton(action: LockOnlyControlIntent()) {
                Label("上锁车辆", systemImage: ControlActivityAction.lock.symbol)
                    .controlWidgetActionHint("上锁车辆")
                    .controlWidgetStatus(value.statusLine)
            }
            .tint(LeapPalette.accent)
            .disabled(!value.canDispatch)
        }
        .displayName("上锁车辆")
        .description("仅上锁车辆，需开启直接控车并通过系统身份验证。")
    }
}

struct VehicleUnlockControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: SnapshotStore.unlockControlKind,
            provider: VehicleControlValueProvider()
        ) { value in
            ControlWidgetButton(action: UnlockControlIntent()) {
                Label("解锁车辆", systemImage: ControlActivityAction.unlock.symbol)
                    .controlWidgetActionHint("解锁车辆")
                    .controlWidgetStatus(value.statusLine)
            }
            .tint(LeapPalette.caution)
            .disabled(!value.canDispatch)
        }
        .displayName("解锁车辆")
        .description("仅解锁车辆，需开启直接控车并通过系统身份验证。")
    }
}

// MARK: - 鸣笛寻车

/// 鸣笛本身没有状态可言，但仍然要接取值器：得知道「直接控车」开没开，
/// 否则开关关着时这个按钮按下去会完全没反应。
struct VehicleHornControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: SnapshotStore.hornControlKind,
            provider: VehicleControlValueProvider()
        ) { value in
            ControlWidgetButton(action: HornControlIntent()) {
                Label("鸣笛寻车", systemImage: "speaker.wave.2.fill")
                    .controlWidgetActionHint("鸣笛")
                    .controlWidgetStatus(value.statusLine)
            }
            .tint(LeapPalette.cool)
            .disabled(!value.canDispatch)
        }
        .displayName("鸣笛寻车")
        .description("让车鸣笛闪灯，在停车场里找到它。需先在 App 设置里打开「直接控车」。")
    }
}
