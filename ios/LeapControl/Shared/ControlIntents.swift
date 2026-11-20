import AppIntents
import WidgetKit

/// 卡片按钮能触发的动作。
enum WidgetAction: String, AppEnum {
    case toggleLock
    case toggleClimate
    case trunk
    case horn
    case lock
    case unlock

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "控车动作" }

    static var caseDisplayRepresentations: [WidgetAction: DisplayRepresentation] {
        [
            .toggleLock: "锁车 / 解锁",
            .toggleClimate: "开关空调",
            .trunk: "尾门",
            .horn: "鸣笛寻车",
            .lock: "上锁车辆",
            .unlock: "解锁车辆"
        ]
    }

    var title: String {
        switch self {
        case .toggleLock: "车锁"
        case .toggleClimate: "空调"
        case .trunk: "尾门"
        case .horn: "鸣笛寻车"
        case .lock: "上锁车辆"
        case .unlock: "解锁车辆"
        }
    }

    var symbol: String {
        switch self {
        case .toggleLock, .lock: "lock.fill"
        case .unlock: "lock.open.fill"
        case .toggleClimate: "fan"
        case .trunk: "car.side.rear.crop.trunk.partition"
        case .horn: "speaker.wave.2.fill"
        }
    }

    /// 快捷入口和旧版卡片使用的控车深链。
    var deepLink: URL { LeapDeepLink.action(rawValue) }

    /// 从卡片深链里还原动作；不是控车链接就返回 nil。
    init?(deepLink url: URL) {
        guard let raw = LeapDeepLink.actionRawValue(from: url) else { return nil }
        self.init(rawValue: raw)
    }
}

extension Notification.Name {
    static let leapWidgetAction = Notification.Name("leap.widget.action")
}

/// 小尺寸卡片不支持多个 Link，使用明确要求前台运行的意图保留每颗按钮的操作。
struct OpenVehicleActionIntent: AppIntent {
    static var title: LocalizedStringResource { "打开 App 控车" }
    static var openAppWhenRun: Bool { true }
    static var isDiscoverable: Bool { false }
    static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }

    @Parameter(title: "动作") var action: WidgetAction

    init() {}
    init(action: WidgetAction) { self.action = action }

    @MainActor
    func perform() async throws -> some IntentResult {
        SharedSettings.pendingWidgetAction = action.rawValue
        NotificationCenter.default.post(name: .leapWidgetAction, object: nil)
        return .result()
    }
}

/// 桌面卡片上的控车按钮。
///
/// 卡片扩展弹不出 Face ID（LocalAuthentication 需要宿主 App 的界面），
/// 所以这里分两条路：
/// - 用户在设置里开了「卡片直接控车」且本机存了操作密码：扩展进程直接下发。
/// - 否则：打开 App，由 App 走 Face ID + 操作密码的完整流程。
///
/// 新版默认开启直控，用户可关闭；未保存操作密码时仍走 App 验证。
///
/// 此意图只负责后台直控；需要前台验证时使用 `OpenVehicleActionIntent`。
/// 控车意图都额外声明 `LiveActivityIntent`。
///
/// 不是装饰：扩展进程默认**不允许**调 `Activity.request`，起不来也不报错，
/// 就是没有灵动岛。带上这个标记之后系统才放行。
struct VehicleControlIntent: AppIntent, LiveActivityIntent {
    static var title: LocalizedStringResource { "控制车辆" }
    static var description: IntentDescription { "从桌面卡片发送控车指令。" }

    /// 直接控车整条都在扩展进程里跑完，不需要把 App 顶到前台。
    static var openAppWhenRun: Bool { false }

    /// **不要出现在快捷指令库里。** 这个意图是给卡片按钮用的，
    /// 默认值 `true` 意味着任何人在这台手机上建个快捷指令就能调它控车——
    /// 桌面卡片至少还要先解锁才碰得到，快捷指令连那道门槛都没有。
    /// 两个锁屏控件一开始就关了，只有这个漏了。
    static var isDiscoverable: Bool { false }

