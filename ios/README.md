# 壹跑 iOS

零跑汽车第三方控车 App「壹跑」的 iOS 端。SwiftUI 原生实现，iOS 26 上使用液态玻璃，低版本自动降级成毛玻璃；最低支持 iOS 18.2。

本项目与零跑汽车没有任何隶属或授权关系，只使用车主自己的零跑账号访问零跑官方服务。请只控制属于你自己或你已获授权的车辆。

## 功能

- **登录**：零跑账号短信验证码登录，登录态与操作密码只保存在本机钥匙串（仅本设备，不同步、不进备份）。
- **车况**：电量 / 续航（含增程车型油量）、充电状态、门窗锁、尾门、胎压、空调、车辆位置等，前台定时轮询。
- **远程控车**：开关车锁、鸣笛寻车、尾门、车窗、天窗 / 遮阳帘 / 前备箱（按车型能力码显示）、空调（温度 / 风量 / 模式）、远程启停充电、解锁充电枪、哨兵模式等。所有会动车的指令都要先通过 Face ID / 触控 ID 或操作密码验证。
- **功能中心**：侧边操作按钮、锁屏控件、桌面小组件直接控车；蓝牙钥匙（可信车辆绑定、近车直连、无感解闭锁）；电池预热；充电计划；舒适座舱（座椅加热 / 通风、方向盘加热、后视镜加热）；车载冰箱；预约空调。
- **座舱控制**：顶部页签切换空调控制与舒适座舱，每张座椅可独立调整加热和通风。
- **桌面卡片与锁屏控件**：多种尺寸的车况小组件、锁屏车锁 / 鸣笛控件、控车过程的灵动岛（Live Activity）、长按图标快捷操作。没有 App Group 的构建仍可通过主 App 与扩展共用的钥匙串组显示只读电量、续航、充电状态和更新时间，轻点卡片可打开主 App。先在 App 内刷新一次以生成快照。
- **车辆位置**：地图显示车辆与本机位置，可跳转苹果 / 高德 / 百度 / 腾讯地图导航，显示最近一张驻车照片。
- **行程**：零跑官方的里程能耗统计。
- **充电记录**：「能源」页面底部可查看，「功能 → 能源 → 充电记录」也有独立页面。按周、月、年查看当前车辆的充电次数、充入电量和快充占比。轻点图表选择日期或月份，查看分页明细。日期统一按北京时间显示。
- **爱车外观**：在「设置 → 爱车外观」选择首页主题色，或为当前车辆从相册导入主图。照片只保存在本机，支持透明背景，可随时恢复默认车图。
- **演示模式**：登录页提供演示账号（手机号 `13800138000`、验证码 `000000`），使用写死的模拟车况，不发任何网络请求、不会向任何车辆下发指令。

## 开发环境

- macOS + Xcode 26（正式版），iOS 26 SDK
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)：`brew install xcodegen`
- 真机调试需要一个 Apple 开发者账号（免费账号也可以装到自己的设备上，但 App Groups 等能力受限）

第三方依赖只有 `Vendor/GmSSL/GmSSL.xcframework`（国密 SM2 / SM3 / SM4，用于新款车型的蓝牙钥匙认证），已随仓库提供，许可证见同目录下的 LICENSE 文件。

## 目录结构

```text
project.yml        XcodeGen 工程描述（.xcodeproj 由它生成，不入库）
LeapControl/
  App/             全局状态（VehicleStore）、入口、蓝牙控制器、演示数据
  Core/            鉴权、签名、网络、车况解析、蓝牙协议、国密封装（无 UI 依赖）
  DesignSystem/    背景、玻璃卡片、配色
  Features/        各个页面
  Shared/          App 与小组件共用的快照、偏好、App Intents、Live Activity
  Legal/           App 内展示的用户协议与隐私政策
LeapWidget/        小组件扩展（桌面卡片、锁屏控件、灵动岛）
LeapControlTests/  单元测试（签名对拍、车况字段语义、蓝牙协议、会话并发等）
Vendor/GmSSL/      GmSSL 预编译库
```

## 编译前要自己准备的配置

