import AppIntents
import SwiftUI
import WidgetKit

@main
struct LeapWidgetBundle: WidgetBundle {
    var body: some Widget {
        VehicleWidget()
        VehicleLockWidget()
        VehicleLockOnlyWidget()
        VehicleUnlockWidget()
        // 锁屏**底部**那两个圆按钮位 / 控制中心 / 侧边操作按钮上的控件。
        //
        // `WidgetBundleBuilder` 没有 `buildOptional`，包一层 `if` 会让编译器崩在
        // "failed to produce diagnostic for expression"，所以一律注册。
        VehicleLockControl()
        VehicleLockOnlyControl()
        VehicleUnlockControl()
        VehicleHornControl()
        // 控车过程那条灵动岛。它只在扩展进程真的能直接下发时才会被起起来
        // （见 `ControlActivitySession.begin`）。
        ControlActivityWidget()
    }
}

// MARK: - 时间线

struct VehicleEntry: TimelineEntry {
    var date: Date
    var snapshot: VehicleSnapshot
    /// 官方图层叠出来的车图，主 App 每次叠完写进 App Group。大卡和锁车卡的主视觉都用它。
    var carImage: Image?
    var readOnlyStatus: WidgetStatusSnapshot?
}

/// WidgetKit 的 completion 不是 Sendable，直接捕进 Task 会被并发检查拦下。
/// WidgetKit 保证只调一次，包一层就够了。
private final class TimelineSink: @unchecked Sendable {
    private let completion: (Timeline<VehicleEntry>) -> Void
    init(_ completion: @escaping (Timeline<VehicleEntry>) -> Void) { self.completion = completion }
    func finish(_ timeline: Timeline<VehicleEntry>) { completion(timeline) }
}

struct VehicleProvider: TimelineProvider {
    private var store: SnapshotStore { SnapshotStore() }

    /// 卡片自己拉车况的间隔。注意这只是"请求"——系统按刷新预算决定真正给不给，
    /// 电量低或用户很少看这个卡片时会被拉长到远超 10 分钟。
    static let refreshInterval: TimeInterval = 600

    func placeholder(in context: Context) -> VehicleEntry {
        VehicleEntry(date: .now, snapshot: .placeholder, readOnlyStatus: .preview)
    }

    private func readOnlyEntry(preview: Bool = false) -> VehicleEntry {
        let status: WidgetStatusSnapshot? = WidgetStatusStore().read() ?? (preview ? .preview : nil)
        return VehicleEntry(date: .now, snapshot: .placeholder, readOnlyStatus: status)
    }

    func getSnapshot(in context: Context, completion: @escaping (VehicleEntry) -> Void) {
        guard SnapshotStore.hasSharedContainer else {
            completion(readOnlyEntry(preview: context.isPreview))
            return
        }
        completion(VehicleEntry(
            date: .now,
            snapshot: store.read() ?? .placeholder,
            carImage: Self.carImage()
        ))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<VehicleEntry>) -> Void) {
        guard SnapshotStore.hasSharedContainer else {
            let entry = readOnlyEntry()
            completion(Timeline(entries: [entry], policy: .after(entry.date.addingTimeInterval(Self.refreshInterval))))
            return
        }
        let sink = TimelineSink(completion)
        let cached = store.read()

        Task {
            // 整条时间线必须在系统给的预算内交出去。拉车况最坏要走「续期 token → 取路由 →
            // 查车况」三个请求，任何一个卡住都会超预算——WidgetKit 会直接干掉扩展进程，
            // 桌面上继续显示上一次渲染的画面，看起来就像新版本没生效。
            // 所以这里压一个硬超时，超了就用上一份快照先把卡片画出来。
            let snapshot = await WidgetTimeout.within(
                seconds: 12,
                fallback: cached ?? .placeholder
            ) {
                await WidgetVehicleFetcher.latest(fallback: cached)
            }
            // 车图是本地文件，读它不用压超时。
            let car: Image? = Self.carImage()

            // 中途再插一个条目，好让"多久前"这句话在两次刷新之间也会变。
            let entries = [0.0, Self.refreshInterval / 2].map { offset in
                VehicleEntry(
                    date: Date.now.addingTimeInterval(offset),
                    snapshot: snapshot,
                    carImage: car
                )
            }
            // 拉到了新车况，顺手把锁屏 / 控制中心那几个控件也叫醒。
            //
            // 它们读的是同一份共享快照，但没有时间线，不叫就不会重取。理由和这个动作
            // 会不会白做，都写在 `LeapWidgets.reloadControlsOnly` 上。
            //
            // 只在真拉到新数据时叫：两条时间线（状态卡、锁车卡）由系统分别派发，
            // 后跑的那条会复用共享快照、`updatedAt` 原样不动，没必要再叫一次。
            if snapshot.updatedAt != cached?.updatedAt {
                LeapWidgets.reloadControlsOnly()
            }

            let next = Date.now.addingTimeInterval(Self.refreshInterval)
            sink.finish(Timeline(entries: entries, policy: .after(next)))
        }
    }

    /// 主 App 叠好后写进 App Group 的那张车图。没有就返回 nil，卡片退回剪影。
    private static func carImage() -> Image? {
        CarImageCache.shared().map { Image(uiImage: $0) }
    }
}