    /// 桌面卡片本来就要手机解锁才碰得到，这里维持 `.alwaysAllowed`——
    /// 改成每次点锁车键都过一遍 Face ID，就和「直接控车」这个开关的意义相抵了。
    /// 但**必须显式写出来**：吃默认值的话，将来 SDK 改了默认档位不会有任何提示。
    /// 而且静态属性只能直接写在类型里，写进协议扩展 `appintentsmetadataprocessor` 看不见。
    static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }

    @Parameter(title: "动作")
    var action: WidgetAction

    init() {}

    init(action: WidgetAction) {
        self.action = action
    }

    func perform() async throws -> some IntentResult {
        try await WidgetControlRunner.run(action)
        return .result()
    }
}

// MARK: - 扩展进程里的下发

/// 卡片按钮和锁屏控件共用的那条"直接下发"实现。
///
/// 抽出来只为一件事：这段逻辑现在有三个调用方（桌面卡片的 `VehicleControlIntent`、
/// 锁屏的 `LockControlIntent` 和 `HornControlIntent`），复制三份的话乐观更新、
/// 回读车况、刷新哪几个表面这些细节会各自跑偏。
/// 扩展这一侧根本发不出去的原因。文案会原样显示在卡片上，所以要写成给车主看的话。
enum WidgetControlUnavailable: LocalizedError {
    case noOperationPassword
    case trunkWhileDriving
    case readOnlyWidget

    var errorDescription: String? {
        switch self {
        case .noOperationPassword: "本机没存操作密码，打开 App 控车"
        case .trunkWhileDriving: "行驶中不能操作尾门"
        case .readOnlyWidget: "此版本的小组件只显示车况，请打开 App 控车"
        }
    }
}

extension ControlActivityAction {
    /// 把"切换"翻译成"这一次到底在做什么"。
    ///
    /// `desiredLock` 只有锁屏那个开关会给；卡片上的按钮没有这个信息，只能照快照取反——
    /// 这和 `WidgetControlRunner.command(for:snapshot:)` 里那份取反必须**用同一份判据**，
    /// 否则灵动岛上写着"正在锁车"、发出去的却是解锁。
    init(_ action: WidgetAction, desiredLock: Bool?, snapshot: VehicleSnapshot?) {
        switch action {
        case .lock: self = .lock
        case .unlock: self = .unlock
        case .toggleLock:
            self = (desiredLock ?? (snapshot?.lockActionTarget ?? true)) ? .lock : .unlock
        case .toggleClimate:
            self = (snapshot?.climateOn ?? false) ? .climateOff : .climateOn
        case .trunk:
            self = .trunk
        case .horn:
            self = .horn
        }
    }

    /// 下发之后回读到的车况，能不能证实这个动作真的生效了。
    ///
    /// 尾门和鸣笛永远返回 false：车端根本不报"刚刚响过没有"，
    /// 而尾门那个开合过程比回读那 3 秒长得多，读到的多半还是旧位置。
    /// 这两个动作只能停在「指令已发出」，不去猜。
    func confirms(_ snapshot: VehicleSnapshot?) -> Bool {
        guard let snapshot else { return false }
        switch self {
        case .lock: return snapshot.isLocked == true
        case .unlock: return snapshot.isLocked == false
        case .climateOn: return snapshot.climateOn
        case .climateOff: return !snapshot.climateOn
        case .trunk, .horn: return false
        }
    }

    /// 车端会不会把这个动作的结果报上来。
    ///
    /// 尾门和鸣笛不报（理由见 `confirms`），`confirms` 对它们恒为 false——
    /// 拿它当轮询的退出条件就永远退不出来，白等满三轮。这两个拉到一份就收工。
    var isVerifiable: Bool {
        switch self {
        case .lock, .unlock, .climateOn, .climateOff: true
        case .trunk, .horn: false
        }
    }

    /// 是不是在动车锁。回读没能证实时要不要把锁状态标成"读不到"，只对这两个成立。
    var isLockAction: Bool { self == .lock || self == .unlock }
}

