import Foundation
import MapKit
import SwiftUI
import WidgetKit

/// Explicit pairing always tries the server. A network outage may reuse a valid cached key;
/// rejected login, invalid server material and cancellation must not silently reuse it.
@MainActor
enum BLEPairingCredentialRefresh {
    static func resolve(cached: LeapBLECredentialContext?,
                        fetch: () async throws -> LeapBLECredentialContext) async throws -> LeapBLECredentialContext {
        do {
            let fresh = try await fetch()
            try Task.checkCancellation()
            BLEDiagnostics.record("key", "certificate.pair.source=cloud hadCache=\(cached != nil) materialChanged=\(cached.map { $0.certificate != fresh.certificate } ?? false)")
            return fresh
        } catch {
            try Task.checkCancellation()
            BLEDiagnostics.record("key", "certificate.pair.refresh.failed \(BLEDiagnostics.failureDetail(error))")
            guard isNetworkFailure(error), let cached,
                  cached.certificate.isSupportedKeyType, cached.certificate.hasValidPasswordCard else { throw error }
            BLEDiagnostics.record("key", "certificate.pair.source=cache reason=networkFailure keyType=\(cached.certificate.keyType)")
            return cached
        }
    }

    private static func isNetworkFailure(_ error: Error) -> Bool {
        if let error = error as? LeapError {
            switch error {
            case .network: return true
            case .http(let status, _): return status >= 500 && status <= 599
            default: return false
            }
        }
        let urlError = error as NSError
        return urlError.domain == NSURLErrorDomain && urlError.code != NSURLErrorCancelled
    }
}

/// 一次控车请求在 UI 上要走的确认流程。
enum AuthChallenge: Identifiable, Equatable {
    /// 需要用户输入操作密码（首次使用、或生物识别不可用/失败）。
    case operationPassword(prompt: String)

    var id: String {
        switch self {
        case .operationPassword(let prompt): return "pwd-\(prompt)"
        }
    }
}

/// 空调设定草稿存本机。空调没开的时候车端不保存这几项（上报的是上次运行的残留值），
/// 不自己存一份的话，每次冷启动都会回到默认值而不是用户上次选的。
enum ClimateDraft {
    private static let prefix = "climate.draft."

    static var temperature: Int {
        get { UserDefaults.standard.object(forKey: prefix + "temperature") as? Int ?? 24 }
        set { UserDefaults.standard.set(newValue, forKey: prefix + "temperature") }
    }

    static var fanLevel: Int {
        get { UserDefaults.standard.object(forKey: prefix + "fanLevel") as? Int ?? 3 }
        set { UserDefaults.standard.set(newValue, forKey: prefix + "fanLevel") }
    }

    static var mode: ClimateMode {
        get {
            guard let raw = UserDefaults.standard.string(forKey: prefix + "mode") else { return .cold }
            return ClimateMode(rawValue: raw) ?? .cold
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: prefix + "mode") }
    }

    static var circleIn: Bool {
        get { UserDefaults.standard.object(forKey: prefix + "circleIn") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: prefix + "circleIn") }
    }
}

/// 深浅色外观。默认跟随系统，用户也可以在设置里固定成浅色或深色。
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    /// 喂给 `preferredColorScheme`。跟随系统时为 nil，交回系统决定。
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

struct ToastMessage: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var detail: String?
    var isError: Bool = false
    /// 带重试按钮的提示要停久一点，否则用户还没来得及点就消失了。
    var showsRetry: Bool = false
    var seconds: Double = 3
}

@MainActor
@Observable
final class VehicleStore {
    private let client: LeapClient
    private let passwordStore = OperationPasswordStore()
    private let bleCertificateStore = BLEKeyCertificateStore()
    private let snapshotStore = SnapshotStore()
    let bleController: BLEVehicleController

    /// 卡片点进来时要打开的页面。
    var pendingDeepLink: String?

    // MARK: - 对外状态

    private(set) var session: LeapSession {
        didSet {
            let vehicle = VehicleIdentity(session: session)
            if vehicle != VehicleIdentity(session: oldValue) {
                customVehiclePhoto = vehicle.flatMap(CustomVehiclePhoto.load(for:))
            }
        }
    }

    private(set) var customVehiclePhoto: UIImage?

    func saveCustomVehiclePhoto(_ data: Data, for vehicle: VehicleIdentity) throws {
        guard vehicle == VehicleIdentity(session: session) else { throw LeapError.missingVehicle }
        try CustomVehiclePhoto.save(data, for: vehicle)
        customVehiclePhoto = UIImage(data: data)
    }

    func removeCustomVehiclePhoto(for vehicle: VehicleIdentity) throws {
        guard vehicle == VehicleIdentity(session: session) else { throw LeapError.missingVehicle }
        try CustomVehiclePhoto.remove(for: vehicle)
        customVehiclePhoto = nil
    }
    /// 每退出一次登录递增。RootView 拿它当 HomeView 的 id：
    /// 实测 iOS 26 上重登后 NavigationStack 会把上一段会话推着的页面（比如设置页）带回来，
    /// 换 id 强制整棵首页视图树重建，重登后一定从首页开始。
    private(set) var loginEpoch = 0
    private(set) var state: VehicleState?
    private(set) var isRefreshing = false
    private(set) var isSendingCommand = false
    private(set) var lastUpdated: Date?
    /// 车端采集这份车况的时刻。读不到（某些车型不报 `collectTime`）时是 nil。
    ///
    /// 不单独存一份：它完全由 `state` 决定，存下来只会多一处忘记清空的地方。
    var reportedAt: Date? { state?.reportedAt }
    private(set) var lastReceipt: ControlReceipt?
    /// 指令下发后正在等车动作。和 `isSendingCommand` 分开：
    /// 前者是"网络请求在飞"，这个是"车还没确认"，界面上要提示的是后者。
    /// 爱车图。演示态为 nil（回退剪影）。3D 车也有这张静态图，用作 3D 加载前的占位。
    ///
    /// 冷启动时是上次缓存的成品，图层叠好之后换成 `carComposition.base`。
    private(set) var carImage: UIImage?
    /// 按车况叠好的分层车图。充电时中间那段是多帧的，界面自己播。
    private(set) var carComposition: CarLayerComposer.ComposedCar?
    private(set) var carModel: CarModel?
    /// 3D 资源解压目录。有值才渲染 3D。
    private(set) var carModelRoot: URL?
    /// 从解压目录反推的车型别名（`Lafa5` 这种）。渲染器按它拼资源路径，
    /// 接口不返回，只能等资源落地后现推——见 `CarModelAssets.assetAlias`。
    private(set) var carAssetAlias: String?
    private(set) var is3DDownloading = false
    /// 2D 分层贴图目录。有值说明这台车走叠图那条路。
    private var carLayerRoot: URL?
    /// 上次叠出来的图层组合，用来跳过没变化的重绘。
    private var composedLayerSignature: String?

    private(set) var confirmingLabel: String?
    /// 超时后可以原样重发的指令。不自动重发——尾门和鸣笛重发是会真的再动一次车的。
    private(set) var retryableCommand: LeapCommand?
    /// 车辆位置反解析出的地址名，比经纬度对用户有意义得多。
    private(set) var locationName: String?

    var toast: ToastMessage?
    var challenge: AuthChallenge?

    /// 生物识别开关（用户可关，关掉后每次控车都手输操作密码）。
    var biometricEnabled: Bool {
        didSet { UserDefaults.standard.set(biometricEnabled, forKey: "biometricEnabled") }
    }

    /// 记住操作密码后才能用生物识别代替输入。
    var hasSavedPassword: Bool { passwordStore.hasPassword }

    /// 首页是否显示官方车模型（3D / 按车况叠的 2D 车图）。
    /// 关掉就回到剪影，同时也不再下载、解压、叠图——完全不碰模型资源。
    var showCarModel: Bool {
        didSet {
            guard showCarModel != oldValue else { return }
            UserDefaults.standard.set(showCarModel, forKey: "showCarModel")
            if showCarModel {
                Task { await loadCarModel() }
            } else {
                unloadCarModel()
            }
        }
    }