// MARK: - 卡片

struct VehicleWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SnapshotStore.widgetKind, provider: VehicleProvider()) { entry in
            Group {
                if SnapshotStore.hasSharedContainer {
                    VehicleWidgetView(snapshot: entry.snapshot, carImage: entry.carImage)
                } else {
                    ReadOnlyVehicleWidgetView(status: entry.readOnlyStatus)
                }
            }
            .containerBackground(.fill.tertiary, for: .widget)
        }
        // 关掉系统默认边距，改由 VehicleWidgetView 自己控制。
        // 桌面上的默认边距实测只有 3pt 左右，和添加卡片时的预览也对不上。
        .contentMarginsDisabled()
        .configurationDisplayName("车辆状态")
        .description(SnapshotStore.hasSharedContainer
                     ? "查看电量、续航和车辆锁定状态。"
                     : "查看电量、续航、充电状态和最近更新时间。")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .systemLarge,
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline
        ])
    }
}

// MARK: - 单功能锁车卡片

/// 只管锁车的小卡片，桌面上独立的一张——库里直接挑得到，不用先加卡再长按选样式。
///
/// 它和「车辆状态」是两个 kind，也就是两条时间线。两条线各拉各的车况会让同一时刻
/// 两张卡显示不同的瞬间（真出过），所以拉取那一步加了复用窗口：先跑的那条拉网络并
/// 写回共享快照，后跑的那条直接复用——见 `WidgetVehicleFetcher.reuseWindow`。
private struct VehicleLockCard: View {
    let entry: VehicleEntry
    var action: WidgetAction = .toggleLock

    var body: some View {
        if SnapshotStore.hasSharedContainer {
            LockWidgetView(snapshot: entry.snapshot, carImage: entry.carImage, action: action)
                .containerBackground(for: .widget) { LockWidgetBackground(snapshot: entry.snapshot) }
        } else {
            ReadOnlyVehicleWidgetView(status: entry.readOnlyStatus)
                .containerBackground(.fill.tertiary, for: .widget)
        }
    }
}

struct VehicleLockWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: SnapshotStore.lockWidgetKind,
            provider: VehicleProvider()
        ) { entry in
            VehicleLockCard(entry: entry)
        }
        .contentMarginsDisabled()
        .configurationDisplayName("车锁")
        .description(SnapshotStore.hasSharedContainer
                     ? "车辆模型与锁车状态，点击卡片执行标题所示操作。"
                     : "本签名版本显示只读车况，点击打开壹跑。")
        .supportedFamilies([.systemSmall])
    }
}

struct VehicleLockOnlyWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SnapshotStore.lockOnlyWidgetKind, provider: VehicleProvider()) { entry in
            VehicleLockCard(entry: entry, action: .lock)
        }
        .contentMarginsDisabled()
        .configurationDisplayName("上锁车辆")
        .description(SnapshotStore.hasSharedContainer
                     ? "车辆模型与锁车状态，点击卡片上锁车辆。"
                     : "本签名版本显示只读车况，点击打开壹跑。")
        .supportedFamilies([.systemSmall])
    }
}

struct VehicleUnlockWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SnapshotStore.unlockWidgetKind, provider: VehicleProvider()) { entry in
            VehicleLockCard(entry: entry, action: .unlock)
        }
        .contentMarginsDisabled()
        .configurationDisplayName("解锁车辆")
        .description(SnapshotStore.hasSharedContainer
                     ? "车辆模型与锁车状态，点击卡片解锁车辆。"
                     : "本签名版本显示只读车况，点击打开壹跑。")
        .supportedFamilies([.systemSmall])
    }
}

#Preview("小尺寸", as: .systemSmall) {
    VehicleWidget()
} timeline: {
    VehicleEntry(date: .now, snapshot: .placeholder)
}

#Preview("单功能锁车卡片", as: .systemSmall) {
    VehicleLockWidget()
} timeline: {
    VehicleEntry(date: .now, snapshot: .placeholder)
}

#Preview("中尺寸", as: .systemMedium) {
    VehicleWidget()
} timeline: {
    VehicleEntry(date: .now, snapshot: .placeholder)
}