enum WidgetControlRunner {
    /// 跑一个动作：能直接下发就下发，不能就把它留给 App。
    ///
    /// `desiredLock` 只有锁屏那个开关会传，而且**只是个兜底值**：它是照渲染那一刻的
    /// 车况算出来的，而渲染可能发生在几十分钟前。真正的方向由 `resolvedLockTarget`
    /// 在按下去这一刻重新确定（够新就信快照，否则联网），只有那一步也失败才用它。
    /// 卡片上的按钮没有这个信息，传 nil，同样走 `resolvedLockTarget`。
    /// 失败一律记进 `SharedSettings.lastControlError` 再抛出去。
    ///
    /// 扩展进程没有任何别的出口能告诉用户"刚才那下没成"——卡片弹不了 toast，
    /// 控件也拉不起 App。这个 catch 不吞错误，只是让它在卡片上留下一句话；
    /// 记完立刻 reload，用户抬眼就能看见，而不是对着一张没有任何变化的卡片发呆。
    static func run(_ action: WidgetAction, desiredLock: Bool? = nil) async throws {
        guard SnapshotStore.hasSharedContainer else { throw WidgetControlUnavailable.readOnlyWidget }
        // 灵动岛那一条要在**任何 guard 之前**起：按下去没成也得说话，
        // 而"本机没存操作密码"恰恰是最需要当场解释的那种失败。
        let before = SnapshotStore().read()
        // 车锁的方向在这里重算一次，可能会去联网。**必须在这一行之后才用 `desiredLock`**——
        // 下面四个地方都要拿方向：灵动岛那句文案、乐观更新、真正发出去的指令、
        // 回读时用来比对的期望值。在入口重算一次它们就自动对齐；
        // 谁漏用了 `target` 谁就会出现"灵动岛写着正在锁车、发出去的是解锁"。
        let target = await resolvedLockTarget(action, desiredLock: desiredLock, snapshot: before)
        // `before` 可能已经被上面那趟联网写新了（如果真去拉了），这里只拿它取个车名。
        let described = ControlActivityAction(action, desiredLock: target, snapshot: SnapshotStore().read())
        let session = await ControlActivitySession.begin(
            described,
            vehicleName: before?.vehicleName ?? "车辆"
        )
        do {
            let after = try await dispatch(action, desiredLock: target)
            SharedSettings.recordControlError(nil)
            await session?.finish(
                described.confirms(after) ? .confirmed : .sent,
                action: described,
                detail: nil
            )
        } catch {
            SharedSettings.recordControlError(error.localizedDescription)
            LeapWidgets.reloadVehicleSurfaces()
            await session?.finish(.failed, action: described, detail: error.localizedDescription)
            throw error
        }
    }

    /// 把车况重新拉一遍写回共享快照，然后叫醒所有表面。给大卡那颗刷新键用。
    ///
    /// 压 10 秒硬超时：这一趟跑在扩展进程里，最坏要走「续期 token → 取路由 → 查车况」
    /// 三个请求，卡住的话系统会直接干掉进程，卡片停在原画面，看着像按了没反应。
    /// 超时或没登录就什么都不写——**绝不清空**，宁可让人看见一份旧车况，
    /// 也不能按一下刷新反而把卡片按空了。
    static func refreshSnapshot() async {
        guard SnapshotStore.hasSharedContainer else { return }
        let before = SnapshotStore().read()
        let refreshed: VehicleSnapshot? = await WidgetTimeout.within(seconds: 10, fallback: nil) {
            let client = LeapClient()
            let session = await client.currentSession()
            guard session.isLoggedIn, !session.selectedVin.isEmpty else { return nil }
            guard let state = try? await client.fetchVehicleState() else { return nil }
            var snapshot = before ?? .placeholder
            merge(state, into: &snapshot)
            return snapshot
        }
        if let refreshed {
            SnapshotStore().write(refreshed)
        }
        // 拉没拉到都刷一次：拉到了要把新数字画上去，没拉到也得让那句「几分钟前」
        // 跟着走——否则按下去整张卡一动不动，和坏了没有区别。
        LeapWidgets.reloadVehicleSurfaces()
    }

    /// 手上这份快照新到这个程度，按下车锁键就直接信它，不再多跑一趟。
    ///
    /// 和桌面卡片的刷新间隔（`VehicleProvider.refreshInterval`）取同一个数不是巧合：
    /// 卡片没被系统限流的常态下，快照本来就该在这个窗口内，于是按下去是立刻走的，
    /// 联网那一趟根本不会发生。它是给"卡片被限流了"「手机在地库躺了半小时」准备的。
    static let lockTargetTrustWindow: TimeInterval = 600

