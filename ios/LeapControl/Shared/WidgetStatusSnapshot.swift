import Foundation
import Security

/// 无共享容器时，主 App 写入的只读车况。
struct WidgetStatusSnapshot: Codable, Equatable, Sendable {
    let soc: Int?
    let rangeText: String?
    let chargeState: Int?
    let updatedAt: Date

    static let preview = Self(soc: 76, rangeText: "312 km", chargeState: 1, updatedAt: .now)

    var chargeLabel: String {
        switch chargeState {
        case 0: "未在充电"
        case 1: "充电中"
        case 2: "充电已结束"
        case 3: "充电故障"
        case 4: "等待预约"
        case 6: "充电暂停"
        default: "充电状态未知"
        }
    }

    /// 状态变化立即写入。相同车况每分钟更新一次拉取时间。
    func shouldPublish(after previous: Self?) -> Bool {
        guard let previous else { return true }
        guard updatedAt >= previous.updatedAt else { return false }
        return soc != previous.soc || rangeText != previous.rangeText || chargeState != previous.chargeState
            || updatedAt.timeIntervalSince(previous.updatedAt) >= 60
    }
}

struct WidgetStatusStore: Sendable {
    var service = "org.yipao.app.widget-status"

    private var query: [String: Any] {
        var attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "latest"
        ]
        KeychainSharing.apply(to: &attributes)
        return attributes
    }

    func read() -> WidgetStatusSnapshot? {
        var attributes = query
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(attributes as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(WidgetStatusSnapshot.self, from: data)
    }

    func write(_ snapshot: WidgetStatusSnapshot) -> Bool {
        guard let data = try? JSONEncoder().encode(snapshot) else { return false }
        let query = query
        let values: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            return SecItemAdd(query.merging(values) { current, _ in current } as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    func clear() {
        SecItemDelete(query as CFDictionary)
    }
}