| 配置 | 位置 | 说明 |
| --- | --- | --- |
| Apple Team ID | `project.yml` 里的 `DEVELOPMENT_TEAM` | 仓库里留空。只在模拟器上跑可以不填；装真机必须填你自己的 Team ID，或者生成工程后在 Xcode 的 Signing & Capabilities 里选择。 |
| Bundle ID | `project.yml` 各 target 的 `PRODUCT_BUNDLE_IDENTIFIER` | 默认 `org.yipao.app`（主 App）、`org.yipao.app.widget`（小组件）、`org.yipao.app.tests`。Bundle ID 全局唯一，用自己的账号签名时多半要改成你自己的前缀。 |
| App Group | `LeapControl/LeapControl.entitlements`、`LeapWidget/LeapWidget.entitlements`、`LeapControl/Shared/VehicleSnapshot.swift` 里的 `SnapshotStore.appGroup` | 默认 `group.org.yipao.app`。三处必须一致，改 Bundle ID 时一起改。 |
| 钥匙串共享组 | 两份 entitlements 里的 `keychain-access-groups` | 默认 `$(AppIdentifierPrefix)org.yipao.app`，App 与小组件必须相同。 |

iOS 端用的是系统 MapKit，不需要地图 SDK key。

改完配置后重新执行一次 `xcodegen generate`。

## 编译与运行

```bash
xcodegen generate
open LeapControl.xcodeproj
```

在 Xcode 里选择 `LeapControl` scheme 和目标设备运行即可。命令行编译：

```bash
# 模拟器
xcodebuild -project LeapControl.xcodeproj -scheme LeapControl \
  -destination 'platform=iOS Simulator,name=iPhone 17' -jobs 4 build

# 真机（需要已填 Team ID，并在 Xcode → Settings → Accounts 登录 Apple ID）
xcodebuild -project LeapControl.xcodeproj -scheme LeapControl \
  -destination 'id=<设备 UDID>' -allowProvisioningUpdates build
```

首次装到真机后，可能需要在 iPhone 的「设置 → 通用 → VPN 与设备管理」里信任开发者证书。

### 本地预览（仅 Debug）

没有零跑账号时，可以用演示数据把界面跑起来：

```bash
xcrun simctl launch booted org.yipao.app -demo
```

再加 `-screen <名字>` 可以直接打开指定页面，例如 `climate`、`charge`、`map`、`settings`、`trips`、`tires`、`trunk`、`password`、`widget`、`widgetlarge`、`widgetlock`、`cabin`、`fridge`、`features`。

## 跑测试

```bash
xcodegen generate
xcodebuild -project LeapControl.xcodeproj -scheme LeapControl \
  -destination 'platform=iOS Simulator,name=iPhone 17' -jobs 4 test
```

说明：

- 测试用 Swift Testing 编写，部分用例会真实读写钥匙串和 App Group，**不要加 `CODE_SIGNING_ALLOWED=NO`**，否则这些用例会整片假失败。模拟器上不填 Team ID 也能跑（Xcode 会用 "Sign to Run Locally"）。
- `-jobs 4` 是为了限制并行编译，避免把 CPU 吃满导致模拟器不稳定，可按机器情况调整。
- 改动 `Core/Crypto.swift`、`Core/LeapClient.swift` 里的签名逻辑后务必跑测试：签名错误时服务端只会回一句笼统的校验失败，没有任何定位信息。

## 实现要点

- **两条鉴权链路**：老链路（`appuser.leapmotor.cn`）负责短信登录和远控下发，参数按 key 升序拼接后签名；新网关（`app-gw-global-master.leapmotor.com`）负责车辆列表、路由和车况，固定请求头 + 业务参数做 HMAC-SHA256。两条链路各自续期，缺一条都用不了。
- **充电记录接口**：按周／月查询 `charge/statistic/days`，按年查询 `charge/statistic/year`，明细使用 `charge/daily/detail/page`。请求复用网关会话和签名，并随账号、车辆切换取消旧页面的在途查询。
- **操作密码**：用老 token 派生 key / iv，AES-128-CBC 加密后随指令发送。生物识别只是取出本机已保存密码的钥匙，不能替代它。
- **车况字段**：车端 `signalMap` 的字段语义按车型分为两套口径，详见 `Core/SignalSchema.swift` 里的注释；读不到的车况一律不显示，不回退默认值。
- **蓝牙钥匙**：老款证书走 `keyType=0`（P-256 ECDH / SHA-256 / AES），新款国密证书走 `keyType=1`（SM2 KAP / SM3 / SM4）。
- **钥匙串分组必须带 Team ID 前缀**：entitlement 里是 `$(AppIdentifierPrefix)org.yipao.app`，真机上会展开成 `<TeamID>.org.yipao.app`；查询时只传不带前缀的名字会静默失败。`SessionStore` 里的 `KeychainSharing` 通过探测拿到真实前缀。

## 许可证

GPL-3.0。`Vendor/GmSSL` 下的第三方组件沿用各自的许可证（Apache-2.0 / MIT）。