    /// 按下车锁键的那一刻，重新确定该往哪个方向发。
    ///
    /// **这是整件事的根子。** 控件是个开关，系统把"拨过去之后的值"当目标态传下来
    /// （`LockControlIntent.value`），而那个值是照着**渲染时**读到的车况算的。渲染可能
    /// 发生在几十分钟前——车主实测那次：解锁后开了一路，锁屏上显示成「已锁车」，
    /// 下车按一下，系统传下来的目标态是"解锁"，车没锁上。
    ///
    /// 所以显示归显示，方向归方向：这里以**按下去这一刻的车况**为准算方向，
    /// 用户在开关上表达的意思始终是"把它变成相反的那一边"，相反于车的真实状态，
    /// 不是相反于一张过期的画面。
    ///
    /// 三档，按代价从小到大：
    /// 1. 快照够新（`lockTargetTrustWindow`）且锁状态明确 → 直接取反，一个请求都不发。
    /// 2. 否则当场拉一次实时车况，压 6 秒。这一步跑在用户主动触发的意图里，
    ///    时间预算比渲染宽松得多，何况 Face ID 那一下本来就要等。
    /// 3. 拉不到（没信号、token 过期、6 秒没回来）→ 回落到开关给的方向，照常发。
    ///    宁可按一个可能过期的方向，也不让人对着一个毫无反应的按钮猜车锁没锁。
    ///
    /// 拉到的车况顺手写回共享快照：都拉了，不写回等于让下一个读快照的人再拉一遍。
    private static func resolvedLockTarget(
        _ action: WidgetAction,
        desiredLock: Bool?,
        snapshot: VehicleSnapshot?
    ) async -> Bool? {
        guard action == .toggleLock else { return desiredLock }

        if let snapshot, snapshot.canDecideLockTarget(within: lockTargetTrustWindow),
           let locked = snapshot.isLocked {
            return !locked
        }

        let live: Bool? = await WidgetTimeout.within(seconds: 6, fallback: nil) {
            let client = LeapClient()
            let session = await client.currentSession()
            guard session.isLoggedIn, !session.selectedVin.isEmpty else { return nil }
            guard let state = try? await client.fetchVehicleState() else { return nil }
            if var refreshed = SnapshotStore().read() {
                merge(state, into: &refreshed)
                SnapshotStore().write(refreshed)
            }
            return state.isLocked
        }

        guard let live else { return desiredLock }
        return !live
    }

    /// 返回下发之后**真的从车端回读到**的那份车况；没回读到就是 nil。
    /// 调用方靠它区分「已锁车」和「锁车指令已发出」——两句话的可信度差着一整个车端。
    @discardableResult
    private static func dispatch(_ action: WidgetAction, desiredLock: Bool?) async throws -> VehicleSnapshot? {
        let snapshotStore = SnapshotStore()
        if action == .trunk, snapshotStore.read()?.isDriving == true {
            throw WidgetControlUnavailable.trunkWhileDriving
        }

        guard canDispatchDirectly, let password = OperationPasswordStore().read() else {
            // 走到这里说明渲染之后条件又没了（比如刚点过「忘记已保存的操作密码」）。
            // 卡片上的按钮和控件都已经按 `canDispatchDirectly` 渲染过一轮，正常不该到这儿。
            //
            // 动作先留给 App——下次打开 App 时 `consumePendingWidgetAction` 会接手。
            // 但**不能只做这一步就返回**：扩展没法把 App 顶到前台
            // （`openAppWhenRun` 只能是编译期常量 false），用户看到的就是"按了没反应"。
            // 所以这里抛出去，由上面那层在卡片上写明原因。
            SharedSettings.pendingWidgetAction = action.rawValue
            throw WidgetControlUnavailable.noOperationPassword
        }

        let client = LeapClient()
        let snapshot = snapshotStore.read()
        let command = command(for: action, snapshot: snapshot, desiredLock: desiredLock)

        // 先把界面切到"进行中"，用户按下去立刻有反馈，不用等服务端。
        if var optimistic = snapshot {
            applyOptimistically(action, desiredLock: desiredLock, to: &optimistic)
            snapshotStore.write(optimistic)
            LeapWidgets.reloadVehicleSurfaces()
        }

        _ = try await client.sendControl(command, operationPassword: password)

        // 指令是异步执行的，等一下再拉车况，拿到的才是动作之后的状态。
        //
        // **只等一次不够。** 原来这里睡 3 秒拉一次就完事，可车端把新状态报上来常常
        // 比这慢；读到的还是动作之前的旧值，`merge` 又把它直接写回快照，刚做的乐观
        // 更新就被一个过期的值盖掉了。锁屏控件之后一直照着这份快照渲染，而它是个开关，
        // 显示什么就决定按下去发哪个方向——车主实测那次正是这么来的：解锁之后快照被
        // 写回「已锁车」，几十分钟后下车按一下，发出去的是解锁，车没锁上。
        //
        // 改成轮询：拉到能证实动作生效的那一份就停，最多三轮、总共 10 秒。
        // 上限卡在这儿是因为整个 `perform` 还在扩展进程的时间预算里，
        // 而三轮已经覆盖了实测中绝大多数的上报延迟。
        let expected = ControlActivityAction(action, desiredLock: desiredLock, snapshot: snapshot)
        var readBack: VehicleSnapshot?
        var confirmed = false
        for wait in [3.0, 3.0, 4.0] {
            try? await Task.sleep(for: .seconds(wait))
            guard let state = try? await client.fetchVehicleState() else { continue }
            var refreshed = snapshot ?? .placeholder
            merge(state, into: &refreshed)
            readBack = refreshed
            if expected.confirms(refreshed) {
                confirmed = true
                break
            }
            if !expected.isVerifiable { break }
        }
        if var refreshed = readBack {
            // 三轮都没证实，而这个动作本来是证实得了的：那就两头都不能说死——
            // 不能说它成了（乐观值可能是假的），也不能照直写回读到的锁状态
            // （可能只是车端还没上报）。如实标成"读不到"，控件那边会渲染成
            // 「状态未知」，而未知时那一按的方向是锁车，落在安全的那一边。
            if !confirmed, expected.isLockAction {
                refreshed.isLocked = nil
            }
            snapshotStore.write(refreshed)
            readBack = refreshed
        }
        LeapWidgets.reloadVehicleSurfaces()
        return readBack
    }

