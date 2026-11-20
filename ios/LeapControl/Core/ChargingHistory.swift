import Foundation

enum ChargingPeriod: String, CaseIterable, Sendable {
    case week = "周"
    case month = "月"
    case year = "年"

    var component: Calendar.Component {
        switch self {
        case .week: .weekOfYear
        case .month: .month
        case .year: .year
        }
    }

    var bucket: Calendar.Component { self == .year ? .month : .day }

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .gmt
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }

    func interval(containing date: Date) -> DateInterval {
        Self.calendar.dateInterval(of: component, for: date) ?? DateInterval(start: date, duration: 0)
    }

    static func apiDate(_ date: Date) -> String {
        date.formatted(
            Date.ISO8601FormatStyle(dateSeparator: .dash, timeZone: calendar.timeZone).year().month().day()
        )
    }
}

struct ChargingRecord: Identifiable, Sendable {
    let start: Date
    let end: Date?
    let energy: Double?
    let kind: Kind

    enum Kind: String, Sendable {
        case fast = "直流快充"
        case slow = "交流慢充"
        case unknown = "类型未知"

        init(code: String?) {
            switch code?.uppercased() {
            case "QUICK", "2": self = .fast
            case "SLOW", "1": self = .slow
            default: self = .unknown
            }
        }
    }

    var id: String {
        "\(start.timeIntervalSince1970)/\(kind.rawValue)"
    }

    var timeRangeText: String {
        let calendar = ChargingPeriod.calendar
        let locale = Locale(identifier: "en_US_POSIX")
        let dateTime = Date.VerbatimFormatStyle(
            format: "\(year: .defaultDigits).\(month: .twoDigits).\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
            locale: locale, timeZone: calendar.timeZone, calendar: calendar
        )
        let startText = start.formatted(dateTime)
        guard let end else { return startText }
        let time = Date.VerbatimFormatStyle(
            format: "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
            locale: locale, timeZone: calendar.timeZone, calendar: calendar
        )
        let endText = end.formatted(calendar.isDate(start, inSameDayAs: end) ? time : dateTime)
        return "\(startText)-\(endText)"
    }

    init?(raw: JSONValue) {
        guard let start = Self.timestamp(raw["chargeGunStartTs"]) ?? Self.timestamp(raw["chargeEarliestTs"]) else {
            return nil
        }
        self.start = start
        end = [raw["chargeGunEndTs"], raw["chargeLatestTs"]]
            .compactMap(Self.timestamp)
            .first { $0 >= start }
        energy = Self.unsigned(raw["chargeInEnergy"])
        kind = Kind(code: raw["chargeType"]?.stringValue)
    }

    private static func timestamp(_ value: JSONValue?) -> Date? {
        guard let milliseconds = unsigned(value), milliseconds > 0 else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1_000)
    }

    fileprivate static func unsigned(_ value: JSONValue?) -> Double? {
        guard let value, let string = value.stringValue,
              let number = Double(string), number.isFinite, number >= 0 else { return nil }
        return number
    }
}

struct ChargingRecordPage: Sendable {
    static let size = 50
    let records: [ChargingRecord]
    let hasMore: Bool

    init(data: JSONValue, page: Int) throws {
        let total = data["total"]?.stringValue.flatMap(Int.init)
        let list = data["list"] ?? data["records"]
        guard let items = list?.arrayValue ?? (list == .null && total == 0 ? [] : nil) else {
            throw LeapError.decode("缺少充电明细")
        }
        records = items.compactMap(ChargingRecord.init(raw:)).sorted { $0.start > $1.start }
        guard items.isEmpty || !records.isEmpty else { throw LeapError.decode("充电明细缺少时间") }
        hasMore = !items.isEmpty && (total.map { $0 > page * Self.size } ?? (items.count >= Self.size))
    }
}

struct ChargingSummary: Sendable {
    struct Bucket: Identifiable, Sendable {
        let date: Date
        let energy: Double
        var id: Date { date }
    }

    let count: Int?
    let energy: Double?
    let fastPercent: Double?
    let buckets: [Bucket]

    init(data: JSONValue, interval: DateInterval, period: ChargingPeriod) throws {
        guard data.objectValue != nil else { throw LeapError.decode("缺少充电统计") }
        count = data["totalChargeCounts"]?.stringValue.flatMap(Int.init).flatMap { $0 >= 0 ? $0 : nil }
        energy = ChargingRecord.unsigned(data["totalChargeInEnergy"])
        fastPercent = ChargingRecord.unsigned(data["fastChargePercent"]).flatMap { $0 <= 100 ? $0 : nil }

        var totals: [Date: Double] = [:]
        let formatter = DateFormatter()
        formatter.calendar = ChargingPeriod.calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = ChargingPeriod.calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        for row in data["chargeStatisList"]?.arrayValue ?? [] {
            guard let day = row["statisDay"]?.stringValue,
                  let date = formatter.date(from: String(day.prefix(10))),
                  interval.start <= date, date < interval.end,
                  let kWh = ChargingRecord.unsigned(row["chargeInEnergy"]) else { continue }
            totals[date, default: 0] += kWh
        }
        let calendar = ChargingPeriod.calendar
        var cursor = interval.start
        var buckets: [Bucket] = []
        while cursor < interval.end {
            buckets.append(Bucket(date: cursor, energy: totals[cursor] ?? 0))
            guard let next = calendar.date(byAdding: period.bucket, value: 1, to: cursor) else { break }
            cursor = next
        }
        self.buckets = buckets
    }
}

struct VehicleIdentity: Hashable, Sendable {
    let accountID: String
    let vin: String

    init?(session: LeapSession) {
        guard let accountID = session.oldAuth?.accountId, !accountID.isEmpty,
              !session.selectedVin.isEmpty else { return nil }
        self.accountID = accountID
        vin = session.selectedVin
    }
}
