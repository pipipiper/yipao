import Foundation

/// 零跑中国 App 链路客户端。
///
/// 服务端同时存在两套鉴权：
/// - 老链路（appuser.leapmotor.cn / carownerservice / 远控）：MD5 短签名 + `XFX-CDN-CROSS-NODE` token。
/// - 新网关（app-gw-global）：HMAC-SHA256(signKey) 签名 + JWT accessToken。
/// 远控、里程、位置走老链路，车辆列表/路由/车况走新网关，两条链路的 token 各自续期。
actor LeapClient {
    private(set) var session: LeapSession
    /// 启动那一帧的会话快照。
    ///
    /// `session` 是 actor 隔离的，读它得 `await`，而界面第一帧等不了——等的结果就是
    /// 首帧按「没登录」渲染，登录页闪一下再被首页盖掉。钥匙串本身是同步读的，
    /// 所以这里在 init 时留一份不隔离的副本，专供首帧判断登录态。
    ///
    /// 之后的会话变更（登录、续期、退出）一律走 `session`，这份不再更新。
    nonisolated let initialSession: LeapSession
    private let store: SessionStore
    private let urlSession: URLSession

    /// 并发调用时只跑一次续期。
    private var refreshTask: Task<Void, Error>?
    private var oldRefreshTask: Task<Void, Error>?

    /// 续期的跨进程互斥。两条链路共用一把：老链路续期尾部还会重换新网关凭证，
    /// 两把锁反而要考虑重入。锁内第一件事永远是 `syncAuthFromStore()`——
    /// 等锁的这段时间里，别的进程多半已经把新凭证换好写回了。
    private let refreshLock = CrossProcessLock(name: "token-refresh.lock")

    /// 启动那帧钥匙串读失败了（不是「没有」，是「读不到」）。
    /// 那一帧会把有登录态的用户判成未登录，靠 `restoreSessionFromStore()` 自愈。
    private var startupLoadFailed: Bool

    /// 充电配置最多缓存 15 秒；进入编辑页和保存后强制读取。
    private var commonConfigCacheVin: String?
    private var commonConfigFetchedAt: Date?
    private var commonConfigAccount: String?
    private var commonConfigRequest = 0
    private var cachedChargePlan: ChargePlan?
    private var cachedChargePlanLimit: Int?

    /// 老链路连续被判「信息校验失败」（result=39）的次数，以及这串连败是从什么时候开始的。
    ///
    /// 单次 39 是抖动，`oldAuthedRequest` 已经按瞬时错误咽下去了（修 A）。但要是每一次
    /// 都失败、还持续了好几分钟，那就不是抖动，是本机这份身份和服务端记的对不上了
    /// （设备号漂移、token 被别处顶掉）——刷新 token 永远成功、重试永远失败，
    /// 用户看到的就是「按什么都提示指令下发失败，请稍后重试」，而且永远不会好。
    /// 那时候得明说「要重新登录」，不能让人一直按下去。
    private var oldAuthFailureStreak = 0
    private var oldAuthFailureStreakStartedAt: TimeInterval = 0

    init(store: SessionStore = SessionStore()) {
        self.store = store
        let restored: LeapSession
        switch store.loadOutcome() {
        case .found(let stored):
            restored = stored
            self.startupLoadFailed = false
        case .missing:
            restored = .fresh()
            self.startupLoadFailed = false
        case .failure:
            // 重启后未解锁被 BLE 恢复 / prewarming 拉起，就会走到这里。
            // 这一帧按未登录渲染无可避免，但绝不能把「读不到」定论成「没登录」。
            restored = .fresh()
            self.startupLoadFailed = true
        }
        self.session = restored
        self.initialSession = restored
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 40
        configuration.waitsForConnectivity = true
        self.urlSession = URLSession(configuration: configuration)
    }

    func currentSession() -> LeapSession { session }

    /// 启动那帧没读到钥匙串时的自愈：重读一次，读到登录态就整份采纳。
    ///
    /// 只在 `startupLoadFailed` 时才尝试——正常冷启动读到「确实没有」（`.missing`）
    /// 的，是真退登了，不该反复去钥匙串里翻。这个区分还挡住了一个更隐蔽的坑：
    /// 用户正在登录页输验证码时切走再切回（复制验证码就会），前台激活若无条件重读,
    /// 可能捞出一份被挤下线的作废旧会话，把登录页顶掉再被踢回来，输到一半的验证码就没了。
    ///
    /// 采纳是整份的（包括选中车、车辆列表）：本进程手里本来就是空的，没有覆盖问题。
    func restoreSessionFromStore() -> Bool {
        guard startupLoadFailed, !session.isLoggedIn, !session.hasAnyCredential else { return false }
        guard case .found(let stored) = store.loadOutcome() else { return false }
        // 只留一次机会给「读失败」：这次读成功了，无论里面有没有登录态，结论都定了。
        startupLoadFailed = false
        guard stored.isLoggedIn else { return false }
        session = stored
        return true
    }

    private func persist() {
        // 落盘前先看一眼别的进程有没有换发过凭证。整份写回是会覆盖的：本进程内存里
        // 那份 token 可能是几小时前的，直接盖上去等于把卡片刚换来的新 token 抹掉，
        // 下次续期就拿着作废的 refreshToken 去问服务端，被拒后判成登录失效。
        syncAuthFromStore()
        // 设备号是空的，说明本进程启动那帧钥匙串读失败、刚才 `syncAuthFromStore()`
        // 也没能读回来（手机仍锁着）。整份写回会把钥匙串里那个真设备号抹成空，
        // 老链路从此全废，且杀 App、重启手机都恢复不了——见 `adoptDeviceId`。
        guard !session.deviceId.isEmpty else {
            return
        }
        guard shouldPersistWholeSession() else { return }
        store.save(session)
    }

    /// 整份写回之前的最后一道闸：本进程手里这份是不是「空快照」。
    ///
    /// 设备号只是被这个问题咬得最狠的那个字段，选中车同样会被盖：启动那帧钥匙串读失败的
    /// 进程（卡片、控件 Intent、锁屏组件）内存里选中车是空的，它一次 `persist()` 就把
    /// 钥匙串里那辆抹掉——界面读内存、别的进程读钥匙串，两边从此认的不是同一辆车。
    ///
    /// 判据分两层，对应钥匙串的三态：
    /// - `.failure`：这一次读不到，那就什么都别写。手里这份到底是不是完整的，现在根本无从判断。
    /// - `.found`：钥匙串里有选中车而本进程没有，说明本进程这份是坏快照。反过来不成立——
    ///   选中车合法地变空只发生在退登/重置，而那两条走的是 `persistAuth()`，不经过这里。
    private func shouldPersistWholeSession() -> Bool {
        switch store.loadOutcome() {
        case .failure:
            return false
        case .missing:
            return true
        case .found(let latest):
            guard session.selectedVin.isEmpty, !latest.selectedVin.isEmpty else { return true }
            return false
        }
    }

    /// 凭证变更后**整份**落盘：打上新的版本号，别的进程据此认账。
    ///
    /// 整份写回意味着本进程手里的选中车、车辆列表也会一起盖上去，所以只有
    /// **本进程就是权威**的那几步能用它：登录（要把上一个账号的车清空）、
    /// 退登、重置会话。续期不行——见 `persistTokens()`。
    private func persistAuth() {
        session.authRevision = Date().timeIntervalSince1970 * 1000
        store.save(session)
    }

    /// 续期后落盘，**只写凭证，不碰选中车**。
    ///
    /// 续期会发生在卡片和控件进程里，而它们手里那份 session 是进程启动时的快照。
    /// 用 `persistAuth()` 整份写回的话，换过账号之后会这样：卡片第一次续期时
    /// `syncAuthFromStore` 发现 App 换发过，采纳凭证后让路——**但同步只搬凭证，
    /// 它内存里的选中车还是上一辆**；等版本号追平，下一次它自己续期就不再让路，
    /// 于是把上一辆车原样写回了钥匙串。
    ///
    /// 后果是读钥匙串的进程认错车（和界面读的内存不一致），App 冷启动也会读到并显示
    /// 上一辆车。见 `SessionCrossProcessTests`、`SessionSwitchAccountTests`。
    ///
    /// 所以这里以钥匙串里那份为底，只把凭证字段盖上去。钥匙串是空的（还没登录过）
    /// 就退回整份写——那种情况下本进程手里这份就是唯一的一份。
    private func persistTokens() {
        session.authRevision = Date().timeIntervalSince1970 * 1000
        guard let latest = store.load() else {
            // 钥匙串是空的（还没登录过），本进程手里这份就是唯一的一份。
            // 但读不出来也会走到这（锁屏期间被拉起），那就什么都别写——理由同 `persist()`。
            guard !session.deviceId.isEmpty else {
                return
            }
            store.save(session)
            return
        }
        guard let merged = Self.merging(tokensFrom: session, into: latest) else { return }
        store.save(merged)
    }

    /// 把 `source` 的凭证盖到 `base` 上，选中车、车辆列表、路由一概保留 `base` 的。
    ///
    /// 返回 nil 表示**这一次不该写**：`base` 里已经没有凭证了，说明续期这段时间里
    /// App 退了登（`logout` 会写一份空会话）。这时候把手里的新凭证写回去，
    /// 等于把刚退出的用户又装回登录态。
    ///
    /// 抽成静态纯函数是为了能测——`persistTokens` 本身要碰钥匙串。
    static func merging(tokensFrom source: LeapSession, into base: LeapSession) -> LeapSession? {
        guard base.oldAuth != nil || base.newAuth != nil else { return nil }
        var merged = base
        merged.oldAuth = source.oldAuth
        merged.newAuth = source.newAuth
        merged.authRevision = source.authRevision
        if !source.phone.isEmpty { merged.phone = source.phone }
        return merged
    }

    /// 从钥匙串捞一次别的进程换发的凭证，采纳了返回 true。
    ///
    /// 只同步凭证本身（`oldAuth` / `newAuth` / `phone`）。车辆列表、选中车、路由不动——
    /// 那些是本进程正在用的界面状态，卡片进程手里的往往更旧。
    @discardableResult
    private func syncAuthFromStore() -> Bool {
        guard let stored = store.load() else { return false }
        adoptDeviceId(from: stored)
        let mine = session.authRevision ?? 0
        let theirs = stored.authRevision ?? 0
        guard theirs > mine else { return false }
        session.oldAuth = stored.oldAuth
        session.newAuth = stored.newAuth
        if !stored.phone.isEmpty { session.phone = stored.phone }
        session.authRevision = theirs
        return true
    }

    /// 把钥匙串里那个 `deviceId` 对齐过来。**不看 `authRevision`**——设备号不随续期变，
    /// 它只有一个正确值：登录时上报给服务端、被服务端拿去绑 token 的那个。
    ///
    /// 这一步是「控车全废、只能重新登录」那个死结的关门处。原来的同步只搬凭证不搬设备号，
    /// 于是启动时钥匙串读失败的进程（重启未解锁被 BLE 恢复/控件预热拉起）会这样走：
    /// 手里是一份空会话 → 同步把凭证搬进来 → 会话变成「有凭证」，`restoreSessionFromStore()`
    /// 的守卫从此永远为假，自愈路彻底关死 → 设备号停在错的那个 → 老链路一律 `result=39`
    /// → `persist()` 整份写回时再把它钉进钥匙串，杀 App、重启手机都恢复不了。
    ///
    /// 现在 `fresh()` 留空设备号，这里再把真的那个补回来，两头一起把路堵死。
    private func adoptDeviceId(from stored: LeapSession) {
        guard !stored.deviceId.isEmpty, stored.deviceId != session.deviceId else { return }
        session.deviceId = stored.deviceId
    }


    /// 首次短信登录前给这台设备发一个设备号。**只有这一条路**能生成新设备号。
    ///
    /// 别处一律不发：换设备号会让老签名链路直接 `result=39`，而重新绑定只能靠重新登录。
    private func ensureDeviceId() {
        restoreDeviceIdFromStore()
        guard session.deviceId.isEmpty else { return }
        session.deviceId = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        // 立刻落盘：登录请求带的就是它，后面服务端拿它绑 token。这一步要是没写成，
        // 下次启动就成了「服务端记着一个设备号、本机手里另一个」——老链路全废。
        store.saveDeviceId(session.deviceId)
    }

    /// 从单独那条钥匙串项把设备号读回来。读不到就保持空着，**绝不发新的**。
    @discardableResult
    private func restoreDeviceIdFromStore() -> Bool {
        guard session.deviceId.isEmpty, let stored = store.loadDeviceId() else { return false }
        session.deviceId = stored
        return true
    }

    /// 发请求前确认手里有设备号，没有就这次别发。
    ///
    /// 空设备号发出去，老链路一律 `result=39`（服务端按 deviceID 取它记录的 token 重算签名），
    /// 而 App 会把 39 当成「该刷新 token 了」——刷新永远成功、重试永远失败，
    /// 用户看到的就是「按什么都提示指令下发失败」。宁可这一次不发。
    private func requireDeviceId() throws {
        restoreDeviceIdFromStore()
        guard session.deviceId.isEmpty else { return }
        throw LeapError.server("设备信息暂时读不到，请解锁手机后重试")
    }

    // MARK: - 登录

    func sendSMS(phone: String) async throws {
        // 登录链路是唯一允许发新设备号的地方，从发验证码这步就得有，
        // 后面 `oldAppHeaders()` 的 APPImei 要用它。
        ensureDeviceId()
        let cipher = try LeapCrypto.phoneNoCiphertext(phone)
        let response = try await request(
            url: "\(LeapConstants.appUserHost)/app-user/applogin/compliance/sendmessagecode",
            method: "GET",
            headers: oldAppHeaders(includeToken: false),
            query: ["phoneNo": cipher]
        )
        try assertSuccess(response, fallback: "验证码发送失败")
    }

    /// 短信验证码登录。
    ///
    /// 第一步先把本机会话清成干净态。这不是顺手做的清理，是这条链路能不能走通的前提：
    /// 被官方 App 挤下线后，本机手里那份 `oldAuth.token` 已经被服务端作废，而
    /// `oldAppHeaders()` 会把它当 `XFX-CDN-CROSS-NODE` 一起发出去——带着一个作废的
    /// token 去打登录接口，验证码再对也会被拒。用户看到的就是「验证码是对的，但报登录异常」。
    ///
    /// 更糟的是它会自锁死：`session.oldAuth` 在 `exchangeNewGateway()` **之前**就赋了值，
    /// 换网关那步一失败，内存里就留下一份「有 oldAuth、没 newAuth」的半截会话。
    /// 界面那边 `isLoggedIn` 为假，停在登录页，可 `expireSession()` 的守卫也正是看
    /// `isLoggedIn`，于是清理逻辑一次都跑不了——用户怎么重试都是同一个脏 token 发出去。
    /// 走一遍演示模式再退出（那条路上的 `logout()` 没有守卫）才解得开。
    ///
    /// 从干净态起步，上面两件事就都不成立了：header 里没有 token 可带，中途失败留下的
    /// 也是干净态而不是半截态。
    ///
    /// 保留 `deviceId`：换设备号会让老签名链路直接返回 result=39。
    func login(phone: String, smsCode: String) async throws {
        // 直接进登录页（没走发验证码那步，比如别的设备上收到码）时这里才真的生成。
        ensureDeviceId()
        // 顺带也把上一个账号的车辆列表、选中车和机房路由清了：`loadVehicles()` 只在
        // selectedVin 为空时才设默认车，留着旧 VIN 车况请求就会一直打别人的车。
        let deviceId = session.deviceId
        session = .fresh()
        session.deviceId = deviceId

        let params: [String: String] = [
            "phoneNoCiphertext": try LeapCrypto.phoneNoCiphertext(phone),
            "smsCode": smsCode,
            "deviceID": session.deviceId
        ]
        // 官方 iOS 1.20.64 的 loginwithphone 使用 POST_Form，三个参数放表单 body。
        // 复用严格百分号编码，避免手机号密文中的 Base64「+」被解析为空格。
        let response = try await request(
            url: "\(LeapConstants.appUserHost)/app-user/applogin/loginwithphone",
            method: "POST",
            headers: oldAppHeaders(includeToken: false),
            formBody: params
        )
        try assertSuccess(response, fallback: "验证码登录失败")

        session.phone = phone.trimmingCharacters(in: .whitespaces)
        session.oldAuth = try Self.extractOldAuth(response)
        do {
            try await exchangeNewGateway()
        } catch {
            // 换网关失败：把刚拿到的 oldAuth 丢掉，退回干净态再抛。
            // 留着它下一次登录就会带上，一次偶发失败会变成永久登不上。
            session = .fresh()
            session.deviceId = deviceId
            throw error
        }
        persistAuth()
    }

    func logout() {
        session = .fresh()
        store.clear()
        BLEKeyCertificateStore().clearAll()
        BLEReconnectTokenStore().clearAll()
        // 退登也是一次凭证变更，且必须是最新的那次：卡片进程可能正跑着一次拉取，
        // 它手里还是旧凭证，写回时得看到「退登比我新」才不会把人又装回登录态。
        persistAuth()
    }

    func resetSession() {
        let deviceId = session.deviceId
        session = .fresh()
        // 保留 deviceId：换设备号会让老签名链路直接返回 result=39。
        session.deviceId = deviceId
        store.clear()
        BLEKeyCertificateStore().clearAll()
        BLEReconnectTokenStore().clearAll()
        persistAuth()
    }

    /// 用老 token 换新网关的 accessToken / signKey。
    private func exchangeNewGateway() async throws {
        guard let oldAuth = session.oldAuth else { throw LeapError.notLoggedIn }
        let body: [String: String] = [
            "identifier": oldAuth.accountId,
            "identifierType": "1",
            "security": oldAuth.token
        ]
        let response = try await request(
            url: "\(LeapConstants.globalHost)/base/base-user/account/v1/login",
            method: "POST",
            headers: try newGatewayHeaders(params: body, needLogin: false),
            jsonBody: body
        )
        try assertSuccess(response, fallback: "新网关换取 token 失败")
        session.newAuth = try Self.extractNewAuth(response, oldAuth: oldAuth)
        persistTokens()
    }

    // MARK: - Token 续期

    /// 续期期间进来的请求先在这儿排一下队，等换发完再带着新凭证出门。
    ///
    /// 对齐官方的 `CacheRequestManager`：官方在刷新 token 期间把后来的请求整队缓存住，
    /// 刷新成功后拿新 token 重放，失败才一起失败。我们原来是「照发不误 → 拿旧 token 撞
    /// 401/39 → 各自再触发一次重试」，多打的那几发请求全是注定失败的，还平白抬高
    /// 服务端看到的鉴权失败频次（老链路的 39 更是会被风控盯上）。
    ///
    /// 只等、不发起，也不把续期的错误扣到这条请求头上：等完照发，成不成由它自己那套
    /// 判据（401 重试、39 冷却窗口、连败升级）说了算。续期失败时这条请求多半也会失败，
    /// 但失败的理由得是它自己撞出来的。
    ///
    /// 续期自身那几发请求走的是 `request(...)`，不经过这道闸，所以不会自等自。
    private func awaitOngoingRefresh() async {
        guard refreshTask != nil || oldRefreshTask != nil else { return }
        // 各等一次就够：等到的时候续期已经结束，紧接着又起的新一轮是下一次的事，
        // 再等下去会把这条请求无限期挂在这里。
        if let task = refreshTask { _ = try? await task.value }
        if let task = oldRefreshTask { _ = try? await task.value }
    }

    func refreshAccessToken() async throws {
        if let task = refreshTask { return try await task.value }
        let task = Task<Void, Error> { [self] in
            try await performAccessTokenRefresh()
        }
        refreshTask = task
        defer { refreshTask = nil }
        try await task.value
    }

    private func performAccessTokenRefresh() async throws {
        // 别的进程刚换来一份，直接用它的——refreshToken 每换发一次旧的就作废，
        // 这里再换一次，等于把它那份也作废掉，两个进程会互相把对方踢下线。
        if syncAuthFromStore() { return }
        // 跨进程串行化：revision 只能让「已写回」的换发被看见，两个进程**同时**
        // 发起续期的窗口要靠锁关上。等到锁后先再看一眼——等锁期间对方多半已换好。
        let holding = await refreshLock.acquire()
        defer { holding?.release() }
        if holding != nil, syncAuthFromStore() { return }
        guard let newAuth = session.newAuth, !newAuth.refreshToken.isEmpty else {
            throw LeapError.sessionExpired
        }
        let body = ["refreshToken": newAuth.refreshToken]
        let response = try await request(
            url: "\(LeapConstants.globalHost)/base/base-user/token/v1/refresh",
            method: "POST",
            headers: try newGatewayHeaders(params: body, needLogin: true),
            jsonBody: body
        )
        if !response.isSuccess {
            // 只有服务端明确说鉴权不过，才算登录态没了。限流、系统繁忙、字段改名
            // 都会走到这里，把它们一律当失效就是无缘无故把用户踢回登录页。
            if Self.isNewAuthFailure(response) {
                // 最后的兜底：被拒可能只是因为手里这份刚被别的进程换掉了
                //（锁超时降级、或对方绕过锁的老版本还在跑）。钥匙串里有更新的就采纳，
                // 这次续期等于别人替我们完成了。
                if syncAuthFromStore() {
                    return
                }
                // 官方在这一步不会退登：refreshToken 被拒时，用老 token 静默重走一次
                // `account/v1/login` 把新网关凭证整份换回来（官方 `PublicUtils.reLogin`
                // → `LoginManager` → identifier/identifierType/security，和这里的
                // `exchangeNewGateway()` 是同一个接口）。新网关那份本来就是从老 token
                // 派生的，老 token 还活着就没有任何理由把人踢回登录页。
                if session.oldAuth?.token.isEmpty == false {
                    do {
                        try await exchangeNewGateway()
                        return
                    } catch {
                        // 断网不算失效，原样抛回去让上层当网络错误处理。
                        if let leap = error as? LeapError, case .network = leap { throw leap }
                    }
                }
                throw LeapError.sessionExpired
            }
            let message = response.responseMessage
            throw LeapError.server(message.isEmpty ? "登录续期失败" : message)
        }
        session.newAuth = try Self.extractNewAuth(response, oldAuth: session.oldAuth)
        persistTokens()
    }

    func refreshOldToken() async throws {
        if let task = oldRefreshTask { return try await task.value }
        let task = Task<Void, Error> { [self] in
            try await performOldTokenRefresh()
        }
        oldRefreshTask = task
        defer { oldRefreshTask = nil }
        try await task.value
    }

    /// 老 token 续期：GET /app-user/appuseroperate/getnewtoken。
    /// refreshToken 参与签名但不出现在 query 里，只放在 `XFX-CDN-CROSS-REFRESH-NODE` 头。
    private func performOldTokenRefresh() async throws {
        // 同上：别的进程刚换发过就用它那份，不再自己换一次。
        if syncAuthFromStore() { return }
        // 同上：跨进程串行化，等到锁后再看一眼别人是不是已经换好了。
        let holding = await refreshLock.acquire()
        defer { holding?.release() }
        if holding != nil, syncAuthFromStore() { return }
        guard let oldAuth = session.oldAuth, !oldAuth.refreshToken.isEmpty else {
            throw LeapError.sessionExpired
        }
        guard !session.phone.isEmpty else {
            // 本机会话缺了手机号，续期签不出来。这是本地数据问题，不是服务端说登录态没了——
            // 当前 token 只要还没到期就照常能用，不该借机把人踢回登录页。
            throw LeapError.server("本地登录信息不完整，暂时无法续期")
        }
        let accountNumber = try LeapCrypto.phoneNoCiphertext(session.phone)
        var map: [String: String] = [
            "timespan": String(Int(Date().timeIntervalSince1970 * 1000)),
            "nonce": LeapCrypto.randomNonce(),
            "deviceID": session.deviceId,
            "refreshtoken": oldAuth.refreshToken,
            "accountId": oldAuth.accountId,
            "accountNumber": accountNumber
        ]
        let signStr = LeapCrypto.shortMD5(LeapCrypto.sortAndConcatValues(map))
        map.removeValue(forKey: "refreshtoken")
        map["signStr"] = signStr

        var headers = oldAppHeaders()
        headers["XFX-CDN-CROSS-REFRESH-NODE"] = oldAuth.refreshToken

        let response = try await request(
            url: "\(LeapConstants.appUserHost)/app-user/appuseroperate/getnewtoken",
            method: "GET",
            headers: headers,
            query: map
        )
        let data = response["data"] ?? response
        guard let token = data["token"]?.stringValue, !token.isEmpty, response.isSuccess else {
            // refreshToken 被服务端明确拒了，救不回来，只能重新短信登录。
            if Self.isOldAuthFailure(response) {
                // 最后的兜底：被拒也可能只是手里这份刚被别的进程换掉（锁超时降级）。
                // 钥匙串里有更新的就采纳，这次续期等于别人替我们完成了。
                if syncAuthFromStore() {
                    return
                }
                throw LeapError.sessionExpired
            }
            // 其余情况——限流、系统繁忙、响应结构变了——都不是登录态的事。
            // 原来这里一律抛 sessionExpired，服务端抖一下用户就被踢回登录页了。
            let message = response.responseMessage
            throw LeapError.server(message.isEmpty ? "登录续期失败" : message)
        }
        let expiredSeconds = Double(data["tokenExpired"]?.stringValue ?? "21600") ?? 21600
        let now = Date().timeIntervalSince1970 * 1000
        session.oldAuth = OldAuth(
            accountId: oldAuth.accountId,
            token: token,
            refreshToken: data["refreshToken"]?.stringValue ?? oldAuth.refreshToken,
            nickname: oldAuth.nickname,
            tokenExpired: String(Int(expiredSeconds)),
            tokenObtainedAt: now,
            tokenExpiresAt: now + expiredSeconds * 1000
        )
        persistTokens()
        // 新网关凭证绑定在老 token 上，续期后需要重新交换。
        // 换不成不影响这次续期的结果（老链路已经好了），但新网关那份会一直用旧的、
        // 直到 401 再走一次续期——所以失败要留痕，否则这条路是全静默的。
        do {
            try await exchangeNewGateway()
        } catch {
        }
    }

    /// 老链路请求 + `result=39` 自愈。对齐官方零跑 App 的做法：39 只当「这份 token 该
    /// 刷新了」，不当「登录态没了」。官方 `OKHttpLPClientRequest.tokenExpiration` 对国内
    /// 39 一律走 `handleRefreshToken`（刷新后重试），只有网关级 refreshToken 过期码
    /// （302010214 / 302010219）才会 `reLogin`——所以官方几乎不会莫名退登。
    ///
    /// - A：刷新后重试仍是 39，**不再抛 `sessionExpired`**（不清会话、不回登录页），改抛
    ///   瞬时业务错误。服务端在刚续期后的短窗口里对老链路回一两次 39 是常见抖动，把它
    ///   升级成退登正是「登录约 77 分钟后莫名掉登录」的直接根因。真正的失效仍由
    ///   `refreshOldToken` 内部 refreshToken 被拒（→ `sessionExpired`）兜底，对应官方 reLogin。
    /// - B：冷却窗口——老 token 是 `oldTokenReauthCooldown` 秒内换发的，再收到 39 就**不刷新**，
    ///   先采纳别进程可能换发的新凭证再重试一次，仍失败当瞬时错误。避免一次续期后紧跟的 39
    ///   触发第二次续期（旧 refreshToken 立刻作废，反而制造失效窗口），对齐官方 60 秒闸。
    private func oldAuthedRequest(
        transientFailureMessage: String,
        perform: () async throws -> JSONValue
    ) async throws -> JSONValue {
        // 正在换发凭证就先等着，别拿一个马上要作废的 token 出门。
        await awaitOngoingRefresh()
        var response = try await perform()
        guard Self.isOldAuthFailure(response) else {
            oldAuthFailureStreak = 0
            return response
        }

        if recentlyRefreshedOldToken() {
            // B：冷却窗口内不再续期。别的进程可能已换发，先采纳再重试一次。
            syncAuthFromStore()
            response = try await perform()
            if !Self.isOldAuthFailure(response) {
                oldAuthFailureStreak = 0
                return response
            }
            // A：仍是 39，当瞬时错误，不退登。
            throw noteOldAuthFailure(transientFailureMessage)
        }

        try await refreshOldToken()
        response = try await perform()
        if Self.isOldAuthFailure(response) {
            // A：刷新后仍 39，不再判定登录失效——这正是官方不会退登的场景。
            throw noteOldAuthFailure(transientFailureMessage)
        }
        oldAuthFailureStreak = 0
        return response
    }

    /// 记一次「刷新过还是 39」，并决定这次该抛哪种错。
    ///
    /// 修 A 把 39 从「退登」降成了「瞬时错误」，但只降了一半：真的救不回来时，
    /// 用户会永远看到「请稍后重试」，而重试一万次也不会好——他实际需要做的是重新登录，
    /// 却没人告诉他。这里补上那一半：连败次数够、且这串连败跨过了足够长的时间，
    /// 才升级成 `needsRelogin`（只提示，不清会话、不清蓝牙钥匙证书）。
    ///
    /// 两个条件都要满足是刻意的——服务端抖动是以秒计的，连着三次都在几秒内发生
    /// 只能说明用户手快，跨过 5 分钟仍每次都失败才叫「不会自己好」。
    private func noteOldAuthFailure(_ transientFailureMessage: String) -> Error {
        let now = Date().timeIntervalSince1970
        if oldAuthFailureStreak == 0 { oldAuthFailureStreakStartedAt = now }
        oldAuthFailureStreak += 1
        let spanned = now - oldAuthFailureStreakStartedAt
        guard Self.shouldEscalateOldAuthFailure(streak: oldAuthFailureStreak, spanned: spanned) else {
            return LeapError.server(transientFailureMessage)
        }
        return LeapError.needsRelogin
    }

    /// 连败到什么程度才算「重试也不会好」。抽成静态纯函数是为了能测。
    static func shouldEscalateOldAuthFailure(streak: Int, spanned: TimeInterval) -> Bool {
        streak >= LeapConstants.oldAuthFailureEscalationCount
            && spanned >= LeapConstants.oldAuthFailureEscalationWindow
    }

    /// 老 token 是否在续期冷却窗口内换发（含登录时初次取得）。`tokenObtainedAt` 是毫秒。
    private func recentlyRefreshedOldToken() -> Bool {
        guard let obtainedAt = session.oldAuth?.tokenObtainedAt, obtainedAt > 0 else { return false }
        let age = Date().timeIntervalSince1970 - obtainedAt / 1000
        return age >= 0 && age < LeapConstants.oldTokenReauthCooldown
    }

    private func ensureFreshAccessToken() async throws {
        // 先认一次别的进程换发的凭证：主 App 这个实例常驻，内存里那份可能是几小时前的，
        // 拿它去请求必然 401，再拿它的 refreshToken 去续期就是拿作废的换。
        syncAuthFromStore()
        guard let expiry = session.newAuth?.expiresAtDate else { return }
        if expiry.timeIntervalSinceNow <= LeapConstants.accessTokenLeeway {
            try await refreshAccessToken()
        }
    }

    private func ensureFreshOldToken() async {
        syncAuthFromStore()
        guard let expiry = session.oldAuth?.expiresAtDate else { return }
        if expiry.timeIntervalSinceNow <= LeapConstants.oldTokenLeeway {
            try? await refreshOldToken()
        }
    }

    /// 主动校验登录态。开 App、回前台时调用。
    ///
    /// 车况刷新走的是新网关读取 token——被别的设备挤下线后它仍然活着，所以刷新永远
    /// 探不到失效（用户「还能看到页面」正是这个原因）。真正会被服务端作废的是老链路
    /// 那条控车 token。这里主动对它做一次续期探测：`refreshToken` 被服务端拒 = 登录态
    /// 没了，抛 `sessionExpired`；网络等其它错误照原样抛出，**不**当作失效——弱网不该
    /// 把人误踢下线。续期成功顺带把控车 token 焐热，正好省下之后控车时的那次续期。
    ///
    /// 但探测不能每次开 App、每次回前台都真打一次续期：老 token 服务端给的是 6 小时，
    /// 每探一次就换发一次、旧 refreshToken 立刻作废，一天几十次轮换意味着几十个
    /// 「本进程手里那份刚被别人换掉」的窗口。所以刚换发过的就直接认有效——
    /// 那次换发本身就是服务端对这份登录态的确认，比再问一遍更可信也更便宜。
    func validateSession() async throws {
        syncAuthFromStore()
        guard let oldAuth = session.oldAuth else { throw LeapError.sessionExpired }
        let obtainedAt = oldAuth.tokenObtainedAt / 1000
        let age = Date().timeIntervalSince1970 - obtainedAt
        if obtainedAt > 0, age >= 0, age < LeapConstants.sessionProbeFreshness { return }
        try await refreshOldToken()
    }

    // MARK: - 车辆

    @discardableResult
    func loadVehicles() async throws -> [Vehicle] {
        let response = try await newGatewayRequest(
            url: "\(LeapConstants.globalHost)/app/app-global-service/v1/vehicle/list",
            method: "GET",
            params: [:]
        )
        try assertSuccess(response, fallback: "获取车辆列表失败")

        var seen = Set<String>()
        var vehicles: [Vehicle] = []
        for object in response.allObjects(where: { ($0["vin"]?.stringValue?.count ?? 0) >= 8 }) {
            guard let vin = object["vin"]?.stringValue, !seen.contains(vin) else { continue }
            seen.insert(vin)
            let carType = object["carType"]?.stringValue ?? object["cartype"]?.stringValue ?? ""
            // 车名优先取车主起的 `vinNickname`，没有就退到车型别名 `carAlias`；
            // 两个都空再兜到 carType，最后到「我的车」，避免空串。
            let name = object["vinNickname"]?.stringValue
                ?? object["carAlias"]?.stringValue
                ?? (carType.isEmpty ? "我的车" : carType)
            // 能力码全在 abilities 数组里（服务器原始短码 "1".."89"）。增程判据看含不含 "39"。
            let abilities = object["abilities"]?.arrayValue?.compactMap { $0.stringValue } ?? []
            let isExtendRange = abilities.contains("39")
            // 哨兵/遮阳帘/天窗/前备箱支持位走的是内部码（400/240/300/131），但 vehicle/list **没有**
            // permission 字段——原始码经 CarPerManager 那张表翻成内部码才对得上，见
            // Vehicle.permissionCodes(fromAbilities:)。此前这里读 object["permission"] 恒空，四个支持位
            // 对所有真实用户全判假、第二栏永不展开，就是这个 bug。为兼容「万一某网关真回 permission」
            // 仍保留兜底，与翻译结果合并去重。
            var permission = Vehicle.permissionCodes(fromAbilities: abilities)
            let literalPermission: [String]
            if let array = object["permission"]?.arrayValue {
                literalPermission = array.compactMap { $0.stringValue }
            } else if let joined = object["permission"]?.stringValue, !joined.isEmpty {
                literalPermission = joined.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            } else {
                literalPermission = []
            }
            for code in literalPermission where !permission.contains(code) { permission.append(code) }
            let isSentinelSupported = Vehicle.supportsSentinel(carType: carType, permission: permission)
            vehicles.append(Vehicle(
                vin: vin,
                carType: carType,
                name: name,
                isExtendRange: isExtendRange,
                permission: permission,
                isSentinelSupported: isSentinelSupported
            ))
        }
        session.vehicles = vehicles
        if session.selectedVin.isEmpty, let first = vehicles.first {
            session.selectedVin = first.vin
            session.selectedCarType = first.carType
            session.route = nil
        }
        persist()
        return vehicles
    }

    func selectVehicle(vin: String, carType: String = "") {
        session.selectedVin = vin
        let vehicle = session.vehicles.first { $0.vin == vin }
        session.selectedCarType = carType.isEmpty ? (vehicle?.carType ?? "") : carType
        // 别名是上一台车的，留着卡片会顶着旧车名，等新车资源就位再重新推。
        session.selectedCarAlias = nil
        session.route = nil
        // 充电配置缓存跟着 VIN 走，切车即失效（fetchVehicleState 还会按 VIN 再兜一次）。
        commonConfigCacheVin = nil
        cachedChargePlan = nil
        cachedChargePlanLimit = nil
        persist()
    }

    /// 记下从 3D 资源目录反推出来的车型别名，给界面和卡片显示用。
    func rememberCarAlias(_ alias: String?) {
        guard session.selectedCarAlias != alias else { return }
        session.selectedCarAlias = alias
        persist()
    }

    /// 车辆所在区域，决定车况/远控请求打到哪个机房。
    @discardableResult
    private func ensureRoute() async throws -> VehicleRoute {
        guard !session.selectedVin.isEmpty else { throw LeapError.missingVehicle }
        if let route = session.route, !route.appRegion.isEmpty { return route }

        let params = ["vin": session.selectedVin]
        let response = try await newGatewayRequest(
            url: "\(LeapConstants.globalHost)/app/app-global-service/v1/vehicle/getCarRoute",
            method: "GET",
            params: params,
            query: params
        )
        try assertSuccess(response, fallback: "获取车辆路由失败")
        let node = response["data"]?.objectValue
            ?? response.firstObject(where: { $0["appRegion"] != nil || $0["appCenter"] != nil })
        let route = VehicleRoute(
            appRegion: (node?["appRegion"]?.stringValue ?? "").trimmingTrailingSlash,
            appCenter: (node?["appCenter"]?.stringValue ?? "").trimmingTrailingSlash
        )
        guard !route.appRegion.isEmpty else { throw LeapError.server("车辆路由缺少 appRegion") }
        session.route = route
        persist()
        return route
    }

    /// - Parameter refreshConfig: 是否强制重拉 commonConfig（充电上限/充电计划）。
    ///   下拉/手动刷新传 `true`；轮询保持默认 `false`，走按 VIN 的缓存。
    func fetchVehicleState(refreshConfig: Bool = false) async throws -> VehicleState {
        let route = try await ensureRoute()
        let body = ["vin": session.selectedVin]
        let response = try await newGatewayRequest(
            url: "\(route.appRegion)/app/app-signal-service/signal/info/query",
            method: "POST",
            params: body,
            jsonBody: body
        )
        try assertSuccess(response, fallback: "获取车况失败")

        let container = response.firstObject(where: { $0["signalMap"]?.objectValue != nil })
        let signalNode = container?["signalMap"]
            ?? response["data"]?["signalMap"]
            ?? response["signalMap"]
        guard let map = signalNode?.objectValue else {
            // 找不到 signalMap 时，完整响应是唯一线索——新车型可能换了外层结构。
            throw LeapError.decode("车况响应里没有 signalMap")
        }
        var state = VehicleState()
        state.signalMap = map.compactMapValues { $0.stringValue }
        // 是不是增程车由 vehicle/list 的 abilities 决定，车况响应里没有，从选中车注入；
        // 匹配不到（会话里还没这辆车）就保持 false。下游油量显示全看这个开关。
        state.isExtendRange = session.selectedVehicle?.isExtendRange ?? false
        if commonConfigCacheVin != session.selectedVin || commonConfigAccount != session.oldAuth?.accountId {
            commonConfigCacheVin = nil
            cachedChargePlan = nil
            cachedChargePlanLimit = nil
        }
        if refreshConfig || commonConfigCacheVin == nil || Date.now.timeIntervalSince(commonConfigFetchedAt ?? .distantPast) >= 15 {
            // 配置失败不阻断普通车况，也不把失败记成成功缓存。
            _ = try? await refreshChargePlan()
        }
        state.chargePlanLimit = cachedChargePlanLimit
        state.chargePlan = cachedChargePlan
        // 车型不同，上报的字段命名体系也不同，按上报内容自己判断该用哪套表，
        // 再叠上车主自己标定出来的映射。
        state.schema = SignalSchema.detect(state.signalMap, carType: session.selectedCarType)
            .merging(LearnedSignals.keys(for: session.selectedCarType))
        state.collectedAt = .now
        return state
    }

    /// 独立于车况请求，避免保存后的强制读取被车况轮询吞掉。
    func refreshChargePlan() async throws -> ChargePlan? {
        let vin = session.selectedVin
        let account = session.oldAuth?.accountId
        commonConfigRequest += 1
        let request = commonConfigRequest
        let config = try await fetchCommonConfig()
        try Task.checkCancellation()
        guard vin == session.selectedVin, account == session.oldAuth?.accountId,
              request == commonConfigRequest else { throw LeapError.server("车辆或配置请求已更新，请重试") }
        let plan = ChargePlan.fromConfig(config)
        cachedChargePlan = plan
        cachedChargePlanLimit = plan?.percent
        commonConfigCacheVin = vin
        commonConfigAccount = account
        commonConfigFetchedAt = .now
        return plan
    }

    /// 拉 commonConfig（车辆公共配置），返回里面的 `data.config` 对象。
    ///
    /// 充电计划就在这张表的 `config."3"` 里——车况响应里没有，官方也是另发这个接口拿的
    /// （见 `VehicleState.chargePlanLimit(fromConfig:)`）。走老签名 GET，host 与预约端点
    /// 一致取 `appCenter ?? appRegion`，范式抄 `fetchCarModel()`。
    ///
    /// 返回 config 节点（可能为 nil：某些车型/版本不带）。调用方（`fetchVehicleState`）
    /// 用 `try?` 兜底，拉失败或没有 config 都不该影响车况本身。
    func fetchCommonConfig() async throws -> JSONValue? {
        let route = try await ensureRoute()
        await ensureFreshOldToken()
        let host = route.appCenter.isEmpty ? route.appRegion : route.appCenter
        let query = try oldSignedParams([
            "appVersion": session.appVersion,
            "osType": "iOS",
            "vin": session.selectedVin
        ])
        let response = try await request(
            url: "\(host)/carownerservice/v3/api/vehicleinfo/commonConfig",
            method: "GET",
            headers: oldAppHeaders(),
            query: query
        )
        try assertSuccess(response, fallback: "获取车辆配置失败")
        return response["data"]?["config"]
    }

    /// 回读车上已有的预约（目前只用于 cmdid 171 预约空调）。
    ///
    /// `GET {appCenter}/carownerservice/v3/api/appremotectl/getappointment?carvin=&cmdid=`，
    /// 老签名，host 取 `appCenter ?? appRegion`（和下发预约的端点同一台）。出处是 leapauto 记录的
    /// 官方抓包 `[334]`。返回 `controls[]`；`data` 本身是一段 JSON 字符串，解析见
    /// `ClimateAppointment.controls(fromAppointmentData:)`。解析不出抛错——那是「读不到」，
    /// 和「车上没有预约」（空数组）是两回事，界面要分开说。
    func fetchAppointmentControls(cmdid: String) async throws -> [JSONValue] {
        let route = try await ensureRoute()
        await ensureFreshOldToken()
        let host = route.appCenter.isEmpty ? route.appRegion : route.appCenter
        let query = try oldSignedParams([
            "carvin": session.selectedVin,
            "cmdid": cmdid
        ])
        let response = try await request(
            url: "\(host)/carownerservice/v3/api/appremotectl/getappointment",
            method: "GET",
            headers: oldAppHeaders(),
            query: query
        )
        try assertSuccess(response, fallback: "读取预约失败")
        guard let controls = ClimateAppointment.controls(fromAppointmentData: response["data"]) else {
            throw LeapError.server("预约数据格式无法识别")
        }
        return controls
    }

    // MARK: - 里程能耗统计

    /// 一次拉齐四个 drivingrecord 接口，揉成规范化统计。
    ///
    /// 接口路径/参数由 Frida 抓包实测（见 apk-analysis/leapmotor_api_interface.md §5.4）：
    /// - `mileage/energy/detail` 用 `vin`，且必须带 `begintime`+`endtime`，否则只回退化字段。
    /// - 能耗接口用 `carvin`；`getLastweekEC` 也要时间范围（返回的是能耗构成饼图）。
    /// 任一接口失败/该车不返回（如纯电车的 plugin）不影响其它块，缺的置 nil。
    func fetchDrivingStats(range: DrivingStatsRange? = nil) async throws -> DrivingStats {
        let route = try await ensureRoute()
        await ensureFreshOldToken()
        var seen = Set<String>()
        let hosts = [LeapConstants.globalHost, route.appCenter, route.appRegion]
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        let window = range ?? .lastSevenDays()
        let vin = session.selectedVin
        let timeParams = ["begintime": String(window.begintime), "endtime": String(window.endtime)]

        async let mileage = oldDrivingRecord("mileage/energy/detail",
            ["vin": vin].merging(timeParams) { _, new in new }, hosts: hosts)
        async let weeklyRank = oldDrivingRecord("getLastNweeks100kmECAndRank",
            ["carvin": vin], hosts: hosts)

        // 能耗构成默认跟着「本周」那根柱子走（和官方一致），可它的区间要等周列表回来才知道，
        // 所以这一发只能串在 weeklyRank 后面——总请求数没变，只多一个来回。
        // 周列表拉不到就退回 window（近 7 天）并把 distributionWeekID 留空，界面据此改口。
        let weeklyRaw = await weeklyRank
        let lastWeek = (weeklyRaw?["data"]?["weeklyEC"]?.arrayValue ?? []).last.map {
            DrivingStats.WeeklyEC(
                weekStart: $0["weekStart"]?.stringValue,
                weekEnd: $0["weekEnd"]?.stringValue,
                hundredKmEc: nil
            )
        }
        let distributionRaw = await fetchEnergyDistributionRaw(
            vin: vin, range: lastWeek?.range ?? window, hosts: hosts)

        return DrivingStats(
            mileageRaw: await mileage,
            distributionRaw: distributionRaw,
            weeklyRaw: weeklyRaw,
            range: window,
            distributionWeekID: lastWeek?.range == nil ? nil : lastWeek?.id
        )
    }

    /// 单独拉某个区间的能耗构成（`getLastweekEC`）。页面点周柱子时按周调，
    /// 拿不到就返回 nil——调用方按「这周没数据」处理，不许拿别的区间顶。
    func fetchEnergyDistribution(range: DrivingStatsRange) async throws -> DrivingStats.EnergyDistribution? {
        let route = try await ensureRoute()
        await ensureFreshOldToken()
        var seen = Set<String>()
        let hosts = [LeapConstants.globalHost, route.appCenter, route.appRegion]
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        let raw = await fetchEnergyDistributionRaw(vin: session.selectedVin, range: range, hosts: hosts)
        return DrivingStats.EnergyDistribution(raw: raw)
    }

    private func fetchEnergyDistributionRaw(vin: String, range: DrivingStatsRange,
                                            hosts: [String]) async -> JSONValue? {
        // 时间戳收**秒**，不是毫秒。同一个 drivingrecord 命名空间下 mileage/energy/detail
        // 收的是毫秒，唯独这个接口收秒——传毫秒不报「参数越界」也不返空，而是被网关判成
        // `code:2 请求参数含非法字符`，看着像签名或字符集问题，实际只是量纲错了（2026-08-18 实测）。
        await oldDrivingRecord("getLastweekEC", [
            "carvin": vin,
            "begintime": String(range.begintimeSeconds),
            "endtime": String(range.endtimeSeconds)
        ], hosts: hosts)
    }

    /// 老签名 GET 一个 drivingrecord 接口，按 host 依次 fallback（global 常 404，落到路由 host）。
    /// 失败/非成功响应返回 nil，交给上层揉数据时按缺失处理。
    private func oldDrivingRecord(_ path: String, _ params: [String: String], hosts: [String]) async -> JSONValue? {
        for host in hosts {
            do {
                let query = try oldSignedParams(params)
                let response = try await request(
                    url: "\(host)/carownerservice/v3/api/drivingrecord/\(path)",
                    method: "GET",
                    headers: oldAppHeaders(),
                    query: query
                )
                if response.isSuccess { return response }
            } catch {
                continue
            }
        }
        return nil
    }

    // MARK: - 充电记录

    func fetchChargingSummary(vehicle: VehicleIdentity, period: ChargingPeriod,
                              interval: DateInterval) async throws -> ChargingSummary {
        let path: String
        var params = ["vin": vehicle.vin]
        if period == .year {
            path = "statistic/year"
            params["year"] = String(ChargingPeriod.calendar.component(.year, from: interval.start))
        } else {
            path = "statistic/days"
            params["startTime"] = ChargingPeriod.apiDate(interval.start)
            params["endTime"] = ChargingPeriod.apiDate(interval.end)
        }
        let data = try await chargingRequest(path, params: params, vehicle: vehicle)
        return try ChargingSummary(data: data, interval: interval, period: period)
    }

    func fetchChargingRecordPage(vehicle: VehicleIdentity, interval: DateInterval,
                                 page: Int) async throws -> ChargingRecordPage {
        let data = try await chargingRequest("daily/detail/page", params: [
            "vin": vehicle.vin,
            "startTime": ChargingPeriod.apiDate(interval.start),
            "endTime": ChargingPeriod.apiDate(interval.end),
            "pageNum": String(page),
            "pageSize": String(ChargingRecordPage.size)
        ], vehicle: vehicle)
        return try ChargingRecordPage(data: data, page: page)
    }

    private func chargingRequest(_ path: String, params: [String: String],
                                 vehicle: VehicleIdentity) async throws -> JSONValue {
        guard VehicleIdentity(session: session) == vehicle else { throw LeapError.missingVehicle }
        let response = try await newGatewayRequest(
            url: "https://appgateway.leapmotor.com/carownerservice/charge/\(path)",
            method: "POST",
            params: params,
            jsonBody: params,
            vehicleContext: (accountId: vehicle.accountID, vin: vehicle.vin)
        )
        try Task.checkCancellation()
        guard VehicleIdentity(session: session) == vehicle else { throw LeapError.missingVehicle }
        try assertSuccess(response, fallback: "获取充电记录失败")
        guard let data = response["data"] else { throw LeapError.decode("缺少充电数据") }
        return data
    }

    // MARK: - 蓝牙钥匙

    /// 官方 iOS 从 commoninfo/sync 读取车辆版本，用于选择认证和配置字段。
    func fetchBLEProtocolMinor(vin: String, accountId: String) async throws -> Int {
        guard session.selectedVin == vin, session.oldAuth?.accountId == accountId else { throw LeapError.server("车辆已切换，请重试") }
        await ensureFreshOldToken()
        let route = try await ensureRoute()
        let host = route.appCenter.isEmpty ? route.appRegion : route.appCenter
        let response = try await oldAuthedRequest(transientFailureMessage: "蓝牙协议版本读取失败，请稍后重试") {
            guard self.session.selectedVin == vin, self.session.oldAuth?.accountId == accountId else { throw LeapError.server("车辆已切换，请重试") }
            return try await self.request(
                url: "\(host)/carownerservice/v3/api/commoninfo/sync",
                method: "POST", headers: self.oldAppHeaders(),
                formBody: try self.oldSignedParams(["type": "bluetoothMac", "vin": vin]), bleVersionDiagnostic: true)
        }
        guard session.selectedVin == vin, session.oldAuth?.accountId == accountId else { throw LeapError.server("车辆已切换，请重试") }
        try assertSuccess(response, fallback: "读取蓝牙协议版本失败")
        guard let minor = LeapBLEProtocol.cloudProtocolMinor(response: response) else {
            throw LeapError.decode("版本响应缺少有效的 data.list[0].bluetoothInfo，或版本格式不受支持")
        }
        return minor
    }

    func fetchBLECalibration(model: String, multipleAnchors: Bool = false, vin: String, accountId: String) async throws -> BLECalibration {
        guard session.selectedVin == vin, session.oldAuth?.accountId == accountId else { throw LeapError.server("车辆已切换，请重试") }
        let response = try await bleCalibrationRequest(path: "getAnchorPoint/calibrateParams", model: model)
        return try BLECalibration(json: response, multipleAnchors: multipleAnchors)
    }

    func saveBLECalibration(model: String, configuration: LeapBLEConfiguration, vin: String, accountId: String) async throws {
        guard session.selectedVin == vin, session.oldAuth?.accountId == accountId else {
            throw LeapError.server("车辆已切换，请重试")
        }
        let distance = configuration.unlockDistance
        var params = ["operate": distance == .standard ? "delete" : "add", "anchorType": configuration.multipleAnchors == true ? "1" : "0"]
        if distance != .standard { params["params"] = configuration.calibrationText }
        _ = try await bleCalibrationRequest(path: "uploadAutonomyCalibrateParams", model: model, body: params)
    }

    private func bleCalibrationRequest(path: String, model: String,
                                       body: [String: String]? = nil) async throws -> JSONValue {
        guard !session.selectedVin.isEmpty, let account = session.oldAuth?.accountId else { throw LeapError.notLoggedIn }
        let vin = session.selectedVin
        // Official service type 1 requires global gateway token/signature and POST form.
        BLEDiagnostics.record("key", "calibration.request route=globalApp auth=gateway method=POST encoding=form operation=\(path) model=\(BLEDiagnostics.safeMessage(model))")
        var params = body ?? ["manufacture": "iphone"]
        params["model"] = model.replacingOccurrences(of: " ", with: "")
        params["vin"] = vin
        let response = try await newGatewayRequest(
            url: "\(LeapConstants.globalHost)/app/app-global-service/v3/api/bluetoothkey/\(path)",
            method: "POST", params: params, formBody: params,
            vehicleContext: (accountId: account, vin: vin))
        guard session.selectedVin == vin, session.oldAuth?.accountId == account else { throw LeapError.server("车辆已切换，请重试") }
        BLEDiagnostics.record("key", "calibration.response success=\(response.isSuccess) code=\(BLEDiagnostics.safeMessage(response.responseCode ?? "missing")) message=\(BLEDiagnostics.safeMessage(response.responseMessage))")
        try assertSuccess(response, fallback: "距离设置同步失败")
        return response
    }

    func fetchBLEKeyCertificate() async throws -> LeapBLEKeyCertificate {
        guard !session.selectedVin.isEmpty else { throw LeapError.missingVehicle }
        guard session.oldAuth != nil else { throw LeapError.notLoggedIn }
        let vin = session.selectedVin
        let accountId = session.oldAuth?.accountId
        await ensureFreshOldToken()
        let route = try await ensureRoute()
        guard !route.appCenter.isEmpty else { throw LeapError.server("车辆中心路由为空") }

        func performRequest() async throws -> JSONValue {
            try await request(
                url: "\(route.appCenter)/carownerservice/v3/api/bluetoothkey/combine/syncBluetoothKeys",
                method: "POST",
                headers: oldAppHeaders(),
                formBody: try oldSignedParams(["vin": vin])
            )
        }

        let response = try await oldAuthedRequest(
            transientFailureMessage: "蓝牙钥匙证书同步失败，请稍后重试",
            perform: performRequest
        )
        try assertSuccess(response, fallback: "蓝牙钥匙证书同步失败")
        guard session.selectedVin == vin, session.oldAuth?.accountId == accountId else {
            throw LeapError.server("车辆已切换，请重新同步蓝牙钥匙")
        }
        guard let certificate = LeapBLEKeyCertificate(json: response, vin: vin) else {
            throw LeapError.decode("未找到当前车辆的蓝牙钥匙证书")
        }
        guard certificate.vin.isEmpty || certificate.vin == session.selectedVin else {
            throw LeapError.decode("蓝牙钥匙证书 VIN 不匹配")
        }
        do {
            try certificate.validatePasswordCard()
        } catch let error as LeapBLEProtocolError {
            throw LeapError.decode(error.errorDescription ?? "蓝牙钥匙证书 passwordCard 无效")
        }
        return certificate
    }

    // MARK: - 驻车照片

    /// 读取车辆驻车时自动上传的最近一张照片，不向车辆发送拍照指令。
    func fetchParkingPhoto() async throws -> ParkingPhoto {
        guard !session.selectedVin.isEmpty else { throw LeapError.missingVehicle }
        guard session.oldAuth != nil else { throw LeapError.notLoggedIn }
        let response = try await oldSignedGETWithFallback(
            path: "chassis/query",
            params: ["vin": session.selectedVin],
            preferredHosts: [LeapConstants.globalHost]
        )
        try assertSuccess(response, fallback: "驻车照片查询失败")

        return ParkingPhoto(response: response)
    }

    /// 图片地址由业务接口直接返回，不追加旧网关签名或登录凭证。
    func downloadParkingPhoto(from url: URL) async throws -> Data {
        guard url.scheme?.lowercased() == "https", url.host != nil else {
            throw LeapError.server("驻车照片地址不是安全连接")
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 30
        let (data, response) = try await send(request, retriesOnTimeout: true)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw LeapError.server("驻车照片下载失败")
        }
        guard !data.isEmpty else { throw LeapError.decode("驻车照片内容为空") }
        if let mime = http.mimeType?.lowercased(),
           !mime.hasPrefix("image/"),
           mime != "application/octet-stream" {
            throw LeapError.decode("驻车照片返回了非图片内容")
        }
        return data
    }

    /// 老签名 GET：鉴权失败时刷新一次 token，并按 global / appRegion / appCenter 回退。
    private func oldSignedGETWithFallback(
        path: String,
        params: [String: String],
        preferredHosts: [String] = []
    ) async throws -> JSONValue {
        await ensureFreshOldToken()
        let route = try await ensureRoute()
        var seen = Set<String>()
        let hosts = (preferredHosts + [LeapConstants.globalHost, route.appRegion, route.appCenter])
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        var lastError: Error?

        for host in hosts {
            do {
                let url = "\(host)/carownerservice/v3/api/\(path)"
                func perform() async throws -> JSONValue {
                    try await request(
                        url: url,
                        method: "GET",
                        headers: oldAppHeaders(),
                        query: try oldSignedParams(params)
                    )
                }
                let response = try await oldAuthedRequest(
                    transientFailureMessage: "接口返回失败，请稍后重试",
                    perform: perform
                )
                if response.isSuccess { return response }
                lastError = LeapError.server(response.responseMessage.isEmpty
                    ? "接口返回失败"
                    : response.responseMessage)
            } catch LeapError.sessionExpired {
                throw LeapError.sessionExpired
            } catch {
                lastError = error
            }
        }
        throw lastError ?? LeapError.server("请求失败")
    }

    // MARK: - 车模型（爱车图）

    /// 拉爱车页车模型。`carpicture/3d/key` 一个接口就区分 2D/3D（见 `CarModel`）。
    /// 走老签名 + host fallback（carpicture 挂在 appCenter，优先它）。
    func fetchCarModel() async throws -> CarModel {
        let route = try await ensureRoute()
        await ensureFreshOldToken()
        var seen = Set<String>()
        let hosts = [route.appCenter, route.appRegion, LeapConstants.globalHost]
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        let vin = session.selectedVin
        for host in hosts {
            do {
                let query = try oldSignedParams(["vin": vin])
                let response = try await request(
                    url: "\(host)/carownerservice/v3/api/carpicture/3d/key",
                    method: "GET",
                    headers: oldAppHeaders(),
                    query: query
                )
                if response.isSuccess, let model = CarModel(raw: response) { return model }
            } catch {
                continue
            }
        }
        throw LeapError.server("车模型接口无数据")
    }

    /// 下载 3D 资源包（模型 zip 或渲染器 zip）。
    ///
    /// 走的是 `carpicture/key/package`，返回体是 ZIP 二进制而不是 JSON，
    /// 所以不能借 `request`——它会把响应当 JSON 解，几 MB 的包再塞进字符串。
    func fetchCarModelPackage(key: String) async throws -> Data {
        guard !key.isEmpty else { throw LeapError.server("资源 key 为空") }
        let route = try await ensureRoute()
        await ensureFreshOldToken()
        var seen = Set<String>()
        let hosts = [route.appCenter, route.appRegion]
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        for host in hosts {
            do {
                var components = URLComponents(string: "\(host)/carownerservice/v3/api/carpicture/key/package")
                components?.queryItems = try oldSignedParams(["key": key])
                    .map { URLQueryItem(name: $0.key, value: $0.value) }
                guard let url = components?.url else { continue }
                var urlRequest = URLRequest(url: url)
                urlRequest.httpMethod = "GET"
                for (name, value) in oldAppHeaders() {
                    urlRequest.setValue(value, forHTTPHeaderField: name)
                }
                // 十几 MB 的包，默认超时不够。
                urlRequest.timeoutInterval = 120
                // 超时不重试：这个请求本来就给了 120 秒，再等一轮谁也受不了。
                let (data, response) = try await send(urlRequest, retriesOnTimeout: false)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                // 鉴权失败时服务端回的是 JSON 错误体，用 ZIP 魔数把它和真包区分开。
                guard (200..<300).contains(status), data.starts(with: [0x50, 0x4B]) else { continue }
                return data
            } catch {
                continue
            }
        }
        throw LeapError.server("车模型资源包下载失败")
    }

    // MARK: - 远控

    /// 发送远控指令，返回服务端回执里的 msgID。
    func sendControl(_ command: LeapCommand, operationPassword: String) async throws -> ControlReceipt {
        guard !session.selectedVin.isEmpty else { throw LeapError.missingVehicle }
        guard let oldAuth = session.oldAuth else { throw LeapError.notLoggedIn }
        if command.requiresOperationPassword && operationPassword.isEmpty {
            throw LeapError.server("该指令需要操作密码")
        }
        await ensureFreshOldToken()
        let route = try await ensureRoute()
        // 预约类命令是另一套端点，且优先打 appCenter。
        let url: String
        if command.isAppointment {
            let host = route.appCenter.isEmpty ? route.appRegion : route.appCenter
            url = "\(host)/carownerservice/v3/api/appremotectl/appointment"
        } else {
            url = "\(route.appRegion)/app/app-control-service/v3/api/appremotectl"
        }

        func buildBody() throws -> [String: String] {
            var params: [String: String] = [
                "cmdid": command.cmdid,
                "state": command.stateJSON,
                "carvin": session.selectedVin
            ]
            if !operationPassword.isEmpty {
                params["oppwd"] = try LeapCrypto.encryptOperationPassword(
                    operationPassword, oldToken: session.oldAuth?.token ?? oldAuth.token
                )
            }
            return try oldSignedParams(params)
        }

        let response = try await oldAuthedRequest(
            transientFailureMessage: "\(command.label)指令下发失败，请稍后重试"
        ) {
            let body = try buildBody()
            let raw = try await request(
                url: url, method: "POST", headers: oldAppHeaders(), formBody: body
            )
            return raw
        }
        try assertSuccess(response, fallback: "\(command.label)指令发送失败")

        let msgID = response.firstObject(where: { $0["msgID"] != nil || $0["msgId"] != nil })
            .flatMap { ($0["msgID"] ?? $0["msgId"])?.stringValue }
            ?? response["data"]?.stringValue
            ?? ""
        return ControlReceipt(msgID: msgID, label: command.label)
    }

    // MARK: - 请求装配

    /// 老链路通用头。
    ///
    /// `includeToken: false` 用于登录、发验证码这类**建立身份之前**的请求：它们不该带
    /// `XFX-CDN-CROSS-NODE`。本机手里那份 token 在被挤下线后已经作废，带上去只会让
    /// 服务端拒掉整个请求。靠调用点当时 `session.oldAuth` 恰好为空来保证是不够的——
    /// 显式关掉，将来谁在登录前动了 session 也不会把这条链路又打脏。
    private func oldAppHeaders(includeToken: Bool = true) -> [String: String] {
        var headers: [String: String] = [
            "APPPlatform": "iOS",
            "APPVersion": session.appVersion,
            "APPImei": session.deviceId,
            "C-VERSIONS": "APP",
            "XFX-CDN-VRS": "v4"
        ]
        if includeToken, let token = session.oldAuth?.token, !token.isEmpty {
            headers["XFX-CDN-CROSS-NODE"] = token
        }
        return headers
    }

    /// 老链路签名：timespan/nonce/deviceID/token + 业务参数，排序拼接后取短 MD5；token 本身不发送。
    private func oldSignedParams(_ params: [String: String]) throws -> [String: String] {
        guard let oldAuth = session.oldAuth else { throw LeapError.notLoggedIn }
        try requireDeviceId()
        var map: [String: String] = [
            "timespan": String(Int(Date().timeIntervalSince1970 * 1000)),
            "nonce": LeapCrypto.randomNonce(),
            "deviceID": session.deviceId,
            "token": oldAuth.token
        ]
        for (key, value) in params { map[key] = value }
        let signStr = LeapCrypto.shortMD5(LeapCrypto.sortAndConcatValues(map))
        map.removeValue(forKey: "token")
        map["signStr"] = signStr
        return map
    }

    /// 新网关签名：固定 8 个头字段 + 业务参数一起参与签名。
    /// 登录前用 sha256，登录后用 HMAC-SHA256(signKey)。
    private func newGatewayHeaders(params: [String: String], needLogin: Bool) throws -> [String: String] {
        try requireDeviceId()
        let nonce = LeapCrypto.randomNonce()
        let timestamp = String(Int(Date().timeIntervalSince1970 * 1000))
        var headers: [String: String] = [
            "source": "leapmotor",
            "channel": "1",
            "acceptLanguage": "zh-CN",
            "x-region": "CN",
            "x-api-signature-version": "2.0",
            "digest": "",
            "version": session.appVersion,
            "deviceType": "ios",
            "nonce": nonce,
            "timestamp": timestamp,
            "deviceId": session.deviceId,
            "userId": session.newAuth?.accountId ?? session.oldAuth?.accountId ?? "",
            "carvin": session.selectedVin,
            "cartype": session.selectedCarType,
            "x-subversion": session.subVersion
        ]
        let signHeaders: [String: String] = [
            "acceptLanguage": "zh-CN",
            "channel": "1",
            "deviceId": session.deviceId,
            "deviceType": "ios",
            "nonce": nonce,
            "source": "leapmotor",
            "timestamp": timestamp,
            "version": session.appVersion
        ]
        let signBase = LeapCrypto.sortAndConcatValues(signHeaders, params)
        if needLogin {
            guard let newAuth = session.newAuth, !newAuth.accessToken.isEmpty, !newAuth.signKeyData.isEmpty else {
                throw LeapError.notLoggedIn
            }
            headers["token"] = newAuth.accessToken
            headers["userId"] = newAuth.accountId.isEmpty ? (headers["userId"] ?? "") : newAuth.accountId
            headers["sign"] = LeapCrypto.hmacSHA256Hex(message: signBase, key: newAuth.signKeyData)
        } else {
            headers["sign"] = LeapCrypto.sha256Hex(signBase)
        }
        return headers
    }

    /// 新网关请求：先按需续期，失败时再续期重试一次。
    private func newGatewayRequest(
        url: String,
        method: String,
        params: [String: String],
        query: [String: String]? = nil,
        jsonBody: [String: String]? = nil,
        formBody: [String: String]? = nil,
        vehicleContext: (accountId: String, vin: String)? = nil
    ) async throws -> JSONValue {
        await awaitOngoingRefresh()
        try await ensureFreshAccessToken()

        func perform() async throws -> JSONValue {
            // Refresh awaits can switch the active account/vehicle; check before every send.
            if let vehicleContext {
                guard session.selectedVin == vehicleContext.vin,
                      session.oldAuth?.accountId == vehicleContext.accountId else {
                    throw LeapError.server("车辆已切换，请重试")
                }
            }
            return try await request(
                url: url,
                method: method,
                headers: try newGatewayHeaders(params: params, needLogin: true),
                query: query,
                jsonBody: jsonBody,
                formBody: formBody
            )
        }

        do {
            let response = try await perform()
            if !Self.isNewAuthFailure(response) { return response }
        } catch let error as LeapError {
            guard case .http(let status, _) = error, status == 401 || status == 403 else { throw error }
        }
        try await refreshAccessToken()
        let retried = try await perform()
        // 续期之后还是被拒，说明登录态真的失效了。这里不抛出去的话，
        // 界面会一直停在首页反复弹同一条错误，永远回不到登录页。
        if Self.isNewAuthFailure(retried) { throw LeapError.sessionExpired }
        return retried
    }

    // MARK: - 传输

    /// 所有 HTTP 请求的统一出口：带一次瞬时错误重试，并把 `URLError` 翻成用户话。
    ///
    /// **锁屏久了再解锁，回前台第一发几乎必失败**，成因不在我们这边：iOS 在锁屏期间会
    /// 挂起网络接口（Wi-Fi 省电断链、蜂窝无线电休眠、运营商 NAT 表项超时），而
    /// `URLSession` 连接池里那几条 keep-alive 的 TLS 连接其实已经死了、池子却不知道。
    /// 解锁后复用死连接发第一个包，内核立刻回 RST，抛出 -1005 `networkConnectionLost`
    /// ——它的系统中文文案正是用户看到的那句「网络连接已中断」。同一个成因在不同时序下
    /// 还会掉进 -1001 / -1009 / -1200，这就是「有时候是其他报错」。
    ///
    /// 上面那句 `waitsForConnectivity = true` 救不了：它只管「发起时完全没网」，而这里
    /// 连接明明「有」，只是已经死了，包早发出去了。唯一可靠的办法是重发一次——第一次失败
    /// 时坏连接已被踢出连接池，第二次必定新建连接。
    ///
    /// 重试范围只收**连接层就失败**的错误码，也就是包根本没能交给服务端的那几种；控车这类
    /// 非幂等 POST 走的也是这里，重发不会变成重复下发。超时（-1001）不在其列——请求可能
    /// 已经到了服务端、只是回包慢，所以只有幂等的 GET 才让它重试。证书类错误（-1202 等）
    /// 一概不重试：重发同样过不去，而且可能是中间人。
    private func send(_ request: URLRequest, retriesOnTimeout: Bool) async throws -> (Data, URLResponse) {
        do {
            return try await urlSession.data(for: request)
        } catch {
            guard Self.isRetriableTransportFailure(error, retriesOnTimeout: retriesOnTimeout) else {
                throw LeapError.wrapping(error)
            }
            // 给刚唤醒的网络接口一点时间，也确保坏连接确实已从连接池里摘掉。
            try? await Task.sleep(for: .milliseconds(300))
            do {
                return try await urlSession.data(for: request)
            } catch {
                throw LeapError.wrapping(error)
            }
        }
    }

    // internal 而非 private：这张判据表要被 `NetworkResilienceTests` 逐条钉住。
    static func isRetriableTransportFailure(_ error: Error, retriesOnTimeout: Bool) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        // 连接层就断了，包没能交给服务端——非幂等请求重发也安全。
        case .networkConnectionLost,   // -1005 复用死连接，锁屏解锁场景的主犯
             .notConnectedToInternet,  // -1009 蜂窝重新附着的那几秒
             .cannotConnectToHost,     // -1004
             .cannotFindHost,          // -1003
             .dnsLookupFailed,         // -1006
             .secureConnectionFailed:  // -1200 半死连接上重协商 TLS 失败
            return true
        // 请求可能已经到服务端了，只有幂等的才敢重发。
        case .timedOut:
            return retriesOnTimeout
        default:
            return false
        }
    }

    /// 按 RFC 3986 严格转义后拼成 `k=v&k=v`：只放行 unreserved（字母数字 `-._~`），
    /// 其余一律百分号编码。
    ///
    /// **不能用 `URLComponents.queryItems`。** 它的允许字符集放行 `+`，而
    /// `application/x-www-form-urlencoded` 规定 `+` 解码成空格——带 Base64 值的参数
    /// （`oppwd` 是 AES 密文的 Base64）只要撞上一个 `+`，服务端拿到的就和我们**签名时用的**
    /// 那串不是同一个东西，它重算 `signStr` 必然对不上，回 `result=39 信息校验失败`。
    ///
    /// 而 AES 密钥由 token 派生、加密是确定性的：同一个 token 周期内密文固定，
    /// 于是这 6 小时里**每一条**控制指令都失败，重试多少次都不会好；等续期换了 token
    /// 又可能自己好了。这正是「所有控制指令都下发失败、但查询一切正常」的来源——
    /// 查询类请求不带 `oppwd`，值全是十六进制和数字，永远撞不上。
    ///
    /// query 侧同样用它：URL query 里的 `+` 一样有被解成空格的实现，
    /// 而签名对不上时的报错完全一样，没有理由留着这个雷。
    static func strictFormEncoded(_ params: [String: String]) -> String {
        let unreserved = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        func escape(_ text: String) -> String {
            text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text
        }
        // 排序只为让日志和抓包里同一条请求每次长得一样，服务端不关心顺序。
        return params.keys.sorted()
            .map { "\(escape($0))=\(escape(params[$0] ?? ""))" }
            .joined(separator: "&")
    }

    private func request(
        url: String,
        method: String,
        headers: [String: String],
        query: [String: String]? = nil,
        jsonBody: [String: String]? = nil,
        formBody: [String: String]? = nil,
        emptyBody: Bool = false,
        bleVersionDiagnostic: Bool = false
    ) async throws -> JSONValue {
        guard var components = URLComponents(string: url) else {
            throw LeapError.server("非法的请求地址：\(url)")
        }
        if let query, !query.isEmpty {
            components.percentEncodedQuery = Self.strictFormEncoded(query)
        }
        guard let requestURL = components.url else {
            throw LeapError.server("无法构造请求地址：\(url)")
        }

        var urlRequest = URLRequest(url: requestURL)
        urlRequest.httpMethod = method
        for (key, value) in headers { urlRequest.setValue(value, forHTTPHeaderField: key) }

        if let jsonBody {
            urlRequest.setValue("application/json; charset=utf-8", forHTTPHeaderField: "content-type")
            urlRequest.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
        } else if let formBody {
            urlRequest.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "content-type")
            urlRequest.httpBody = Self.strictFormEncoded(formBody).data(using: .utf8)
        } else if emptyBody {
            urlRequest.httpBody = Data()
        }

        if bleVersionDiagnostic {
            BLEDiagnostics.record("key", "version.http.request method=\(method) host=\(requestURL.host ?? "unknown") path=\(requestURL.path) formKeys=\((formBody ?? [:]).keys.sorted())")
        }
        let (data, response) = try await send(
            urlRequest,
            retriesOnTimeout: method.uppercased() == "GET"
        )
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if bleVersionDiagnostic { BLEDiagnostics.record("key", "version.http.response status=\(status) bytes=\(data.count)") }
        let value: JSONValue
        if data.isEmpty {
            value = .null
        } else if let decoded = try? JSONDecoder().decode(JSONValue.self, from: data) {
            value = decoded
        } else {
            value = .object(["raw": .string(String(data: data, encoding: .utf8) ?? "")])
        }
        if bleVersionDiagnostic { BLEDiagnostics.record("key", "version.response \(BLEDiagnostics.versionResponseSummary(value))") }
        guard (200..<300).contains(status) else {
            throw LeapError.http(status, value.responseMessage.isEmpty
                ? String(data: data.prefix(200), encoding: .utf8) ?? ""
                : value.responseMessage)
        }
        return value
    }

    private func assertSuccess(_ response: JSONValue, fallback: String) throws {
        guard !response.isSuccess else { return }
        let message = response.responseMessage
        throw LeapError.server(message.isEmpty ? fallback : message)
    }

    // MARK: - 响应解析

    private static func extractOldAuth(_ response: JSONValue) throws -> OldAuth {
        let node = response["data"]?["appLoginVO"]?.objectValue
            ?? response["data"]?["appOneLoginVO"]?.objectValue
            ?? response.firstObject(where: { $0["accountId"] != nil && $0["token"] != nil })
        guard
            let node,
            let accountId = node["accountId"]?.stringValue,
            let token = node["token"]?.stringValue
        else {
            throw LeapError.decode("登录响应里没有 accountId/token")
        }
        let expiredSeconds = Double(node["tokenExpired"]?.stringValue ?? "") ?? 0
        let now = Date().timeIntervalSince1970 * 1000
        return OldAuth(
            accountId: accountId,
            token: token,
            refreshToken: node["refreshToken"]?.stringValue ?? "",
            nickname: node["nickname"]?.stringValue ?? "",
            tokenExpired: expiredSeconds > 0 ? String(Int(expiredSeconds)) : "",
            tokenObtainedAt: now,
            tokenExpiresAt: expiredSeconds > 0 ? now + expiredSeconds * 1000 : 0
        )
    }

    private static func extractNewAuth(_ response: JSONValue, oldAuth: OldAuth?) throws -> NewAuth {
        let node = response["data"]?.objectValue
            ?? response.firstObject(where: { $0["accessToken"] != nil && $0["signParam"] != nil })
        guard
            let node,
            let accessToken = node["accessToken"]?.stringValue,
            let r2 = node["signParam"]?["r2"]?.stringValue,
            let r3 = node["signParam"]?["r3"]?.stringValue
        else {
            throw LeapError.decode("新网关响应里没有 accessToken/signParam")
        }
        let signKey = try LeapCrypto.deriveSignKey(accessToken: accessToken, r2: r2, r3: r3)
        let jwtExpiry = LeapCrypto.jwtExpiryMilliseconds(accessToken)
        let fallbackExpiry = Double(node["tokenExpireTime"]?.stringValue ?? "").map {
            Date().timeIntervalSince1970 * 1000 + $0 * 1000
        } ?? 0
        return NewAuth(
            accountId: oldAuth?.accountId ?? node["accountId"]?.stringValue ?? "",
            gatewayAccountId: node["accountId"]?.stringValue ?? "",
            accessToken: accessToken,
            refreshToken: node["refreshToken"]?.stringValue ?? "",
            accessTokenExpiresAt: jwtExpiry > 0 ? jwtExpiry : fallbackExpiry,
            nickname: node["nickname"]?.stringValue ?? "",
            signKeyBase64: signKey.base64EncodedString()
        )
    }

    /// 需要重新登录的强判据文案：命中任意一条即视为登录态失效。
    /// 两类：登录/会话/token 明确过期失效、异地或他设备登录被挤下线。
    /// 都是能独立成立的多字短语，避免「登录成功」这类误伤。
    /// 匹配前统一小写并去空格，容忍「token 失效」这种中间带空格的写法。
    ///
    /// 这张表只收「除了重新登录没有别的解释」的文案。以下几条曾经在表里，都撤了：
    /// - 「已下线」：撞的是「**车辆**已下线」，车在休眠而已，跟登录态无关。
    /// - 「未授权」：撞的是「未授权访问该车辆」，是这辆车的权限问题。
    /// - 「信息校验失败」：老链路签名不过就是这句——设备时钟偏一点、nonce 撞了都会出，
    ///   续期救不了它，重试还是同一句，于是稳定地把用户踢回登录页。
    /// - 「鉴权失败」「认证失败」「身份验证失败」：同一个理由，签名不过也叫这几个名字，
    ///   分不出是「这次请求没签对」还是「这个人不该在线」。真正的失效有 401/403 和
    ///   result=39 兜着，不缺这几条。
    /// 宁可漏判：漏了顶多多弹一次错误提示，误判是直接清掉登录态。
    private static let reauthPhrases: [String] = [
        // 登录 / 会话 过期失效
        "重新登录", "登录已失效", "登录失效", "登录已过期", "登录过期",
        "登录信息已过期", "登录信息失效", "登录状态已失效", "登录状态失效", "登录态失效",
        "会话已过期", "会话过期", "会话失效", "账号已失效", "账号失效",
        // token 类
        "token失效", "token已失效", "token过期", "token已过期",
        "tokeninvalid", "tokenexpired", "第三方token失效",
        // 异地 / 他设备登录被挤下线
        "异地登录", "其他设备登录", "其它设备登录", "别处登录", "别的设备登录",
        "换设备登录", "其他终端登录", "被挤下线", "顶下线", "强制下线",
        // 未登录：服务端明说这次请求没带上有效身份，没有第二种解释。
        "未登录",
    ]

    private static func matchesReauthPhrase(_ message: String) -> Bool {
        let normalized = message.lowercased().replacingOccurrences(of: " ", with: "")
        return reauthPhrases.contains { normalized.contains($0) }
    }

    /// 老链路失效标志：result=39 或命中失效文案。
    private static func isOldAuthFailure(_ response: JSONValue) -> Bool {
        if response["result"]?.stringValue == "39" {
            return true
        }
        let message = response.responseMessage
        if matchesReauthPhrase(message) {
            return true
        }
        return false
    }

    private static func isNewAuthFailure(_ response: JSONValue) -> Bool {
        if let code = response.responseCode, code == "401" || code == "403" {
            return true
        }
        let message = response.responseMessage
        if matchesReauthPhrase(message) {
            return true
        }
        // 这里原来还有一条组合兜底：消息里同时出现「登录/鉴权/认证/授权/token」和
        // 「过期/失效/无效」就判失效。撤掉了——「无效」「授权」在业务报错里太常见，
        // 「该车辆未授权，参数无效」这种句子会被它一并判成登录失效，把人踢回登录页。
        // 401/403 才是新链路的强判据，兜底那点覆盖率不值这个代价。
        // 成功响应也会走这个判断，别把正常返回也刷进日志。
        return false
    }
}

private extension String {
    var trimmingTrailingSlash: String {
        var value = self
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }
}