    /// 扩展进程这一侧能不能自己把指令发出去。
    ///
    /// 两个条件缺一不可：用户在设置里开了「卡片直接控车」，且本机确实存过操作密码。
    /// 开着开关却没存密码是能出现的（换了手机、或点过「忘记已保存的操作密码」），
    /// 这时按钮必须退回"打开 App"那条路，而不是发一条注定被拒的请求。
    /// **不能在这里读钥匙串。** 操作密码那条是 `WhenUnlockedThisDeviceOnly`，
    /// 设备锁着就读不到；而锁屏底部两个控件正是在设备锁着时渲染的，
    /// 一读就必然算出「发不出去」，按钮永远渲染成链接——表现是
    /// 「锁屏上点一下，进了 App，没控车」。
    ///
    /// 所以这里只看两个**锁屏也读得到**的东西：开关，和「存过密码」那个标记
    /// （标记本身不敏感，密码始终留在钥匙串里）。真正下发时才去读钥匙串，
    /// 那时读不到就抛错并写到卡片上，不会静默。
    static var canDispatchDirectly: Bool {
        SnapshotStore.hasSharedContainer && SharedSettings.widgetControlEnabled && SharedSettings.hasSavedOperationPassword
    }

    static func command(
        for action: WidgetAction,
        snapshot: VehicleSnapshot?,
        desiredLock: Bool?
    ) -> LeapCommand {
        if action == .toggleLock, let desiredLock {
            return desiredLock ? .lock() : .unlock()
        }
        return command(for: action, snapshot: snapshot)
    }

    private static func command(for action: WidgetAction, snapshot: VehicleSnapshot?) -> LeapCommand {
        switch action {
        case .lock: return .lock()
        case .unlock: return .unlock()
        case .toggleLock:
            // 判据在 `VehicleSnapshot.lockActionTarget`，三处共用一份（这里、灵动岛那句
            // 文案、乐观更新）。原来这行写的是 `(isLocked ?? true) ? .unlock : .lock`：
            // 读不到锁状态时按下去发的是**解锁**，和「只管锁车」卡的约定正好相反。
            return (snapshot?.lockActionTarget ?? true) ? .lock() : .unlock()
        case .toggleClimate:
            let on = !(snapshot?.climateOn ?? false)
            return .climate(
                on: on,
                temperature: 24,
                fanLevel: 3,
                mode: .cold,
                circleIn: true,
                windshield: false
            )
        case .trunk:
            return .trunk()
        case .horn:
            return .horn()
        }
    }