    /// 深浅色外观，默认跟随系统。
    var appearance: AppearanceMode {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: "appearanceMode") }
    }

    /// 桌面卡片和锁屏控件是否允许绕过 App 直接下发指令。
    ///
    /// 真值存在 App Group 里（扩展进程要读），这里是它在 `@Observable` 上的镜像。
    /// 不能写成纯计算属性：`@Observable` 只跟踪存储属性，设置页那个 `Toggle` 绑上去
    /// 会拨得动却不重绘——看起来就是"点了没反应，退出去再进来才变"。
    var widgetControlEnabled: Bool {
        didSet {
            guard widgetControlEnabled != oldValue else { return }
            SharedSettings.widgetControlEnabled = widgetControlEnabled
            // 开关直接决定按钮渲染成 Button 还是 Link，卡片和控件都得重画。
            LeapWidgets.reloadVehicleSurfaces()
        }
    }

    let biometricKind = BiometricGate.available

    // MARK: - 本地草稿（控件即时反馈，指令下发后再由车况纠正）

    var climateTemperature: Int = ClimateDraft.temperature {
        didSet { ClimateDraft.temperature = climateTemperature; noteClimateEdit() }
    }
    var climateFanLevel: Int = ClimateDraft.fanLevel {
        didSet { ClimateDraft.fanLevel = climateFanLevel; noteClimateEdit() }
    }
    var climateMode: ClimateMode = ClimateDraft.mode {
        didSet { ClimateDraft.mode = climateMode; noteClimateEdit() }
    }
    var climateCircleIn: Bool = ClimateDraft.circleIn {
        didSet { ClimateDraft.circleIn = climateCircleIn; noteClimateEdit() }
    }
    var climateOn: Bool = false {
        didSet { noteClimateEdit() }
    }

    /// 用户最后一次在界面上动空调的时间。
    ///
    /// 这段时间里的车况不许回冲草稿：从按下到指令真正发出去有一段防抖延迟，
    /// 期间十秒一次的轮询要是插进来，车报的还是旧值，用户刚调的数字会被弹回去——
    /// 看上去就是"这一下没生效，得再按一次"。
    private var climateEditedAt: Date?
    /// 正在用车况回填草稿，这期间的 didSet 不算用户操作。
    private var isSyncingClimateDrafts = false
    /// 指令还在路上时用户又调了。等这条走完补发一次最新的，别把用户的调整吞掉。
    private var climatePushQueued = false

    private func noteClimateEdit() {
        guard !isSyncingClimateDrafts else { return }
        climateEditedAt = .now
    }

    /// 刚动过的这几秒内，车况说什么都不改草稿。
    private var isClimateDraftFresh: Bool {
        guard let editedAt = climateEditedAt else { return false }
        return Date.now.timeIntervalSince(editedAt) < Self.climateEditGrace
    }

    private static let climateEditGrace: TimeInterval = 3
    var chargeLimitDraft: Int = 90

    /// 等待用户确认后要发送的指令。
    private var pendingCommand: LeapCommand?

    /// 充电计划保存要一次连发多条（健康充电 480 + 充电计划 190），
    /// 一次操作密码验证覆盖整批。等待手输密码时把整批指令暂存在这里。
    private var pendingChargeBatch: [LeapCommand]?

    /// 最近一次车真的知道的空调设定。
    ///
    /// 界面上改模式、温度、风量是立刻生效的（要的就是这个即时反馈），但指令还得过操作密码。
    /// 用户取消掉密码、或者指令下发失败，车压根没收到，界面却已经显示成新设定了——
    /// 这时必须退回这份，否则就是在骗人。C11 不上报空调模式，靠车况纠正是等不到的。
    private var confirmedClimate: ClimateSettings?

    private struct ClimateSettings: Equatable {
        var on: Bool
        var temperature: Int
        var fanLevel: Int
        var mode: ClimateMode
        var circleIn: Bool
    }

    private var currentClimate: ClimateSettings {
        ClimateSettings(
            on: climateOn,
            temperature: climateTemperature,
            fanLevel: climateFanLevel,
            mode: climateMode,
            circleIn: climateCircleIn
        )
    }

    private func rollbackClimateDraft() {
        guard let settings = confirmedClimate, settings != currentClimate else { return }
        climateOn = settings.on
        climateTemperature = settings.temperature
        climateFanLevel = settings.fanLevel
        climateMode = settings.mode
        climateCircleIn = settings.circleIn
    }

    /// 本次前台使用期间已经验证过身份，后续指令直接下发。
    ///
    /// 退到后台就作废：手机放在桌上被别人拿起来时，不该还能一路点到底。
    /// 密码只留在内存里，不额外落盘——落盘的那份始终只有钥匙串里勾了「记住」的那个。
    private var verifiedPassword: String?

    init(
        client: LeapClient = LeapClient(),
        bleController: BLEVehicleController = BLEVehicleController()
    ) {
        self.client = client
        self.bleController = bleController
        // 首帧就得知道登没登录。原来这里给的是 `.fresh()`，真正的会话要等
        // `bootstrap()` 里 `await client.currentSession()` 才到手——中间那几帧
        // 按「没登录」渲染，于是每次冷启动都闪一下登录页。
        // 会话本身是钥匙串里同步读出来的，没有理由等。
        var restored = client.initialSession
        // 演示态同理：审核员杀掉 App 重进时，恢复演示会话的那段也在 bootstrap 里。
        var demo = ReviewDemo.isActive
        #if DEBUG
        demo = demo || DemoData.isEnabled
        #endif
        if demo { restored = ReviewDemo.session }
        self.session = restored
        self.customVehiclePhoto = VehicleIdentity(session: restored).flatMap(CustomVehiclePhoto.load(for:))
        self.biometricEnabled = UserDefaults.standard.object(forKey: "biometricEnabled") as? Bool ?? true
        let directControlDefaultChanged = SharedSettings.defaults.map {
            SharedSettings.migrateDirectControlDefault(in: $0)
        } ?? false
        self.widgetControlEnabled = SharedSettings.widgetControlEnabled
        // 操作密码这条钥匙串项要在 App 里（必定已解锁）做两件事，锁屏那边都做不了：
        //
        // 1. 把老等级（`WhenUnlockedThisDeviceOnly`）存的那条重写成新等级，
        //    否则锁屏上永远读不到它——改代码只影响新写入的项。
        // 2. 把「存过密码」的标记和钥匙串对齐，锁屏组件靠它决定渲染成按钮还是链接。
        //
        // 标记变了就得刷卡片和控件：widget 的渲染结果是系统缓存的，不刷的话
        // 它们会一直按上一次的判断显示，点下去还是打开 App。
        passwordStore.migrateAccessibilityIfNeeded()
        let flagChanged = passwordStore.syncSharedFlag()
        if flagChanged || directControlDefaultChanged { LeapWidgets.reloadVehicleSurfaces() }
        self.showCarModel = UserDefaults.standard.object(forKey: "showCarModel") as? Bool ?? true
        self.appearance = AppearanceMode(
            rawValue: UserDefaults.standard.string(forKey: "appearanceMode") ?? ""
        ) ?? .system
        // 重试梯烧完之后（长期未解锁时挂起期到期的 tick 会背靠背连发耗尽），
        // 挂起态下车端的连接/断开事件就是仅剩的「再试一轮」信号。
        // `refreshBluetoothRuntime` 自带去重：梯子还活着就不会另起一条。
        bleController.onArmingStalledEvent = { [weak self] in
            self?.refreshBluetoothRuntime()
        }
        bleController.onProximityWakeEvent = { [weak self] in
            self?.refreshBluetoothRuntime()
        }
        bleController.onProtocolVersionNeeded = { [weak self] accountId, vin in
            self?.scheduleBLEProtocolVersionRefresh(accountId: accountId, vin: vin)
        }
        // 启动即武装。被系统为蓝牙事件在后台拉起时 RootView 不上屏，bootstrap 那条链
        // 整段不跑——不在这里读齐绑定/证书，willRestoreState 恢复的连接就会被当成
        // 过期连接拆掉，感应解锁死在「拉起了但没人接」。这些都是同步钥匙串读取；
        // central 的恢复回调要等 main queue 下一跳，此刻读完刚好赶在它前面。
        if !demo {
            refreshBluetoothRuntime()
            observeProtectedDataUnlock()
        }
    }

    /// 重启未解锁的窗口里被拉起（prewarming、极端时序的蓝牙恢复）时整套钥匙串都
    /// 读不到，解锁那一刻是唯一确定的补救时机：登录态和蓝牙武装各重走一遍。
    private func observeProtectedDataUnlock() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.restoreSessionIfNeeded()
                self.refreshBluetoothRuntime()
            }
        }
    }

    var isLoggedIn: Bool { session.isLoggedIn }

    var vehicleName: String { session.displayVehicleName }

    /// 这台车能不能远程控车窗，见 `VehicleState.windowsRemoteSupported`。
    ///
    /// **读不到车况时按「能」算**：不知道不等于不能。冷启动那一下车况还是空的，
    /// 按「不能」算会让车窗按钮先消失、读到车况再冒出来，比多摆一个按钮更难看。
    var windowsControllable: Bool { state?.windowsRemoteSupported ?? true }

    /// 当前选中车支不支持哨兵模式。来源是 vehicle/list 的 `permission`（含 "400" 且非 S01/T03），
    /// 随车走、不看车况，所以读选中车的 `isSentinelSupported` 而不是 `state`。首页据此决定
    /// 顶行第二格显示哨兵卡还是空调卡。
    var sentinelSupported: Bool { session.selectedVehicle?.isSentinelSupported ?? false }

    /// 哨兵当前是否开启。直接透传车况的 `sentinelOn`（信号 3636），不做本地草稿——界面读的
    /// 就是真车状态，控车确认后由 refresh 刷新翻转，不像空调那样先乐观翻转。
    var sentinelOn: Bool { state?.sentinelOn ?? false }

    /// 遮阳帘 / 天窗 / 前备箱支不支持远控。和哨兵一样随车走（vehicle/list 的 `permission`）、
    /// 不看车况；区别是不落持久化字段、就地现算——`permission` 本身已随会话持久化，
    /// 老会话缺 `permission` 的场景已有 `sentinelStale` 强制重拉 vehicle/list 兜底。
    var sunshadeSupported: Bool {
        guard let vehicle = session.selectedVehicle else { return false }
        return Vehicle.supportsSunshade(permission: vehicle.permission)
    }

    var sunroofSupported: Bool {
        guard let vehicle = session.selectedVehicle else { return false }
        return Vehicle.supportsSunroof(carType: vehicle.carType, permission: vehicle.permission)
    }

    var frunkSupported: Bool {
        guard let vehicle = session.selectedVehicle else { return false }
        return Vehicle.supportsFrunk(carType: vehicle.carType, permission: vehicle.permission)
    }

    /// 舒适座舱页要不要给入口。
    ///
    /// 和上面那几项反过来：**车况信号说话，能力码只是兜底**。理由两条——
    /// 信号比能力码更贴车端（八个座椅信号在实测 C16 上逐个在场），而方向盘加热那条
    /// 指令（cmdid 320）压根没有已知的 `abilities` 原始码，只能靠信号 `1816`。
    /// 两路都没有才隐藏。
    var cabinComfortSupported: Bool {
        if state?.hasCabinComfort == true { return true }
        guard let vehicle = session.selectedVehicle else { return false }
        return Vehicle.supportsCabinComfort(carType: vehicle.carType, permission: vehicle.permission)
    }

    /// 车载冰箱要不要给入口。同上，信号优先。
    ///
    /// 车主那台 C16 两路都没有（`abilities` 不含 `76`、signalMap 里冰箱信号全无），
    /// 所以这个入口在他车上整个不出现——这是「读不到就别显示」，不是功能缺失。
    var fridgeSupported: Bool {
        if state?.fridgeState != nil { return true }
        guard let vehicle = session.selectedVehicle else { return false }
        return Vehicle.supportsFridge(carType: vehicle.carType, permission: vehicle.permission)
    }

    // MARK: - 前台轮询

    private var pollTask: Task<Void, Never>?

    /// 车况没有推送，只能轮询。前台每 10 秒一次，进后台立刻停——
    /// 后台既刷新不了界面，也只是白白耗电和打服务端。
    static let pollInterval: Duration = .seconds(10)

    func startPolling() {
        stopPolling()
        guard session.isLoggedIn, !isDemo else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard !Task.isCancelled, let self else { return }
                await self.refresh()
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - 生命周期

    func bootstrap() async {
        // 每次启动都让桌面卡片重新走一遍时间线。
        // 不这么做的话，装了新版本后桌面上那张卡还会拿旧时间线渲染出的画面顶很久
        // （最长顶到时间线末尾），看起来就像改动没生效。
        LeapWidgets.reloadAll()
        // 审核员可能会杀掉 App 重进，演示态要能恢复，否则会掉回登录页。
        var demo = ReviewDemo.isActive
        #if DEBUG
        demo = demo || DemoData.isEnabled
        #endif
        if demo {
            bleController.deactivate(clearBinding: false)
            session = ReviewDemo.session
            let state = Self.demoVehicleState
            self.state = state
            lastUpdated = .now
            syncDraftsFromState(state)
            await resolveLocationName()
            publishSnapshot()
            return
        }
        session = await client.currentSession()
        // 启动那帧钥匙串可能是「读不到」而不是「没有」（重启未解锁被 BLE 拉起、
        // prewarming）。跑到这里设备多半已解锁，先给一次自愈机会再下未登录的结论。
        if !session.isLoggedIn, await client.restoreSessionFromStore() {
            session = await client.currentSession()
        }
        guard session.isLoggedIn else {
            refreshBluetoothRuntime()
            return
        }
        await startLoggedInSession()
    }

    /// 登录态确认在手之后的启动流程。冷启动 `bootstrap()` 和前台自愈共用一份，
    /// 免得自愈出来的会话少走了哪一步。
    private func startLoggedInSession() async {
        refreshBluetoothRuntime()
        // 上次缓存的车图先同步顶上，首页就不会先闪剪影再换图。
        if showCarModel {
            carImage = CarImageCache.cached(vin: session.selectedVin)
        }
        // 开 App 先探一次登录态：被挤下线后车况仍能刷出来，只有主动探控车 token 才发现。
        // 失效就直接回登录页，不再往下拉车况和轮询。
        guard await validateSession(force: true) else { return }
        Task { await recoverBluetoothCredentialIfNeeded() }
        await refresh(showSpinner: true)
        consumePendingWidgetAction()
        startPolling()
        // 车模型是静态的，拉一次即可；放最后不挡车况刷新。
        await loadCarModel()
    }

    /// 前台激活时停在登录页的自愈入口：启动那帧钥匙串读失败的话，这里重读一次，
    /// 恢复出登录态就直接进首页。只有那种情况会真的动手，其余时候什么都不做
    /// （详见 `LeapClient.restoreSessionFromStore`）。
    func restoreSessionIfNeeded() async {
        guard !session.isLoggedIn, !isDemo else { return }
        guard await client.restoreSessionFromStore() else { return }
        session = await client.currentSession()
        await startLoggedInSession()
    }

    /// 拉车模型。两条路：3D 车（modelType 3）下模型 + 渲染器两个包走 WebGL；
    /// 其余车型下的是一套分层贴图，按车况叠出官方那张会动的车图。
    /// 两条都走不通就留着剪影。
    ///
    /// 演示态不拉；用户关掉「显示车模型」时也不拉——那时下载下来也不会显示。
    func loadCarModel() async {
        guard session.isLoggedIn, !isDemo, showCarModel else { return }
        do {
            let model = try await client.fetchCarModel()
            // 下载途中用户可能把「显示车模型」关掉了，每次 await 回来都要再看一眼，
            // 否则关掉开关后车图还是会冒出来。
            guard showCarModel else { return }
            let vin = session.selectedVin
            carModel = model

            if model.has3DPackages, let param = model.modelParam {
                if CarModelAssets.isReady(vin: vin) {
                    let root = CarModelAssets.directory(vin: vin)
                    carAssetAlias = CarModelAssets.assetAlias(in: root, carTypeCode: param.carTypeCode)
                    await client.rememberCarAlias(carAssetAlias)
                    carModelRoot = root
                    adoptLayers(in: root)
                    return
                }
                is3DDownloading = true
                defer { is3DDownloading = false }
                let root = try await CarModelAssets.prepare(vin: vin, model: model) { [client] key in
                    try await client.fetchCarModelPackage(key: key)
                }
                guard showCarModel else { return }
                // 别名要在设 root 之前推出来：root 一变 3D 视图就重建并立刻 newInit，
                // 那时 alias 还是 nil 的话，第一帧仍然按 carType 拼路径。
                carAssetAlias = CarModelAssets.assetAlias(in: root, carTypeCode: param.carTypeCode)
                await client.rememberCarAlias(carAssetAlias)
                carModelRoot = root
                adoptLayers(in: root)
                return
            }

            let root = CarModelAssets.areLayersReady(vin: vin)
                ? CarModelAssets.directory(vin: vin)
                : try await CarModelAssets.prepareLayers(vin: vin, model: model) { [client] key in
                    try await client.fetchCarModelPackage(key: key)
                }
            guard showCarModel else { return }
            carLayerRoot = CarLayerComposer.layerDirectory(in: root)
            composeCarImage()
        } catch {
            // 拿不到就保持剪影，不打扰用户。
        }
    }

    /// 清掉内存里的车图和 3D 资源引用，首页立刻回到剪影。
    /// 关开关、换车、退出登录、会话失效都要走这里——这些字段不清的话，
    /// 下一台车（或下一位用户）登录后首页渲的还是上一台。
    /// 磁盘上已下载的资源留着，按 VIN 分目录，回来时不用再下一遍。
    private func unloadCarModel() {
        carImage = nil
        carComposition = nil
        carLayerRoot = nil
        composedLayerSignature = nil
        carModel = nil
        carModelRoot = nil
        carAssetAlias = nil
        // 卡片那份也得清，否则桌面上会一直挂着上一台车（或上一位用户的车）。
        CarImageCache.clearShared()
        LeapWidgets.reloadVehicleSurfaces()
    }

    /// 按当前车况把图层叠成车图。车况一变就重叠一次，门窗开合、充电会跟着显示。
    private func composeCarImage() {
        guard let layerRoot = carLayerRoot else { return }
        let carType = session.selectedCarType
        // 签名必须带上图层目录（按 VIN 分的）：图层名只反映车况，
        // 两台车碰巧都锁着不充电时签名会一模一样，只比图层名的话，
        // 换车/换账号后这里会因「没变化」直接返回，旧车图永远不被覆盖。
        let signature = layerRoot.path + "#"
            + CarLayerComposer.plan(for: state, carType: carType).signature
        guard signature != composedLayerSignature else { return }
        composedLayerSignature = signature
        guard let composed = CarLayerComposer.compose(
            state: state, carType: carType, layerDirectory: layerRoot
        ) else { return }
        carComposition = composed
        carImage = composed.base
        // 缓存底图就够了：它是车身及以下那一整块，冷启动拿它顶第一帧不会露空白。
        CarImageCache.store(composed.base, vin: session.selectedVin)
        // 卡片那份要拍平的整车（含充电口盖、开着的门），而且得写进 App Group。
        if CarImageCache.storeShared(composed.still) {
            Task { await ControlActivitySession.refreshArtwork() }
        }
        LeapWidgets.reloadVehicleSurfaces()
    }

    /// 3D 渲染器截来的车图，**只给桌面卡片和灵动岛用**。
    ///
    /// 3D 车的资源包里根本没有 2D 图层（真机实测：C11 2026、B10 2025 解出来只有渲染器
    /// 和模型，没有 `android/<density>/`），`composeCarImage()` 那条路一次都跑不了，
    /// 卡片上的车图因此一直是空的——桌面上只剩剪影。官方安卓也是这么绕过去的：
    /// 3D 车的爱车图就是渲染器截的图，2D 车才是分层贴图叠的。
    ///
    /// 首页不用这张：那儿有现渲的 3D，比截图新鲜。
    func adoptRenderedCarImage(_ image: UIImage) {
        guard session.isLoggedIn, !isDemo, showCarModel else { return }
        // 背景没抠干净的那种整块底图会被挡在这一步，写不进去就保持原样（见 CarImageCache）。
        guard CarImageCache.storeShared(rendered: image) else { return }
        Task { await ControlActivitySession.refreshArtwork() }
        LeapWidgets.reloadVehicleSurfaces()
    }

    /// 3D 车型也把包里那套 2D 图层认下来。
    ///
    /// 资源包里两套都有，只是原来走 3D 那条分支时从没试过取图层，`carLayerRoot` 一直是 nil。
    /// 首页照旧渲 3D——`HomeView` 本来就写着「三层回退：3D → 2D 车图 → 剪影」，
    /// 补上这一层之后，3D 加载期间和 WebGL 挂掉时垫的不再是剪影而是真车图，
    /// 桌面上那张单功能卡片也才有车图可用。包里没有图层目录就保持原样。
    private func adoptLayers(in root: URL) {
        guard carLayerRoot == nil, let layers = CarLayerComposer.layerDirectory(in: root) else { return }
        carLayerRoot = layers
        composeCarImage()
    }

    /// 卡片深链、桌面快捷方式带进来的动作：**先把车况拉准，再执行。**
    ///
    /// 车锁、尾门、空调这三个动作都是照手上这份车况取反的，而这条路上的动作
    /// 可以在 App 睡了几小时之后进来（退到后台就停了轮询，`state` 冻在那一刻）。
    /// 不先刷一次，「开关车锁」会照着几小时前那份「已锁」发出一条解锁。
    ///
    /// 手上没有寄存的动作就一步都不走——不能让一次普通的深链跳转顺带发个请求。
    func refreshThenConsumePendingAction() async {
        guard SharedSettings.pendingWidgetAction != nil else { return }
        // 还没登录时先别刷：`consumePendingWidgetAction` 会把动作原样留着，
        // 等 `bootstrap()` 或登录完成后接手，那两条路自己会拉车况。
        guard session.isLoggedIn else { return }
        await refresh()
        consumePendingWidgetAction()
    }

    /// 卡片按钮在未开启「直接控车」时会把动作交回 App，这里接手并走完整验证流程。
    ///
    /// 调用前请确保车况是新的：方向敏感的动作照 `state` 取反，
    /// 入口一般走 `refreshThenConsumePendingAction`，`bootstrap()` 里则是刚 `refresh()` 过。
    func consumePendingWidgetAction() {
        guard let raw = SharedSettings.pendingWidgetAction else { return }
        // 卡片深链唤起 App 时，onOpenURL 会早于 bootstrap 拿到 session。
        // 这时不能把动作吃掉——先留着，等 bootstrap 或登录完成后再来一次。
        //
        // 留着也只留一分钟（`pendingWidgetActionWindow`）：没登录的人得先走完登录，
        // 走得慢就过期了，这是对的——那条动作已经不是他此刻要的了。
        guard session.isLoggedIn else { return }
        SharedSettings.pendingWidgetAction = nil
        guard let action = WidgetAction(rawValue: raw) else { return }
        // **这条动作一律重新验证一次。**
        //
        // 动作是从 `leapcontrol://action?a=…` 进来的，而这个 scheme 在 Info.plist 里
        // 是公开注册的：别的 App、Safari 里一个链接、用户自己绑在侧边按钮上的
        // 「打开 URL」快捷指令，构造出来的 URL 和卡片发的一模一样，`onOpenURL`
        // 分辨不出来。App 已经在前台时更直接——不清这一下，`verifiedPassword`
        // 还在，指令就静默发出去了，一次验证都不弹。
        //
        // 走卡片这条路本来就承诺「由 App 走完整的 Face ID + 操作密码流程」
        // （见 `WidgetAction.deepLink`），所以这里多验一次不算加戏。
        endForegroundVerification()
        switch action {
        case .lock: perform(.lock())
        case .unlock: perform(.unlock())
        case .toggleLock: toggleLock()
        case .toggleClimate: applyClimate(on: !climateOn)
        case .trunk: toggleTrunk()
        case .horn: honk()
        }
    }

    /// 演示态不发任何网络请求，控车只回一条提示。
    ///
    /// 两条来源：审核用的演示账号（Release 也有，见 `ReviewDemo`），
    /// 以及本地逐屏核对用的 `-demo` 启动参数（仅 Debug）。
    ///
    var isDemo: Bool {
        if ReviewDemo.isActive { return true }
        #if DEBUG
        return DemoData.isEnabled
        #else
        return false
        #endif
    }

    /// 轮询和用户手动刷新会撞在一起，同一时刻只允许一个请求在飞。
    private var fetchInFlight = false
    /// 本次 App 运行内是否已成功拉过一次 `vehicle/list`。用来「首启强制刷新一次能力码」：
    /// 升级用户持久化的旧车列表缺 `isExtendRange`，必须重拉一次纠正，之后轮询不再重复拉。
    private var didLoadVehiclesThisLaunch = false

    @discardableResult
    func refreshChargePlan() async -> Bool {
        if isDemo { return true }
        let vin = session.selectedVin
        let account = session.oldAuth?.accountId
        do {
            let plan = try await client.refreshChargePlan()
            guard vin == session.selectedVin, account == session.oldAuth?.accountId else { return false }
            if state == nil { state = VehicleState() }
            state?.chargePlan = plan
            state?.chargePlanLimit = plan?.percent
            return true
        } catch {
            if !Task.isCancelled, vin == session.selectedVin, account == session.oldAuth?.accountId {
                show(text: "充电计划读取失败", detail: "请稍后重试，暂未取得最新设置")
            }
            return false
        }
    }

    /// - Parameter refreshConfig: 是否重拉 commonConfig（充电上限/充电计划）。
    ///   下拉/手动刷新传 `true`；轮询保持默认 `false`，走客户端按 VIN 的缓存。
    func refresh(showSpinner: Bool = false, refreshConfig: Bool = false) async {
        guard session.isLoggedIn, !isDemo, !fetchInFlight else { return }
        fetchInFlight = true
        if showSpinner { isRefreshing = true }
        defer { isRefreshing = false; fetchInFlight = false }
        do {
            // 本会话首次、或车辆列表为空、或任一车能力码是老会话兜出来的默认值（abilitiesStale
            // 判增程 / sentinelStale 判哨兵），都强制重拉一次 vehicle/list 把 abilities→isExtendRange、
            // permission→isSentinelSupported 一并刷到最新。否则升级用户持久化的旧车列表非空、又缺
            // 这些字段，增程会被永久误判成纯电（油量整块消失）、哨兵支持位会被永久误判成不支持，
            // 且永不自愈。两个 stale 同一套兜底，一并纳入这道门。
            // 刷新成功后置 didLoadVehiclesThisLaunch，之后轮询照旧跳过，不额外打接口。
            let capabilitiesStale = session.vehicles.contains { $0.abilitiesStale || $0.sentinelStale }
            if session.vehicles.isEmpty || !didLoadVehiclesThisLaunch || capabilitiesStale {
                _ = try await client.loadVehicles()
                didLoadVehiclesThisLaunch = true
                session = await client.currentSession()
            }
            let fresh = try await client.fetchVehicleState(refreshConfig: refreshConfig)
            state = fresh
            lastUpdated = .now
            syncDraftsFromState(fresh)
            // 2D 车的车图是按车况叠出来的，门窗开合了要重叠一次。
            composeCarImage()
            session = await client.currentSession()
            refreshBluetoothRuntime()
            await resolveLocationName()
            publishSnapshot()
        } catch {
            show(error: error)
        }
    }

    /// 把展示用的车况写进 App Group，供桌面卡片读取。
    /// 只写非敏感字段——token 和操作密码始终留在 Keychain。
    private func publishSnapshot() {
        guard let state else { return }
        snapshotStore.write(VehicleSnapshot.make(
            state: state,
            vehicleName: vehicleName,
            locationName: locationName,
            updatedAt: lastUpdated ?? .now
        ))
        LeapWidgets.reloadVehicleSurfaces()
    }

    /// 车辆坐标，**车端原样的 GCJ-02**，隐私模式下拿不到。
    ///
    /// 全端只有这一个坐标口径，不要再派生第二个：在中国大陆，苹果地图（MapKit）和
    /// 系统定位（CoreLocation）用的都是 GCJ-02，跳高德／百度／腾讯要的也是 GCJ-02，
    /// 所有消费点原样用这一个值。为什么不能转见 `CoordinateTransform`。
    var coordinate: CLLocationCoordinate2D? { state?.shareableCoordinate }

    /// 把坐标换成"杭州市滨江区江陵路"这类地址，失败时不显示任何回退坐标。
    /// 十秒一次的轮询里，车没动就不重复解析。
    func resolveLocationName() async {
        guard let coordinate else {
            locationName = nil
            return
        }
        if let name = await LocationNaming.name(for: coordinate, reusing: snapshotStore.read()) {
            locationName = name
        }
    }

    /// 拉里程能耗统计。演示模式给演示数据；真机四个接口并发拉，失败的块置 nil。
    func loadDrivingStats() async -> DrivingStats? {
        if isDemo { return ReviewDemo.drivingStats }
        do {
            return try await client.fetchDrivingStats()
        } catch {
            return nil
        }
    }

    /// 拉某一周的能耗构成（点周柱子时按周调）。
    /// 演示模式给一份跟着周变的假数据——六根柱子点下去数字纹丝不动，看着就像点坏了。
    func loadEnergyDistribution(range: DrivingStatsRange) async -> DrivingStats.EnergyDistribution? {
        if isDemo { return ReviewDemo.energyDistribution(for: range) }
        do {
            return try await client.fetchEnergyDistribution(range: range)
        } catch {
            return nil
        }
    }

    func loadChargingSummary(vehicle: VehicleIdentity, period: ChargingPeriod,
                             interval: DateInterval) async throws -> ChargingSummary {
        if isDemo { return try ReviewDemo.chargingSummary(period: period, interval: interval) }
        return try await client.fetchChargingSummary(vehicle: vehicle, period: period, interval: interval)
    }

    func loadChargingRecordPage(vehicle: VehicleIdentity, interval: DateInterval,
                                page: Int) async throws -> ChargingRecordPage {
        if isDemo { return try ReviewDemo.chargingPage(interval: interval, page: page) }
        return try await client.fetchChargingRecordPage(vehicle: vehicle, interval: interval, page: page)
    }

    /// 驻车照片只有最近一张；图片数据不写普通缓存，避免旧 URL 覆盖新照片。
    func loadParkingPhoto() async throws -> (ParkingPhoto, Data?) {
        guard !isDemo else { throw LeapError.server("演示模式没有驻车照片") }
        let photo = try await client.fetchParkingPhoto()
        guard let url = photo.url else { return (photo, nil) }
        return (photo, try await client.downloadParkingPhoto(from: url))
    }

    /// 车况回来后把本地草稿对齐。
    ///
    /// 只在空调**开着**的时候对齐：这时车端是权威的，界面该显示车里真实在跑的设定。
    /// 空调关着时车端上报的模式/温度是上一次运行留下的残留值，拿它覆盖草稿，
    /// 界面就会每次都落回上一次的档位，而且十秒一次的轮询会把用户刚选好的设定反复冲掉。
    private func syncDraftsFromState(_ state: VehicleState) {
        if let limit = state.chargeLimit, limit > 0 { chargeLimitDraft = limit }
        clearCabinDraftsIfSettled()
        // 用户刚动过、或者指令还在路上时，车况里还是旧值，回冲草稿等于把刚调的弹回去。
        guard !isClimateDraftFresh, !isSendingCommand, !climatePushQueued else { return }
        isSyncingClimateDrafts = true
        defer { isSyncingClimateDrafts = false }
        climateOn = state.acOn
        guard state.acOn else { return }
        if let temperature = state.acSetting { climateTemperature = temperature }
        if let fan = state.acFanLevel, fan > 0 { climateFanLevel = min(7, fan) }
        // 车端没上报模式就别动草稿。硬对齐会把用户刚选的「制冷」冲成「自动」，
        // 而且十秒一次的轮询会反复冲。原始值各车型编码不同套，交给 state 去解释。
        if let mode = state.climateMode { climateMode = mode }
        if let circle = state.acCircleIn { climateCircleIn = circle }
        // 车况是车自己报的，对齐完这份就是车确认知道的设定。
        confirmedClimate = currentClimate
    }

    // MARK: - 登录

    func sendSMS(phone: String) async -> Bool {
        // 演示账号不走短信通道：这个号码在零跑那边并不存在，真发只会拿到一个错误。
        if phone == ReviewDemo.phone {
            show(text: "演示账号无需验证码", detail: "验证码填 \(ReviewDemo.code)")
            return true
        }
        do {
            try await client.sendSMS(phone: phone)
            show(text: "验证码已发送")
            return true
        } catch {
            show(error: error)
            return false
        }
    }

    func login(phone: String, code: String) async -> Bool {
        if ReviewDemo.matches(phone: phone, code: code) {
            enterDemo()
            return true
        }
        do {
            try await client.login(phone: phone, smsCode: code)
            session = await client.currentSession()
            _ = try? await client.loadVehicles()
            session = await client.currentSession()
            refreshBluetoothRuntime()
            await refresh(showSpinner: true)
            // 从卡片点进来但当时还没登录，动作一直留着，这时接手。
            consumePendingWidgetAction()
            startPolling()
            show(text: "登录成功")
            // 登录进来的这条路不经过 bootstrap，车模型得在这里拉一次，
            // 否则首页会一直停在剪影上。
            Task { await loadCarModel() }
            Task { await recoverBluetoothCredentialIfNeeded() }
            return true
        } catch {
            // 失败也要把 client 那边的会话同步过来。`client.login()` 失败时已经把自己退回
            // 干净态了，界面这份要是还停在旧值，两边就又不一致了。
            session = await client.currentSession()
            show(error: error)
            return false
        }
    }

    /// 演示态装载的车况。Release 下就是审核用的那份；Debug 带 `-demo` 时走 `DemoData`，
    /// 它会按 `-screen` 叠加本地核对用的信号（舒适座舱 / 冰箱），审核那份不受影响。
    private static var demoVehicleState: VehicleState {
        #if DEBUG
        if DemoData.isEnabled { return DemoData.vehicleState }
        #endif
        return ReviewDemo.vehicleState
    }

    /// 进入演示态：装载写死的车况，不建立任何会话，也不启动轮询
    /// （轮询本来就会被 `isDemo` 挡掉，这里不启动是为了不留一个空转的任务）。
    private func enterDemo() {
        ReviewDemo.isActive = true
        session = ReviewDemo.session
        let demoState = Self.demoVehicleState
        state = demoState
        lastUpdated = .now
        syncDraftsFromState(demoState)
        Task {
            await resolveLocationName()
            publishSnapshot()
        }
        show(text: "已进入演示模式", detail: "数据为模拟，不会控制真实车辆")
    }

    func logout() async {
        ReviewDemo.isActive = false
        loginEpoch += 1
        stopPolling()
        endForegroundVerification()
        cancelBluetoothArmRetry()
        bleController.deactivate(clearBinding: true)
        await client.logout()
        passwordStore.clear()
        // 「直接控车」那个开关跟着退登一起归零：`VehicleStore` 随进程活着，
        // `widgetControlEnabled` 只在 init 读过一次，不显式归零的话，界面上拿到的
        // 还是上一位用户的选择。这个开关降低的正是控车门槛，不能这样继承过来。
        widgetControlEnabled = false
        // 退出后卡片不能继续显示上一位用户的车况。
        snapshotStore.clear()
        LeapWidgets.reloadVehicleSurfaces()
        session = await client.currentSession()
        state = nil
        lastUpdated = nil
        // 车图也得清：VehicleStore 随进程活着，不清的话换账号登录后
        // 首页会先渲上一位用户那台车。
        unloadCarModel()
    }

    func resetSession() async {
        loginEpoch += 1
        stopPolling()
        endForegroundVerification()
        cancelBluetoothArmRetry()
        bleController.deactivate(clearBinding: true)
        await client.resetSession()
        passwordStore.clear()
        session = await client.currentSession()
        state = nil
        lastUpdated = nil
        unloadCarModel()
        show(text: "会话已重置")
    }

    func selectVehicle(_ vehicle: Vehicle) async {
        cancelBluetoothArmRetry()
        bleController.deactivate(clearBinding: false)
        await client.selectVehicle(vin: vehicle.vin, carType: vehicle.carType)
        session = await client.currentSession()
        refreshBluetoothRuntime()
        // 切到的这台车证书可能也在上次退登时被清了，同样给一次静默补同步。
        Task { await recoverBluetoothCredentialIfNeeded() }
        // 换车后把共享偏好里的直控开关重新读回内存。
        widgetControlEnabled = SharedSettings.widgetControlEnabled
        state = nil
        // 换车了，上一台的车图/3D 资源不能再用。
        unloadCarModel()
        await refresh(showSpinner: true)
        await loadCarModel()
    }

    func forgetPassword() {
        passwordStore.clear()
        show(text: "已忘记操作密码")
    }

    private func cachedBLECredentialContext() -> LeapBLECredentialContext? {
        cachedBLECredentialOutcome().context
    }

    /// 证书读取三态。「读不到」（重启未解锁的窗口）要和「没有」分开：
    /// 前者等钥匙串可读了重试，后者才轮得到重新同步。
    private func cachedBLECredentialOutcome() -> (context: LeapBLECredentialContext?, unreadable: Bool) {
        guard !isDemo,
              let accountId = session.oldAuth?.accountId,
              !accountId.isEmpty,
              !session.selectedVin.isEmpty else { return (nil, false) }
        // 设备号还没就位（启动那帧钥匙串读不到，界面这份 session 还是空态快照）：
        // 证书就算读到了也签不出认证包（`LeapBLEProtocol` 会挡空 deviceId），
        // 更不能把空值当真值塞进 context。按「暂不可读」处理，让武装探针稍后重试。
        guard !session.deviceId.isEmpty else {
            return (nil, true)
        }
        switch bleCertificateStore.loadOutcome(accountId: accountId, vin: session.selectedVin) {
        case .found(let certificate):
            let context = LeapBLECredentialContext(
                certificate: certificate,
                accountId: accountId,
                deviceId: session.deviceId,
                vin: session.selectedVin
            )
            return (context, false)
        case .missing:
            return (nil, false)
        case .failure:
            return (nil, true)
        }
    }

    func syncBLECredentialContext() async throws -> LeapBLECredentialContext {
        guard !isDemo else { throw LeapError.server("演示模式不能同步蓝牙证书") }
        guard bluetoothKeyEligible else {
            throw LeapError.server("当前环境不能使用蓝牙钥匙")
        }
        let requestedAccount = session.oldAuth?.accountId
        let requestedVIN = session.selectedVin
        let requestedDevice = session.deviceId
        BLEDiagnostics.record("key", "certificate.fetch.begin")
        let certificate = try await client.fetchBLEKeyCertificate()
        BLEDiagnostics.record("key", "certificate.fetch.success keyType=\(certificate.keyType) validPasswordCard=\(certificate.hasValidPasswordCard)")
        guard certificate.isSupportedKeyType else {
            throw LeapError.server("当前蓝牙证书类型不受支持（keyType=\(certificate.keyType)）")
        }
        guard certificate.hasValidPasswordCard else {
            throw LeapError.server("当前蓝牙证书的 passwordCard 无效，请重新同步")
        }
        let refreshedSession = await client.currentSession()
        try Task.checkCancellation()
        guard session.oldAuth?.accountId == requestedAccount, session.selectedVin == requestedVIN,
              session.deviceId == requestedDevice, !isDemo, bluetoothKeyEligible,
              refreshedSession.oldAuth?.accountId == requestedAccount,
              refreshedSession.selectedVin == requestedVIN, refreshedSession.deviceId == requestedDevice else {
            throw LeapError.server("账号、车辆或设备已切换，请重新同步蓝牙钥匙")
        }
        session = refreshedSession
        guard let accountId = session.oldAuth?.accountId,
              !accountId.isEmpty,
              !session.selectedVin.isEmpty else {
            throw LeapError.notLoggedIn
        }
        guard bleCertificateStore.save(
            certificate,
            accountId: accountId,
            vin: session.selectedVin
        ) else {
            throw LeapError.server("蓝牙证书写入钥匙串失败")
        }
        let context = LeapBLECredentialContext(
            certificate: certificate,
            accountId: accountId,
            deviceId: session.deviceId,
            vin: session.selectedVin
        )
        bleController.configureProduction(
            credentialContext: context,
            eligible: true
        )
        scheduleBLEProtocolVersionRefresh(accountId: context.accountId, vin: context.vin)
        return context
    }

    var bluetoothKeyEligible: Bool {
        !isDemo
    }

    func refreshBluetoothRuntime() {
        if attemptBluetoothArm() {
            cancelBluetoothArmRetry()
        } else {
            scheduleBluetoothArmRetry()
        }
    }

    /// 武装一轮。返回 `true` 表示这轮到达了确定状态（armed/unbound/disabled/…），
    /// `false` 表示钥匙串还锁着、要继续等。
    ///
    /// 关键在第一步：内存没有登录态时先分辨「真没登录」和「会话钥匙串锁着没读到」。
    /// 后者（重启未解锁被拉起）时资格、证书、绑定全都算不出来——session 读失败启动
    /// 帧会落一份 `.fresh()`，拿它算出来的只会是「无证书/无绑定」——
    /// `configureProduction` 的任何分支都会把这些「未知」当「否」执行
    /// 拆除。所以那时根本不进它，整个挂起，只给控制器举旗。
    @discardableResult
    private func attemptBluetoothArm() -> Bool {
        // 新安装判定可能在锁定窗口被跳过过（那时分不清「重装」和「锁着」），武装前
        // 再给它一次机会：不能让旧安装的绑定先在本进程里武装生效、下次冷启动才被
        // 突然清掉。已判定过的话这里只是读一个 bool，白给。
        BLEInstallationGuard.prepareIfNeeded()
        if !isDemo, session.oldAuth == nil {
            switch SessionStore().loadOutcome() {
            case .failure:
                bleController.suspendArming(message: "会话钥匙串暂不可读，武装挂起等待解锁或重试")
                return false
            case .found(let stored) where stored.isLoggedIn:
                // 第三态：钥匙串已经读得到了（刚解锁、或启动那帧只是瞬时报错），
                // 内存里的会话却还是启动帧落下的空壳。这时放行就是拿空会话去
                // `configureProduction` 得出「无资格/缺证书」的假确定态，反手把
                // 恢复机制整个拆掉——解锁通知对挂起的进程不保证补投，这一轮重试
                // 往往是唯一的救场机会。先把会话装回内存（既有自愈入口），装好后
                // `startLoggedInSession` 自己会重新武装；本轮保持挂起。
                bleController.suspendArming(message: "等待内存会话恢复后重新武装")
                Task { await self.restoreSessionIfNeeded() }
                return false
            case .found, .missing:
                break
            }
        }
        let credential = cachedBLECredentialOutcome()
        bleController.configureProduction(
            credentialContext: credential.context,
            eligible: bluetoothKeyEligible,
            credentialUnreadable: credential.unreadable
        )
        if let context = credential.context, !credential.unreadable, !bleController.armBlockedByKeychain {
            scheduleBLEProtocolVersionRefresh(accountId: context.accountId, vin: context.vin)
        }
        return !credential.unreadable && !bleController.armBlockedByKeychain
    }

    @ObservationIgnored private var bleVersionRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var bleVersionRefreshID: UUID?
    @ObservationIgnored private var bleVersionRefreshAccount = ""
    @ObservationIgnored private var bleVersionRefreshVIN = ""
    @ObservationIgnored private var bleVersionLastAttempt: Date?

    /// Restored bindings may predate protocolMinor persistence. All arming paths need
    /// the cloud version, not just the pairing screen. Coalesce foreground/BT callbacks.
    private func scheduleBLEProtocolVersionRefresh(accountId: String, vin: String) {
        guard bluetoothKeyEligible, session.oldAuth?.accountId == accountId,
              session.selectedVin == vin,
              bleController.needsCloudProtocolVersion(accountId: accountId, vin: vin) else { return }
        let sameContext = bleVersionRefreshAccount == accountId && bleVersionRefreshVIN == vin
        if sameContext {
            if bleVersionRefreshTask != nil { return }
            if let last = bleVersionLastAttempt, Date.now.timeIntervalSince(last) < 30 { return }
        }
        bleVersionRefreshTask?.cancel()
        let requestID = UUID()
        bleVersionRefreshID = requestID
        bleVersionRefreshAccount = accountId
        bleVersionRefreshVIN = vin
        bleVersionLastAttempt = .now
        BLEDiagnostics.record("key", "version.fetch.begin source=runtime")
        bleVersionRefreshTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.bleVersionRefreshID == requestID { self.bleVersionRefreshTask = nil }
            }
            do {
                let minor = try await self.client.fetchBLEProtocolMinor(vin: vin, accountId: accountId)
                guard !Task.isCancelled, self.bleVersionRefreshID == requestID,
                      self.bluetoothKeyEligible, self.session.oldAuth?.accountId == accountId,
                      self.session.selectedVin == vin else { return }
                BLEDiagnostics.record("key", "version.fetch.success source=runtime profileMinor=\(minor)")
                self.bleController.configureProtocolVersion(minor, accountId: accountId, vin: vin)
            } catch {
                guard !Task.isCancelled, self.bleVersionRefreshID == requestID else { return }
                BLEDiagnostics.record("key", "version.fetch.failed source=runtime \(BLEDiagnostics.failureDetail(error))")
            }
        }
    }

    /// 钥匙串「暂不可读」时的重武装：退避几次，加上受保护数据解锁通知那条路，
    /// 两路先到先得。放弃后前台激活的 `startLoggedInSession` 还会再走武装。
    @ObservationIgnored private var bleArmRetryTask: Task<Void, Never>?
    @ObservationIgnored private var bleArmRetryGeneration = 0

    private func scheduleBluetoothArmRetry() {
        guard bleArmRetryTask == nil else { return }
        bleArmRetryGeneration &+= 1
        let generation = bleArmRetryGeneration
        bleArmRetryTask = Task { [weak self] in
            defer {
                // 只清自己的柄：旧任务被取消后 defer 可能在新任务排定之后才跑，
                // 不比对代数就会把新任务的柄抹掉。
                if let self, self.bleArmRetryGeneration == generation {
                    self.bleArmRetryTask = nil
                }
            }
            for seconds in [2, 8, 30, 120] {
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled, let self else { return }
                if self.attemptBluetoothArm() {
                    return
                }
            }
        }
    }

    /// 退登/换车这类确定性意图要显式停掉重试：让它带着旧会话的余温继续跑，
    /// 会在用户退出之后错误地重新武装。
    private func cancelBluetoothArmRetry() {
        bleArmRetryTask?.cancel()
        bleArmRetryTask = nil
    }

    /// 退登（含此前假性退登的那批）会把蓝牙证书连坐清掉，重登后没人补，
    /// 蓝牙钥匙页会一直停在「缺少当前车辆的蓝牙证书」。这里在登录态确认后
    /// 静默补一次同步；绑定救不回来（得在车旁重新配对），所以证书补上后
    /// 若发现停在未绑定，就把「差的是配对」这一步明确告诉用户。
    func recoverBluetoothCredentialIfNeeded() async {
        guard bluetoothKeyEligible else { return }
        // 「读不到」不补：那多半是钥匙串还没解锁，重新同步只会白跑一趟还写不进去。
        let credential = cachedBLECredentialOutcome()
        guard credential.context == nil, !credential.unreadable else { return }
        do {
            _ = try await syncBLECredentialContext()
            // 「重新配对」只对确实配过的车说。从未配过的车（第二辆已兑码的车、
            // 换新手机首登）同样会停在 unbound，但那不是谁清了它的配对，
            // 弹这条只会让用户以为丢了什么。
            if bleController.runtimeState == .unbound,
               let accountId = session.oldAuth?.accountId,
               BLEPairingHistory.hasPaired(accountId: accountId, vin: session.selectedVin) {
                show(
                    text: "蓝牙钥匙需要重新配对",
                    detail: "退出登录会清除配对信息，请在车旁打开 功能中心 → 蓝牙钥匙 完成配对",
                    seconds: 6
                )
            }
        } catch {
            // 补不上不打扰用户：没资格、离线、服务端拒绝都可能走到这，
            // 蓝牙钥匙页的 needsAttention 文案会兜底。
        }
    }

    @ObservationIgnored private var blePairingPreparationInProgress = false

    func prepareBLEPairing() async {
        guard !blePairingPreparationInProgress else {
            BLEDiagnostics.record("key", "pair.prepare.coalesced")
            return
        }
        blePairingPreparationInProgress = true
        defer { blePairingPreparationInProgress = false }
        BLEDiagnostics.record("key", "pair.prepare build=\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown")")
        guard bluetoothKeyEligible else {
            show(text: "当前环境不能使用蓝牙钥匙", isError: true)
            return
        }
        do {
            bleController.cancelPairing()
            let preparationGeneration = bleController.pairingPreparationGeneration
            let context = try await BLEPairingCredentialRefresh.resolve(cached: cachedBLECredentialContext()) {
                try await self.syncBLECredentialContext()
            }
            guard context.certificate.isSupportedKeyType else {
                throw LeapError.server(
                    "当前蓝牙证书类型不受支持（keyType=\(context.certificate.keyType)）"
                )
            }
            guard context.certificate.hasValidPasswordCard else {
                throw LeapError.server("当前蓝牙证书的 passwordCard 无效，请重新同步")
            }
            guard session.selectedVin == context.vin, session.oldAuth?.accountId == context.accountId, !isDemo else {
                throw LeapError.server("车辆已切换，请重新配对")
            }
            guard bleController.pairingPreparationGeneration == preparationGeneration else {
                BLEDiagnostics.record("key", "pair.prepare.cancelledDuringFetch")
                return
            }
            bleController.configureProduction(credentialContext: context, eligible: true)
            scheduleBLEProtocolVersionRefresh(accountId: context.accountId, vin: context.vin)
            await bleVersionRefreshTask?.value
            guard session.selectedVin == context.vin, session.oldAuth?.accountId == context.accountId, !isDemo else {
                throw LeapError.server("车辆已切换，请重新配对")
            }
            try Task.checkCancellation()
            guard bluetoothKeyEligible, session.deviceId == context.deviceId else {
                throw LeapError.server("当前环境已变化，请重新配对")
            }
            guard bleController.pairingPreparationGeneration == preparationGeneration else {
                BLEDiagnostics.record("key", "pair.prepare.cancelledDuringVersionFetch")
                return
            }
            bleController.beginPairing()
        } catch is CancellationError {
            BLEDiagnostics.record("key", "pair.prepare.cancelled")
        } catch {
            BLEDiagnostics.record("key", "pair.prepare.failed error=\(BLEDiagnostics.error(error))")
            show(error: error)
        }
    }

    func setBluetoothControlEnabled(_ enabled: Bool) {
        bleController.setBluetoothControlEnabled(enabled)
    }

    func refreshBLECalibration() async {
        guard let binding = bleController.binding else { return }
        BLEDiagnostics.record("key", "calibration.cloudFetch.begin multipleAnchors=\(session.selectedVehicle?.permission.contains("bleMultipleAnchors") == true)")
        do {
            let calibration = try await client.fetchBLECalibration(model: BLECalibration.deviceModel,
                multipleAnchors: session.selectedVehicle?.permission.contains("bleMultipleAnchors") == true,
                vin: binding.vin, accountId: binding.accountId)
            BLEDiagnostics.record("key", "calibration.cloudFetch.success \(BLEDiagnostics.configurationSummary(calibration.applying(to: binding.configuration)))")
            bleController.applyCalibration(calibration, accountId: binding.accountId, vin: binding.vin)
        } catch {
            BLEDiagnostics.record("key", "calibration.cloudFetch.failed \(BLEDiagnostics.failureDetail(error))")
            // 离线保留本机标定与用户选择，不阻止已有蓝牙钥匙工作。
        }
    }

    func setBLEUnlockDistance(_ distance: BLEUnlockDistance) async {
        guard let current = bleController.binding else { return }
        bleController.setUnlockDistance(distance)
        guard let updated = bleController.binding,
              updated.accountId == current.accountId, updated.vin == current.vin,
              updated.configuration.unlockDistance == distance else { return }
        let diagnosticConfiguration = BLEDiagnostics.configurationSummary(updated.configuration)
        BLEDiagnostics.record("key", "distance.cloudSave.begin \(diagnosticConfiguration)")
        do {
            try await client.saveBLECalibration(model: BLECalibration.deviceModel,
                                                configuration: updated.configuration, vin: updated.vin, accountId: updated.accountId)
            BLEDiagnostics.record("key", "distance.cloudSave.success vehicleConfirmation=separate \(diagnosticConfiguration)")
        } catch {
            BLEDiagnostics.record("key", "distance.cloudSave.failed \(diagnosticConfiguration) error=\(BLEDiagnostics.failureDetail(error))")
            if bleController.binding?.vin == updated.vin,
               bleController.binding?.accountId == updated.accountId {
                show(text: "距离已保存到手机，云端同步失败；靠近车辆后会下发设置", isError: true)
            }
        }
    }

    func setPassiveAutoUnlock(_ enabled: Bool) {
        bleController.updatePassiveEntry(
            autoUnlock: enabled,
            autoLock: bleController.autoLockEnabled
        )
    }

    func setPassiveAutoLock(_ enabled: Bool) {
        bleController.updatePassiveEntry(
            autoUnlock: bleController.autoUnlockEnabled,
            autoLock: enabled
        )
    }

    func removeBluetoothBinding() {
        bleController.removeBinding()
    }

    func updateApplicationActivity(_ active: Bool) {
        bleController.setApplicationActive(active)
    }

    // MARK: - 车型标定

    /// 这台车还没适配上的标定项。为空说明该认的字段都认全了，设置页里就不必出现标定入口。
    var pendingCalibrationTasks: [CalibrationTask] {
        guard let schema = state?.schema else { return [] }
        return CalibrationTask.all.filter { schema.key(for: $0.signal) == nil }
    }

    /// 标定用：绕开轮询和 `fetchInFlight` 直接取一份最新车况。
    ///
    /// 标定要自己控制采样节奏——用户点「我做好了」之后得连着刷几次等车上报，
    /// 走 `refresh()` 会被十秒一次的轮询占住。
    func captureSignalMap() async -> [String: String]? {
        guard !isDemo else { return nil }
        return try? await client.fetchVehicleState().signalMap
    }

    /// 标定结果落地，并立刻用新映射重解析一次——用户做完就该看见自己车的门窗锁。
    func applyCalibration(_ learned: [VehicleSignal: String]) async {
        guard !learned.isEmpty else { return }
        LearnedSignals.save(learned, for: session.selectedCarType)
        state = nil
        await refresh(showSpinner: true)
        show(text: "已适配 \(learned.count) 项车况")
    }

    /// 忘掉本机标定结果，回到内置映射表。
    func resetCalibration() async {
        LearnedSignals.clear(for: session.selectedCarType)
        state = nil
        await refresh(showSpinner: true)
        show(text: "已清除本机标定结果")
    }

    // MARK: - 控车

    /// 统一入口：所有会真正动车的指令都从这里走确认流程。
    /// 行驶中禁发的命令：尾门（130）和前备箱（131）。行驶中弹开箱盖挡视线是物理危险，
    /// 天窗/遮阳帘（300/240）不在列——那是乘员本来就会在行驶中动的东西。
    private static let drivingBlockedControls: [String: String] = ["130": "尾门", "131": "前备箱"]

    func perform(_ command: LeapCommand) {
        guard !isSendingCommand else { return }
        if let noun = Self.drivingBlockedControls[command.cmdid], state?.isDriving == true {
            show(text: "行驶中不能操作\(noun)", isError: true)
            return
        }
        if isDemo {
            show(text: "\(command.label)指令已发送", detail: "演示模式")
            return
        }
        pendingCommand = command

        guard command.requiresOperationPassword else {
            Task { await dispatch(command, password: "") }
            return
        }

        // 这次前台已经验证过了，不再打断。回到后台会作废。
        if let verified = verifiedPassword {
            Task { await dispatch(command, password: verified) }
            return
        }

        // 已保存密码 + 生物识别可用：用 Face ID 解锁本地密码，不打断操作。
        if biometricEnabled, biometricKind != .none, let saved = passwordStore.read(), !saved.isEmpty {
            Task {
                let ok = await BiometricGate.authenticate(reason: "验证身份以\(command.label)")
                if ok {
                    verifiedPassword = saved
                    await dispatch(command, password: saved)
                } else {
                    // 识别失败不静默丢弃指令，回退到手输密码。
                    challenge = .operationPassword(prompt: command.label)
                }
            }
            return
        }

        challenge = .operationPassword(prompt: command.label)
    }

    /// 充电计划保存：一次连发一批指令（健康充电 480 + 充电计划 190），共用一次操作密码验证。
    ///
    /// 复用 `perform` 的密码流程（前台已验证 / 生物识别 / 手输），只是把「单条」换成「整批」。
    /// 这批指令都是 `.unobservable`（车况里没有健康充电/充电计划的判定位），`dispatch` 会走
    /// 「已发送」快路径；服务端若拒绝（如健康充电开启时上限 >90）由 `assertSuccess` 抛错、
    /// `dispatch` 里的 `show(error:)` 如实弹出。
    func performCharge(_ commands: [LeapCommand]) {
        guard !isSendingCommand, !commands.isEmpty else { return }
        if isDemo {
            show(text: "充电计划已发送", detail: "演示模式")
            return
        }
        // 充电类指令不在行驶禁操作清单里，无需 driving 检查。
        let reason = "保存充电计划"
        if let verified = verifiedPassword {
            Task { await dispatchBatch(commands, password: verified) }
            return
        }
        if biometricEnabled, biometricKind != .none, let saved = passwordStore.read(), !saved.isEmpty {
            Task {
                if await BiometricGate.authenticate(reason: "验证身份以\(reason)") {
                    verifiedPassword = saved
                    await dispatchBatch(commands, password: saved)
                } else {
                    pendingCommand = nil
                    pendingChargeBatch = commands
                    challenge = .operationPassword(prompt: reason)
                }
            }
            return
        }
        pendingCommand = nil
        pendingChargeBatch = commands
        challenge = .operationPassword(prompt: reason)
    }

    /// 顺序下发一批指令，逐条走完整的 `dispatch`（错误提示和刷新都在里面）。
    /// 同一个 Task 里串行，`isSendingCommand` 在每条之间短暂翻假不影响——不会有并发重入。
    private func dispatchBatch(_ commands: [LeapCommand], password: String) async {
        for command in commands {
            await dispatch(command, password: password)
        }
    }

    /// 退到后台时作废本次验证，下次控车要重新过 Face ID 或密码。
    func endForegroundVerification() {
        verifiedPassword = nil
    }

    /// 用户在密码键盘上输满后调用。
    func submitOperationPassword(_ password: String, remember: Bool) {
        challenge = nil
        // 充电计划保存的批量指令优先——一次密码覆盖整批。
        let batch = pendingChargeBatch
        guard batch != nil || pendingCommand != nil else { return }
        if remember, !passwordStore.write(password) {
            // 存不进钥匙串就直说，别让用户以为记住了、下次又被要求手输。
            show(text: "密码这次没能记住", detail: "钥匙串写入失败")
        }
        // 不管记不记，这次前台内不再重复问。
        verifiedPassword = password
        if let batch {
            pendingChargeBatch = nil
            Task { await dispatchBatch(batch, password: password) }
            return
        }
        let command = pendingCommand!
        Task { await dispatch(command, password: password) }
    }

    func cancelChallenge() {
        let wasClimate = pendingCommand?.changesClimate ?? false
        challenge = nil
        pendingCommand = nil
        pendingChargeBatch = nil
        // 用户中途反悔，车没收到任何东西，界面不能停在新设定上，
        // 排队等着补发的那条也一起作废。
        if wasClimate {
            climatePushQueued = false
            climateEditedAt = nil
            rollbackClimateDraft()
        }
        // 座舱同理：用户在密码框上反悔，车什么都没收到，界面不能停在新档位上。
        // 连队列里排着的那几条（「全部关闭」一次压一批）一起作废。
        cancelPendingCabinPushes()
        cabinQueue.removeAll()
        cabinDrafts.removeAll()
        mirrorHeatingDraft = nil
        fridgeDraft = nil
    }

    private func dispatch(_ command: LeapCommand, password: String) async {
        isSendingCommand = true
        retryableCommand = nil
        defer {
            isSendingCommand = false
            pendingCommand = nil
            flushQueuedClimatePush()
            flushCabinQueue()
        }
        do {
            if let bleCommand = command.bleCommand, bluetoothKeyEligible {

                let result = await bleController.performControl(bleCommand)
                switch result {
                case .confirmed:
                    SharedSettings.recordControlError(nil)
                    lastReceipt = nil
                    show(text: successText(for: command), detail: "蓝牙直连")
                    await refresh()
                    // 蓝牙那条路确认在刷新之前，车窗这些得等刷新回来才知道，所以补一句。
                    if let reminder = lockReminder(for: command) { show(reminder) }
                    return

                case .sentWithoutConfirmation:
                    SharedSettings.recordControlError(nil)
                    lastReceipt = nil
                    show(
                        text: "\(command.label)已通过蓝牙发送",
                        detail: "未收到车辆动作确认，不会自动重复发送",
                        seconds: 5
                    )
                    await refresh()
                    return

                case .failedAfterWrite(let message):
                    lastReceipt = nil
                    show(
                        text: "\(command.label)结果不确定",
                        detail: "蓝牙指令已经开始写入，未自动改走网络：\(message)",
                        isError: true,
                        seconds: 6
                    )
                    return

                case .unavailableBeforeWrite:
                    break
                }
            }

            let receipt = try await client.sendControl(command, operationPassword: password)
            lastReceipt = receipt
            // 从 App 控成功了，卡片上那句「刚才那下没成」就该撤掉——
            // 否则用户明明已经在 App 里把车锁上了，卡片还要再挂五分钟的旧失败。
            SharedSettings.recordControlError(nil)
            // 车已经收到了，这份设定就算数了。
            if command.changesClimate { confirmedClimate = currentClimate }
            await confirm(command)
        } catch {
            // 指令根本没发出去，界面得退回车知道的那份设定。
            if command.changesClimate { rollbackClimateDraft() }
            // 密码错误时清掉已保存的密码，否则会一直用错的重试。
            if let message = (error as? LeapError)?.errorDescription, message.contains("密码") {
                passwordStore.clear()
                verifiedPassword = nil
            }
            show(error: error)
        }
    }

    /// 下发后等车真的动作。
    ///
    /// 服务端是异步执行的，返回 200 只代表受理；实测车辆要 5–10 秒才响应，
    /// 休眠时更久。所以这里**以车况为判据**——车自己报的状态才是真的，
    /// 而回执接口的返回结构至今没有已验证样本（`isSuccess` 在响应缺少
    /// code/result/status 时还会直接判成功，早期版本因此第一次查询就退出了）。
    ///
    /// 只轮询车况，不额外采集诊断回执。
    private func confirm(_ command: LeapCommand) async {
        let started = Date.now

        guard command.expectation.isObservable else {
            // 鸣笛这类动作车况里查不到，等一轮刷新就如实说"已发送"，不假称已生效。
            show(text: "\(command.label)指令已发送")
            try? await Task.sleep(for: .seconds(2))
            await refresh()
            if command.cmdid == "190" { await refreshChargePlan() }
            // 预约空调没有车况信号可确认，下发完回读一次预约表，界面上那行「车上当前预约」
            // 就是确认——读回来对上了才算真的设进去了。
            if command.cmdid == "171" { await refreshClimateAppointment() }

            return
        }

        confirmingLabel = command.label
        show(text: "\(command.label)指令已发送", detail: "等待车辆响应…", seconds: Self.confirmTimeout)
        // 后台那个 10 秒轮询会占住 fetchInFlight，把这里的刷新直接跳过，先停掉。
        stopPolling()
        defer {
            confirmingLabel = nil
            startPolling()
        }

        let deadline = started.addingTimeInterval(Self.confirmTimeout)
        while Date.now < deadline {
            try? await Task.sleep(for: Self.pollStep)

            await refresh()

            if let state, command.expectation.isSatisfied(by: state) {
                if let reminder = lockReminder(for: command) {
                    show(reminder)
                } else {
                    show(text: successText(for: command))
                }

                return
            }
        }

        // 窗口内没等到。不自动重发——尾门、鸣笛重发会真的再动一次车。
        retryableCommand = command
        show(
            text: "\(command.label)未收到车辆确认",
            detail: "车可能仍在唤醒，可稍后重试",
            isError: true,
            showsRetry: true,
            seconds: 10
        )

    }

    /// 实测车辆 5–10 秒响应，休眠时更久。20 秒是覆盖正常情况又不至于干等太久的折中。
    /// 已知一次真实样本：空调开启 11.8 秒确认。
    static let confirmTimeout: TimeInterval = 20

    /// 每 2 秒查一次。这个值同时决定了确认的时间分辨率——
    /// 间隔多长，"车实际什么时候动的"就有多大误差，而这个数字正是在用来定窗口长度。
    static let pollStep: Duration = .seconds(2)

    private func successText(for command: LeapCommand) -> String {
        switch command.expectation {
        case .locked(let locked): return locked ? "车辆已上锁" : "车辆已解锁"
        case .climate(let on, _, _, _): return on ? "空调已开启" : "空调已关闭"
        case .windowPosition: return "车窗已调整"
        case .trunkOpen(let open): return open ? "尾门已打开" : "尾门已关闭"
        case .frontTrunkOpen(let open): return open ? "前备箱已打开" : "前备箱已关闭"
        case .sentinel(let on): return on ? "哨兵已开启" : "哨兵已关闭"
        case .sunshadeOpen(let open): return open ? "遮阳帘已打开" : "遮阳帘已关闭"
        case .sunroofOpen(let open): return open ? "天窗已打开" : "天窗已关闭"
        case .charging(let start): return start ? "已开始充电" : "已停止充电"
        // 这几条的 label 本身就把位置和档位说全了（「主驾加热 2 档」），再套一层话术反而更绕。
        case .seatLevel, .steeringWheelLevel: return "\(command.label)已生效"
        case .mirrorHeating(let on): return on ? "后视镜加热已开启" : "后视镜加热已关闭"
        case .fridge(let setting): return setting.enabled ? "\(command.label)已生效" : "车载冰箱已关闭"
        case .unobservable: return "\(command.label)已完成"
        }
    }

    /// 锁车成功但还有东西开着时，把成功提示换成一句提醒（leapauto 的「锁车后检查」，2026-11-19 补上）。
    ///
    /// 用的是确认轮询刚刷回来的那份车况，不额外发请求。只看读得到的项，见 `VehicleState.openItemsAfterLock`。
    /// 锁本身是成功的，所以文案先说「已上锁」；用三角图标和多停几秒，是因为这句是要人回去处理的。
    private func lockReminder(for command: LeapCommand) -> ToastMessage? {
        guard case .locked(true) = command.expectation,
              let items = state?.openItemsAfterLock, !items.isEmpty
        else { return nil }
        return ToastMessage(
            text: "车辆已上锁",
            detail: "\(items.joined(separator: "、"))还开着",
            isError: true,
            seconds: 6
        )
    }

    private func show(_ message: ToastMessage) {
        toast = message
    }

    /// 超时提示上的重试。走完整的 perform 流程，该验身份还是要验。
    func retryLastCommand() {
        guard let command = retryableCommand else { return }
        retryableCommand = nil
        toast = nil
        perform(command)
    }

    // MARK: - 具体动作

    func toggleLock() {
        let locked = state?.isLocked ?? true
        perform(locked ? .unlock() : .lock())
    }

    /// 首页控车条的「上锁」「解锁」两格：方向写在按钮上，不看车况猜。
    func lockCar() { perform(.lock()) }
    func unlockCar() { perform(.unlock()) }

    /// 尾门开着就发关闭，否则发打开。读不到状态时按「开」走——
    /// 这是原来唯一的行为，未适配的车型不该因为这次改动变得更奇怪。
    ///
    /// 控车条上的尾门按钮已经改成先开弹窗、由用户挑开还是关（见 `TrunkControlSheet`），
    /// 这条只剩卡片/快捷指令那条路径在用——那边没有界面可弹，只能替用户判一次方向。
    func toggleTrunk() {
        // 关不了的车型（S01 / T03）只发得出「打开」。尾门开着时照着反转发一条关闭，
        // 车根本不会理，用户看到的是「按了卡片什么都没发生」。
        guard LeapCommand.trunkSupportsClose(carType: session.selectedCarType) else {
            setTrunk(open: true)
            return
        }
        setTrunk(open: !(state?.trunkOpen ?? false))
    }

    /// 明确开或关，方向由调用方给定。
    func setTrunk(open: Bool) {
        perform(.trunk(open: open))
    }

    /// 遮阳帘 / 天窗 / 前备箱。方向都由弹层里的用户点击给定（见 `TwoStateControlSheet`），
    /// 照 `setTrunk` 一行透传、无本地草稿。
    /// 车报着开度就等信号翻转确认，不报就照旧只说「已发送」（见 `LeapCommand.sunshade` 的说明）。
    func setSunshade(open: Bool) {
        perform(.sunshade(open: open, observable: state?.sunshadeOpen != nil))
    }

    func setSunroof(open: Bool) {
        perform(.sunroof(open: open, observable: state?.sunroofOpen != nil))
    }

    /// 远程开始 / 停止充电。按钮只在插着枪时出现（见 `ChargeView`），这里不重复判。
    func setCharging(start: Bool) { perform(.charging(start: start)) }

    func unlockChargingGun() { perform(.unlockChargingGun()) }

    func setFrunk(open: Bool) { perform(.frunk(open: open)) }

    func honk() { perform(.horn()) }

    func preheatBattery() { perform(.batteryPreheat(on: true)) }

    func stopBatteryPreheat() { perform(.batteryPreheat(on: false)) }

    func scheduleBatteryPreheat(at date: Date, enabled: Bool, days: [Int] = [1, 2, 3, 4, 5]) {
        // set_id 实测格式是「前缀_VIN_创建毫秒」，VIN 从当前选中车取（见 batteryPreheatAppointment）。
        perform(.batteryPreheatAppointment(on: enabled, startTime: date, days: days, vin: session.selectedVin))
    }

    /// 保存充电计划：充电上限 + 预约充电走 cmdid 190；若这次改了健康充电开关，再连发 cmdid 480。
    ///
    /// - Parameter healthyChargeOn: 传 nil 表示这次没动健康充电开关，不下发 480。开关初值已从车况信号 48
    ///   播种成真实态，没改就无需重复写一遍车上已有的设置，只在用户明确改动时才发。
    ///   健康充电开启时充电上限最多 90%，上限的封顶由界面负责，这里按传入值如实下发。
    func saveChargePlan(
        limitPercent: Int,
        scheduledEnabled: Bool,
        startTime: String,
        endTime: String,
        cycles: [Bool],
        circulation: Int,
        recharge: Int,
        healthyChargeOn: Bool?
    ) {
        var commands: [LeapCommand] = []
        // 先发健康充电：它决定上限封顶，先落定约束再发上限更稳妥。
        if let healthyChargeOn {
            commands.append(.healthyCharge(on: healthyChargeOn))
        }
        commands.append(.chargePlan(
            limitPercent: limitPercent,
            scheduledEnabled: scheduledEnabled,
            startTime: startTime,
            endTime: endTime,
            cycles: cycles,
            circulation: circulation,
            recharge: recharge
        ))
        performCharge(commands)
    }

    /// `openness` 是开度百分比：0 关闭、100 全开。
    func applyWindows(openness: Int) {
        perform(.window(openness: openness, carType: session.selectedCarType))
    }

    /// 哨兵模式开关。仿 `applyClimate`：下发 cmdid=400 命令，再由 `perform` 轮询车况直到
    /// `sentinelOn`（信号 3636）翻转到位。和空调不同，哨兵没有本地草稿位——界面直接读车况的
    /// `sentinelOn`，不做乐观翻转，少一处会和真车状态背离的草稿；控车确认由轮询刷新体现。
    func applySentinel(_ on: Bool) {
        perform(.sentinel(on))
    }

    func applyClimate(on: Bool) {
        climateOn = on
        perform(.climate(
            on: on,
            temperature: climateTemperature,
            fanLevel: climateFanLevel,
            mode: climateMode,
            circleIn: climateCircleIn,
            windshield: false
        ))
    }

    /// 空调已开时改参数才即时下发，关着的时候只改本地草稿。
    func pushClimateIfRunning() {
        guard climateOn else { return }
        // 上一条还在等车确认——那是个最长几十秒的窗口，`perform` 会把这条直接丢掉，
        // 用户就得再按一次，反馈出来正是「每次都要按两次」。记下来，等这条完事补发最新的。
        guard !isSendingCommand else {
            climatePushQueued = true
            return
        }
        applyClimate(on: true)
    }

    /// 补发那条被压下的空调指令，用的是用户最后调到的值。
    private func flushQueuedClimatePush() {
        guard climatePushQueued else { return }
        climatePushQueued = false
        guard climateOn, !isDemo else { return }
        Task { pushClimateIfRunning() }
    }

    func quickCool() {
        climateOn = true
        climateMode = .cold
        climateTemperature = 18
        climateFanLevel = 7
        perform(.quickCool())
    }

    func quickHeat() {
        climateOn = true
        climateMode = .hot
        climateTemperature = 32
        climateFanLevel = 7
        perform(.quickHeat())
    }

    func defrost() {
        climateOn = true
        perform(.defrost())
    }

    /// 快速除味：通风 + 外循环 + 7 档。草稿跟着改，免得页面上还停在原来的制冷 / 内循环。
    /// 温度草稿不动：通风模式下温度不起作用，车端会不会改设定温度也没验过，等车况回来再同步。
    func deodorize() {
        climateOn = true
        climateMode = .vent
        climateFanLevel = 7
        climateCircleIn = false
        perform(.deodorize())
    }

    // MARK: - 预约空调

    /// 车上预约空调的回读结果。`nil` 是还没读过。
    enum AppointmentReadback: Equatable {
        case loading
        /// 车上没有预约（回读到空 `controls`，或者里面没有开着的项）。
        case empty
        case loaded(ClimateAppointment)
        /// 读不到。和 `.empty` 必须分开说：读不到不等于没有。
        case failed(String)
    }

    private(set) var climateAppointmentReadback: AppointmentReadback?

    func refreshClimateAppointment() async {
        if isDemo {
            climateAppointmentReadback = .empty
            return
        }
        // 已经有结果时不把界面闪回「读取中」，只在第一次读时给转圈。
        if climateAppointmentReadback == nil { climateAppointmentReadback = .loading }
        do {
            let controls = try await client.fetchAppointmentControls(cmdid: "171")
            climateAppointmentReadback = ClimateAppointment.parse(controls: controls).map { .loaded($0) } ?? .empty
        } catch {
            climateAppointmentReadback = .failed(error.localizedDescription)
        }
    }

    /// 保存预约。改的是车上已有的那条时沿用它的 `set_id`（调用方从回读里带过来）。
    func saveClimateAppointment(_ appointment: ClimateAppointment) {
        perform(.climateAppointment(appointment, vin: session.selectedVin))
    }

    func cancelClimateAppointment() {
        perform(.cancelClimateAppointment())
    }

    // MARK: - 舒适座舱

    /// 松手到下发之间的防抖窗口。和空调页调温度那条是同一个值、同一个理由：
    /// 连点三下档位只该发最后那一档，不该打出一串远控请求。
    static let cabinPushDelay: Duration = .milliseconds(800)

    /// 座椅 / 方向盘档位的本机草稿。只活在「用户点了」到「这条指令跑完」之间：
    /// 跑完之后由 `clearCabinDraftsIfSettled` 清掉，界面落回车况报的真值——
    /// 成功就是新档位，失败就是原档位，不需要单独写一套回滚。
    private(set) var cabinDrafts: [String: Int] = [:]
    private(set) var mirrorHeatingDraft: Bool?

    /// 冰箱草稿。进页面时从车况播种（见 `seedFridgeDraft`），之后由界面直接改。
    var fridgeDraft: FridgeSetting?

    /// 每个「座位 + 通道」各一个防抖任务。**不能共用一个**：共用的话
    /// 「主驾调到 3 档后马上点副驾」会把主驾那条取消掉，用户看到的是主驾白点一遍。
    private var cabinPushTasks: [String: Task<Void, Never>] = [:]

    /// `perform` 是单航道的——上一条还在等车确认时它会把新指令直接丢掉。
    /// 座舱这页一次能点出好几条（四个座位，还有「全部关闭」一次发一批），
    /// 丢掉就等于用户点了没反应，所以压进队列，等上一条跑完再接着发。
    private var cabinQueue: [LeapCommand] = []

    private func cabinKey(_ position: SeatPosition, _ channel: SeatComfortChannel) -> String {
        "\(channel.rawValue)|\(position.rawValue)"
    }

    private static let steeringWheelKey = "steeringWheel"

    /// 界面读的档位：草稿优先，没有草稿就读车况。车况也读不到返回 nil——
    /// 那是「这车没这个座位」，界面该整块隐藏，不是显示 0 档。
    func seatLevel(_ position: SeatPosition, _ channel: SeatComfortChannel) -> Int? {
        if let draft = cabinDrafts[cabinKey(position, channel)] { return draft }
        return state?.seatLevel(position, channel)
    }

    var steeringWheelLevel: Int? {
        if let draft = cabinDrafts[Self.steeringWheelKey] { return draft }
        return state?.steeringWheelHeatLevel
    }

    var mirrorHeatingOn: Bool? { mirrorHeatingDraft ?? state?.mirrorHeatingOn }

    /// 方向盘加热剩余分钟。**只在车况报着加热开着时才有值**——草稿不参与，
    /// 因为剩余分钟是车端算的，本机刚点的那一档还没生效时没有对应的分钟数。
    /// 判据收在 `VehicleState.steeringWheelHeatMinutes`。
    var steeringWheelHeatMinutes: Int? { state?.steeringWheelHeatMinutes }

    /// 轻点座位：`0 → 1 → 2 → 3 → 0` 循环。读不到档位的座位界面上本来就不画，点不到。
    func cycleSeat(_ position: SeatPosition, _ channel: SeatComfortChannel) {
        guard let current = seatLevel(position, channel) else { return }
        setSeat(position, channel, level: (current + 1) % (channel.maxLevel + 1))
    }

    func setSeat(_ position: SeatPosition, _ channel: SeatComfortChannel, level: Int) {
        let key = cabinKey(position, channel)
        cabinDrafts[key] = min(channel.maxLevel, max(0, level))
        scheduleCabinPush(key: key) { [weak self] in
            guard let self, let target = cabinDrafts[key] else { return }
            enqueueCabin(.seatComfort(position: position, channel: channel, level: target))
        }
    }

    /// 方向盘加热：`0 → 1 → 2 → 0`，**两档**，和座椅不是一套量程。
    func cycleSteeringWheelHeat() {
        guard let current = steeringWheelLevel else { return }
        setSteeringWheelHeat(level: (current + 1) % 3)
    }

    func setSteeringWheelHeat(level: Int) {
        let key = Self.steeringWheelKey
        cabinDrafts[key] = min(2, max(0, level))
        scheduleCabinPush(key: key) { [weak self] in
            guard let self, let target = cabinDrafts[key] else { return }
            enqueueCabin(.steeringWheelHeating(level: target))
        }
    }

    /// 后视镜加热只有开 / 关两态，没有连点加档的场景，不走防抖，点了就发。
    func toggleMirrorHeating() {
        let next = !(mirrorHeatingOn ?? false)
        mirrorHeatingDraft = next
        enqueueCabin(.mirrorHeating(on: next))
    }

    /// 「全部关闭」：把当前**确实不为 0** 的项逐条发 0。
    ///
    /// 只发不为 0 的那几条：读不到档位的项（这车没这个座位）不该发，已经是 0 的项
    /// 再发一遍纯粹是多一次远控请求和一次等车确认。
    func closeAllCabinComfort() {
        var commands: [LeapCommand] = []
        for channel in SeatComfortChannel.allCases {
            for position in SeatPosition.allCases {
                guard let level = seatLevel(position, channel), level > 0 else { continue }
                cabinDrafts[cabinKey(position, channel)] = 0
                commands.append(.seatComfort(position: position, channel: channel, level: 0))
            }
        }
        if let level = steeringWheelLevel, level > 0 {
            cabinDrafts[Self.steeringWheelKey] = 0
            commands.append(.steeringWheelHeating(level: 0))
        }
        if mirrorHeatingOn == true {
            mirrorHeatingDraft = false
            commands.append(.mirrorHeating(on: false))
        }
        guard !commands.isEmpty else {
            show(text: "座舱加热与通风都已关闭")
            return
        }
        commands.forEach { enqueueCabin($0) }
    }

    /// 冰箱：电源键点了就发；其余设定项改完走防抖，和空调页调温度一个节奏。
    func setFridgePower(on: Bool) {
        var setting = fridgeDraft ?? state?.fridgeState?.asSetting ?? FridgeSetting()
        setting.enabled = on
        fridgeDraft = setting
        enqueueCabin(.fridge(setting))
    }

    func pushFridgeDraft() {
        guard let setting = fridgeDraft, setting.enabled else { return }
        scheduleCabinPush(key: "fridge") { [weak self] in
            guard let self, let latest = fridgeDraft else { return }
            enqueueCabin(.fridge(latest))
        }
    }

    /// 进冰箱页时把车况里的设定搬进草稿。已经有草稿就不动——
    /// 那是用户正在调的东西，被轮询回来的车况冲掉就是「调了弹回去」。
    func seedFridgeDraft() {
        guard fridgeDraft == nil else { return }
        fridgeDraft = state?.fridgeState?.asSetting
    }

    private func scheduleCabinPush(key: String, send: @escaping @MainActor () -> Void) {
        cabinPushTasks[key]?.cancel()
        cabinPushTasks[key] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.cabinPushDelay)
            guard !Task.isCancelled else { return }
            self?.cabinPushTasks[key] = nil
            send()
        }
    }

    /// 单航道被占着就排队，空着就直接发。
    private func enqueueCabin(_ command: LeapCommand) {
        guard !isSendingCommand, pendingCommand == nil else {
            cabinQueue.append(command)
            return
        }
        perform(command)
    }

    /// 上一条跑完后接着发队列里的下一条。
    private func flushCabinQueue() {
        guard !cabinQueue.isEmpty else { return }
        let next = cabinQueue.removeFirst()
        Task { @MainActor [weak self] in self?.perform(next) }
    }

    /// 车况回来时清掉已经尘埃落定的草稿。
    ///
    /// 「尘埃落定」= 没有待发的防抖任务、队列空了、也没有指令在飞或在等密码。
    /// 清掉之后界面读的就是车报的真值：成功显示新档位，失败显示原档位。
    private func clearCabinDraftsIfSettled() {
        guard cabinPushTasks.isEmpty, cabinQueue.isEmpty, !isSendingCommand, pendingCommand == nil else { return }
        if !cabinDrafts.isEmpty { cabinDrafts.removeAll() }
        mirrorHeatingDraft = nil
    }

    /// 离开座舱页时取消还没发出去的那几条。空调页 `onDisappear` 同理。
    func cancelPendingCabinPushes() {
        cabinPushTasks.values.forEach { $0.cancel() }
        cabinPushTasks.removeAll()
    }

    // MARK: - 提示

    func show(
        text: String,
        detail: String? = nil,
        isError: Bool = false,
        showsRetry: Bool = false,
        seconds: Double = 3
    ) {
        toast = ToastMessage(
            text: text,
            detail: detail,
            isError: isError,
            showsRetry: showsRetry,
            seconds: seconds
        )
    }

    func show(error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        if case LeapError.needsRelogin = error {
            // 故意**不**走 `expireSession`：那条路会把蓝牙钥匙证书和绑定一起清掉，
            // 而这个状态未必是登录态没了——多半是本机的设备号跟服务端记的那个对不上，
            // 车况照常刷新、新网关一切正常，只有老链路（远控/里程/位置）全废。
            // 自动清一遍等于顺手毁掉还能用的蓝牙钥匙，重登也不会自动恢复（见 iOS 已知问题）。
            //
            // 但也不能继续说「请稍后重试」——重试一万次都不会好。把话说明白，
            // 什么时候去重登由用户自己决定。停久一点，这条比普通失败重要。
            toast = ToastMessage(
                text: "控车授权已失效",
                detail: "重试无法恢复，请到「我的」退出登录后重新登录",
                isError: true,
                seconds: 8
            )
            return
        }
        toast = ToastMessage(text: message, isError: true)
        if case LeapError.sessionExpired = error {
            Task { await expireSession(reason: "某次请求判定登录失效：\(message)") }
        }
    }

    /// 最近一次主动校验登录态的时间。频繁切前后台时用它节流，别每次都打老链路。
    private var lastSessionValidation: Date?

    /// 主动确认登录态还在——开 App、回到前台时调用。
    ///
    /// 为什么要单独探：车况刷新走新网关读取 token，被挤下线后它仍活着，刷新永远发现
    /// 不了；真正会死的是老链路控车 token（详见 `LeapClient.validateSession`）。
    ///
    /// 两层节流：这里 30 秒内探过就跳过，挡住频繁切前后台；`LeapClient` 那边再看一次
    /// 老 token 有多新，刚换发过就直接认有效、连请求都不发——真正贵的不是这次请求，
    /// 是它换发的新 refreshToken 会让卡片进程手里那份当场作废。
    /// 返回 false 表示已判定失效并开始回登录页；true 表示有效或无法判定（按有效处理）。
    @discardableResult
    func validateSession(force: Bool = false) async -> Bool {
        guard session.isLoggedIn, !isDemo else { return true }
        if !force, let last = lastSessionValidation, Date.now.timeIntervalSince(last) < 30 {
            return true
        }
        lastSessionValidation = .now
        do {
            try await client.validateSession()
            return true
        } catch LeapError.sessionExpired {
            // 直接 await 处理失效，让调用方拿到确定的登录状态，不留 fire-and-forget 的竞态。
            show(text: "登录已过期", detail: "请重新登录", isError: true)
            await expireSession(reason: "前台探活：老链路续期被服务端拒绝")
            return false
        } catch {
            // 网络等其它错误：判不了，按有效继续，别打扰也别误踢。
            return true
        }
    }

    /// 服务端明确说登录态失效时退回登录页。留在首页只会不停弹同一条错误，
    /// 而用户根本没有入口重新登录。
    ///
    /// 操作密码不清：同一个账号重新登录后还是那一个，重新走一遍短信验证已经够验证身份了。
    private func expireSession(reason: String) async {
        // 守卫不能只看界面这份 session。它是 client 那份的拷贝，而且只在成功路径上同步：
        // `login()` 中途失败时界面这份还停在登录前的空态，client 内部却可能攥着半截凭证。
        // 只看 `isLoggedIn` 就会在这里直接 return，那份脏凭证于是永远清不掉——用户只能
        // 靠进一次演示模式再退出（那条路上的 `logout()` 没有守卫）才解得开。以 client 手里的为准。
        let live = await client.currentSession()
        guard session.isLoggedIn || live.hasAnyCredential else { return }
        stopPolling()
        endForegroundVerification()
        cancelBluetoothArmRetry()
        bleController.deactivate(clearBinding: true)
        await client.logout()
        // 卡片不能继续显示一份已经无法刷新的车况。
        snapshotStore.clear()
        LeapWidgets.reloadVehicleSurfaces()
        session = await client.currentSession()
        state = nil
        lastUpdated = nil
        locationName = nil
        challenge = nil
        pendingCommand = nil
        // 被踢回登录页后同样不能留着这台车的车图，下一位登录的可能是别的账号。
        unloadCarModel()
    }
}
