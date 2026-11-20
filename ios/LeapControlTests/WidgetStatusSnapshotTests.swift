import Foundation
import Testing
@testable import LeapControl

@Suite("只读小组件快照")
struct WidgetStatusSnapshotTests {
    @Test("钥匙串可读回、覆盖和清除独立的只读快照")
    func keychainStore() throws {
        let store = WidgetStatusStore(service: "org.yipao.app.tests.widget-status.\(UUID().uuidString)")
        defer { store.clear() }

        #expect(store.read() == nil)
        let initial = WidgetStatusSnapshot(soc: 78, rangeText: "电 180 · 油 420 km", chargeState: 0,
                                           updatedAt: Date(timeIntervalSince1970: 1_000))
        #expect(store.write(initial))
        #expect(store.read() == initial)

        let next = WidgetStatusSnapshot(soc: 79, rangeText: "电 182 · 油 420 km", chargeState: 1,
                                        updatedAt: initial.updatedAt.addingTimeInterval(10))
        #expect(store.write(next))
        #expect(store.read() == next)

        store.clear()
        #expect(store.read() == nil)
    }

    @Test("未变化的车况按分钟更新，数值或充电状态变化时立即发布")
    func publicationPolicy() {
        let date = Date(timeIntervalSince1970: 1_000)
        let previous = WidgetStatusSnapshot(soc: 78, rangeText: "312 km", chargeState: nil, updatedAt: date)

        #expect(previous.shouldPublish(after: nil))
        #expect(!previous.shouldPublish(after: previous))
        #expect(previous.chargeLabel == "充电状态未知")

        let heartbeat = WidgetStatusSnapshot(soc: 78, rangeText: "312 km", chargeState: nil,
                                             updatedAt: date.addingTimeInterval(60))
        #expect(heartbeat.shouldPublish(after: previous))

        let charging = WidgetStatusSnapshot(soc: 78, rangeText: "312 km", chargeState: 1,
                                             updatedAt: date.addingTimeInterval(1))
        #expect(charging.shouldPublish(after: previous))
        #expect(charging.chargeLabel == "充电中")
        #expect(!previous.shouldPublish(after: charging))
    }
}