    /// 只对能立刻确定结果的开关做乐观更新，其余等车况回来。
    private static func applyOptimistically(
        _ action: WidgetAction,
        desiredLock: Bool?,
        to snapshot: inout VehicleSnapshot
    ) {
        switch action {
        case .lock: snapshot.isLocked = true
        case .unlock: snapshot.isLocked = false
        case .toggleLock: snapshot.isLocked = desiredLock ?? snapshot.lockActionTarget
        case .toggleClimate: snapshot.climateOn.toggle()
        case .trunk, .horn: break
        }
    }

    private static func merge(_ state: VehicleState, into snapshot: inout VehicleSnapshot) {
        snapshot.soc = state.soc
        snapshot.gasolinePercent = state.gasolinePercent
        snapshot.isExtendRange = state.hasFuel
        snapshot.rangeKm = state.expectedMileage
        snapshot.energyRangeKm = state.hasFuel ? state.energyRange : nil
        snapshot.fuelRangeKm = state.hasFuel ? state.gasolineRange : nil
        snapshot.isLocked = state.isLocked
        snapshot.isCharging = state.isCharging
        snapshot.chargeLimit = state.chargeLimit
        snapshot.indoorTemp = state.indoorTemp
        snapshot.climateOn = state.acOn
        snapshot.anyDoorOpen = state.anyDoorOpen
        snapshot.trunkOpen = state.trunkOpen
        snapshot.isDriving = state.isDriving
        snapshot.hasTireWarning = state.hasTireWarning
        // 这里原先写的是 `left >= 10 && right >= 10` 当「关好了」——那是车端原始刻度
        // 还没换算时留下的判据，`leftFrontWindow` 早就是开度百分比了（0 才是关严实），
        // 于是开着 10% 的窗在卡片上显示成「已关」。判据和 `VehicleSnapshot.make` 统一。
        if let open = state.anyWindowOpen {
            snapshot.windowsClosed = !open
        }
        snapshot.updatedAt = .now
        // **这一行原来是漏的。** `moment`（`reportedAt ?? updatedAt`）是 `isStale` 和
        // 那句「多久前」的依据；不带上新拉到的采集时刻，回读完一份新鲜车况之后，快照
        // 仍然顶着上一份的旧时刻——卡片上写着「更新于 40 分钟前」，锁屏控件那道
        // `isStale` 也会当场把刚读回来的锁状态判成过期。
        snapshot.reportedAt = state.reportedAt
    }
}

// MARK: - 锁屏 / 控制中心的控件

/// 两个控件意图共用的三条规矩。
///
/// **不要**把它们收进某个协议扩展里"少写两遍"。试过：`appintentsmetadataprocessor`
/// 看不见协议扩展提供的实现，于是三项全部静默落回 `AppIntent` 的默认值——
/// 编译是过的，`authenticationPolicy` 的安全档位却悄悄变了，没有任何提示。
/// 这种东西宁可写两遍。
///
/// 1. **不覆盖 `openAppWhenRun`（默认 false，控件按下不打开 App）。**
///
///    本来想让它跟着「直接控车」开关走——开关关着时由系统把 App 顶到前台，走完整验证。
///    做不到：`openAppWhenRun` 必须是编译期常量，写成计算属性会被
///    `appintentsmetadataprocessor` 直接判错（"must have a compile-time static value"），
///    整个 target 的 AppIntents 元数据都导不出来。控件的模板构造器
///    （`ControlWidgetTemplateBuilder`）又只有 `buildBlock`、没有 `buildEither`，
///    也没法像桌面卡片那样按开关状态在 `Button(intent:)` 和 `Link` 之间二选一。
///
///    所以改成：控件只走"直接下发"这一条路，开关关着时**控件本身渲染成不可用**
///    （见 `VehicleControlValue.canDispatch`），并在控件上写明原因。
///    宁可让它明摆着按不动，也不要按下去悄无声息。
///
/// 2. **`authenticationPolicy` 按动作的后果分档**，两个意图各写各的：
///    车锁能真的把车打开，所以要 `.requiresLocalDeviceAuthentication`；鸣笛按错了
///    最多是响一声，用 `.alwaysAllowed` 换一按即响。理由写在各自的声明上。
///
///    **这三档都不打开 App**——鉴权是系统在锁屏上做的，验过之后意图照旧在扩展进程里跑完。
///
/// 3. **不进快捷指令库**：这两个动作 `VehicleControlIntent` 已经覆盖了，
///    再多两条几乎同名的条目只会让人在快捷指令里挑花眼。

/// 锁屏 / 控制中心上的「车锁」开关。
struct LockControlIntent: SetValueIntent, LiveActivityIntent {
    static var title: LocalizedStringResource { "车锁" }
    static var description: IntentDescription { "锁上或解锁车辆。" }

    /// 每按一次都要过一次 Face ID（或密码），系统当场弹，**不打开 App**。
    ///
    /// 这一档补的正是「直接控车」开着时的那个洞：扩展进程弹不出 Face ID，
    /// 控车门槛本来会被降到"手机已解锁"，而锁屏控件连这一层都没有——
    /// 不加这档的话，捡到手机的人在锁屏上按一下就能开车门。
    /// 换成 `.alwaysAllowed` 就是把这个洞重新打开，改之前先想清楚。
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresLocalDeviceAuthentication }
    static var isDiscoverable: Bool { false }

    /// 开关拨到的目标状态：**true = 解锁**。
    ///
    /// 注意方向：这里存的是"解锁"，不是"锁上"。`SetValueIntent` 的 `value` 由系统填，
    /// 填的就是 `ControlWidgetToggle(isOn:)` 那个开关**拨过去之后**的值——而那个开关的
    /// "开"态被定义成「车是开着的」（见 `VehicleLockControl`：锁着=透明底，解锁=琥珀底）。
    /// 两边必须是同一个方向，任何一侧单独改都会让锁屏上按一下发出反方向的指令：
    /// 想锁车，结果车开了。改之前把这两处一起读完。
    ///
    /// 用目标态而不是照着快照 toggle：控件读的快照最坏可能是几十分钟前的，
    /// 那时按 toggle 算出来的指令会和用户在开关上看到的方向相反。
    ///
    /// 但这个值**已经不是最终方向**了。它同样是照渲染那一刻的车况算的，快照有多旧
    /// 它就有多旧——车主实测那次正是它把"解锁"传了下来。现在它退成兜底：
    /// `WidgetControlRunner.resolvedLockTarget` 会在按下去这一刻重新确认一次，
    /// 拉不到实时车况才回落到这里。
    @Parameter(title: "解锁")
    var value: Bool

    init() {}

    /// 参数名写成 `unlock` 而不是 `value`，是为了让调用点上那个布尔当场能读懂方向。
    init(unlock: Bool) {
        value = unlock
    }

    func perform() async throws -> some IntentResult {
        try await WidgetControlRunner.run(.toggleLock, desiredLock: !value)
        return .result()
    }
}

struct LockOnlyControlIntent: AppIntent, LiveActivityIntent {
    static var title: LocalizedStringResource { "上锁车辆" }
    static var description: IntentDescription { "仅上锁车辆。" }
    static var openAppWhenRun: Bool { false }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresLocalDeviceAuthentication }
    static var isDiscoverable: Bool { false }

    init() {}

    func perform() async throws -> some IntentResult {
        try await WidgetControlRunner.run(.lock)
        return .result()
    }
}

struct UnlockControlIntent: AppIntent, LiveActivityIntent {
    static var title: LocalizedStringResource { "解锁车辆" }
    static var description: IntentDescription { "仅解锁车辆。" }
    static var openAppWhenRun: Bool { false }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresLocalDeviceAuthentication }
    static var isDiscoverable: Bool { false }

    init() {}

    func perform() async throws -> some IntentResult {
        try await WidgetControlRunner.run(.unlock)
        return .result()
    }
}

/// 锁屏 / 控制中心上的「鸣笛寻车」按钮。规矩同上，两项都显式写一遍。
struct HornControlIntent: AppIntent, LiveActivityIntent {
    static var title: LocalizedStringResource { "鸣笛寻车" }
    static var description: IntentDescription { "让车鸣笛闪灯，方便在停车场找到它。" }

    /// 手机锁着也能按，不弹任何验证。
    ///
    /// 和车锁分档的理由：鸣笛的最坏后果是车响一声，而这个动作的使用场景恰恰是
    /// "在停车场里两手拎着东西找车"——那一刻多一道 Face ID 就把它的意义抵消掉了。
    static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }
    static var isDiscoverable: Bool { false }

    init() {}

    func perform() async throws -> some IntentResult {
        try await WidgetControlRunner.run(.horn)
        return .result()
    }
}

/// 大卡右上角那颗刷新键。
///
/// 和四个控车键不是一路：它不下发任何指令，只是把车况重新拉一遍，
/// 所以既不要操作密码，也不看「卡片直接控车」那个开关——没开直控、没存密码的人
/// 一样该能按。真正会拦住它的只有「没登录」，那种时候拉不到就维持上一份快照。
struct RefreshSnapshotIntent: AppIntent {
    static var title: LocalizedStringResource { "刷新车况" }
    static var description: IntentDescription { "重新拉一次车况，更新桌面卡片。" }

    static var openAppWhenRun: Bool { false }

    /// 不进快捷指令库，理由同 `VehicleControlIntent`。
    static var isDiscoverable: Bool { false }

    /// 只读，不改车的任何状态，手机锁着按也没有风险。
    static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }

    init() {}

    func perform() async throws -> some IntentResult {
        await WidgetControlRunner.refreshSnapshot()
        return .result()
    }
}

extension SharedSettings {
    static func widgetButtons(small: Bool) -> [WidgetAction] {
        WidgetButtonLayout.normalize(
            defaults?.stringArray(forKey: small ? "smallWidgetButtons" : "widgetButtons") ?? [],
            small: small
        )
    }

    static func setWidgetButtons(_ actions: [WidgetAction], small: Bool) {
        defaults?.set(
            WidgetButtonLayout.normalize(actions.map(\.rawValue), small: small).map(\.rawValue),
            forKey: small ? "smallWidgetButtons" : "widgetButtons"
        )
        LeapWidgets.reloadVehicleSurfaces()
    }

    private static let pendingActionKey = "pendingWidgetAction"
    private static let pendingActionAtKey = "pendingWidgetActionAt"

    /// 按下之后到 App 接手之间，这条动作还算不算数。
    ///
    /// 卡片按钮和 App 之间隔着一次冷启动，用户按下和 App 真正跑起来之间可以隔很久：
    /// 按完就锁屏、几小时后才想起来打开 App，那时车门自己开一下不是他要的。
    /// 一分钟足够覆盖「按下 → App 起来 → 验证」这条正常路径。
    static let pendingWidgetActionWindow: TimeInterval = 60

    /// 卡片按下但需要回 App 验证的动作，App 启动后接手。**过了时效就当没按过。**
    ///
    /// 读的时候顺手把过期值从磁盘上抹掉：留着的话，下次谁再读一遍还得再判一次，
    /// 而这个键是跨进程的，多留一秒就多一分被另一个进程读到旧值的机会。
    static var pendingWidgetAction: String? {
        get {
            guard let raw = defaults?.string(forKey: pendingActionKey) else { return nil }
            guard let at = defaults?.object(forKey: pendingActionAtKey) as? Date,
                  Date.now.timeIntervalSince(at) < pendingWidgetActionWindow
            else {
                discardPendingWidgetAction()
                return nil
            }
            return raw
        }
        set {
            guard let newValue else {
                discardPendingWidgetAction()
                return
            }
            defaults?.set(newValue, forKey: pendingActionKey)
            defaults?.set(Date.now, forKey: pendingActionAtKey)
        }
    }

    /// 动作和它的时间戳一起抹掉。**两个键必须一起清**：只清动作留下时间戳，
    /// 下一条动作要是写失败了，读到的会是一个配着旧时间戳的空值。
    private static func discardPendingWidgetAction() {
        defaults?.removeObject(forKey: pendingActionKey)
        defaults?.removeObject(forKey: pendingActionAtKey)
    }
}

enum WidgetButtonLayout {
    static let defaults: [WidgetAction] = [.toggleLock, .toggleClimate, .trunk, .horn]

    static func normalize(_ raw: [String], small: Bool) -> [WidgetAction] {
        var result: [WidgetAction] = []
        for action in raw.compactMap(WidgetAction.init(rawValue:)) + defaults where !result.contains(action) {
            result.append(action)
        }
        return Array(result.prefix(small ? 2 : 4))
    }

    static func replacing(_ actions: [WidgetAction], at index: Int, with action: WidgetAction) -> [WidgetAction] {
        var result = actions
        if let previous = result.firstIndex(of: action) { result[previous] = result[index] }
        result[index] = action
        return result
    }

    static func moving(_ actions: [WidgetAction], from: Int, to: Int) -> [WidgetAction] {
        guard actions.indices.contains(from), actions.indices.contains(to), from != to else { return actions }
        var result = actions
        result.insert(result.remove(at: from), at: to)
        return result
    }
}
