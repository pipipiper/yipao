import Foundation
import Testing
@testable import LeapControl

@Suite("充电记录")
struct ChargingHistoryTests {
    @Test("北京时间的周和年查询边界")
    func shanghaiCalendar() throws {
        let sundayInUTC = try #require(ISO8601DateFormatter().date(from: "2026-11-15T16:04:00Z"))
        let week = ChargingPeriod.week.interval(containing: sundayInUTC)
        #expect(ChargingPeriod.apiDate(week.start) == "2026-11-16")
        #expect(ChargingPeriod.apiDate(week.end) == "2026-11-23")
        let year = ChargingPeriod.year.interval(containing: sundayInUTC)
        #expect(ChargingPeriod.apiDate(year.start) == "2026-01-01")
        #expect(ChargingPeriod.apiDate(year.end) == "2027-01-01")
    }

    @Test("统计按接口口径显示，并补齐无数据的月份")
    func yearlySummary() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-11-20T12:00:00Z"))
        let raw = try decode("""
        {
          "totalChargeCounts": "2",
          "totalChargeInEnergy": 42.1,
          "fastChargePercent": "50",
          "chargeStatisList": [
            {"statisDay": "2026-01-01 00:00:00", "chargeInEnergy": "20.1"},
            {"statisDay": "2026-11-01 00:00:00", "chargeInEnergy": 22}
          ]
        }
        """)
        let result = try ChargingSummary(data: raw, interval: ChargingPeriod.year.interval(containing: now), period: .year)
        #expect(result.count == 2)
        #expect(result.energy == 42.1)
        #expect(result.fastPercent == 50)
        #expect(result.buckets.count == 12)
        #expect(result.buckets.map(\.energy).prefix(2).elementsEqual([20.1, 0]))
        #expect(result.buckets.first { ChargingPeriod.apiDate($0.date) == "2026-11-01" }?.energy == 22)
    }

    @Test("分页使用服务端总数，保留未知类型与缺失电量")
    func recordPage() throws {
        let raw = try decode("""
        {
          "total": "51",
          "list": [
            {"chargeGunStartTs": "0", "chargeEarliestTs": "1795172400000",
             "chargeGunEndTs": -1, "chargeLatestTs": 1795176000000, "chargeType": "QUICK",
             "chargeInEnergy": "12.5"},
            {"chargeGunStartTs": 1795076000000, "chargeType": "other"}
          ]
        }
        """)
        let first = try ChargingRecordPage(data: raw, page: 1)
        let last = try ChargingRecordPage(data: raw, page: 2)
        #expect(first.hasMore)
        #expect(!last.hasMore)
        #expect(first.records.map(\.kind) == [.fast, .unknown])
        let firstRecord = try #require(first.records.first)
        #expect(firstRecord.end?.timeIntervalSince(firstRecord.start) == 3_600)
        #expect(firstRecord.energy == 12.5)
        #expect(first.records.last?.energy == nil)
    }

    @Test("空记录与解析失败可区分")
    func emptyAndInvalidPages() throws {
        let empty = try ChargingRecordPage(data: decode(#"{"total":0,"list":[]}"#), page: 1)
        #expect(empty.records.isEmpty)
        #expect(!empty.hasMore)
        let nullList = try ChargingRecordPage(data: decode(#"{"total":0,"list":null}"#), page: 1)
        #expect(nullList.records.isEmpty)
        #expect(throws: LeapError.self) {
            try ChargingRecordPage(data: decode(#"{"list":[{"chargeType":"SLOW"}]}"#), page: 1)
        }
    }

    @Test("明细合并开始与结束时间，北京时间跨天时保留两边日期")
    func timeRangeText() throws {
        let formatter = ISO8601DateFormatter()
        let start = try #require(formatter.date(from: "2026-11-19T13:43:00Z"))
        let sameDayEnd = try #require(formatter.date(from: "2026-11-19T14:15:00Z"))
        let nextDayEnd = try #require(formatter.date(from: "2026-11-20T14:15:00Z"))
        func record(ending end: Date?) throws -> ChargingRecord {
            try #require(ChargingRecord(raw: .object([
                "chargeGunStartTs": .number(start.timeIntervalSince1970 * 1_000),
                "chargeGunEndTs": end.map { .number($0.timeIntervalSince1970 * 1_000) } ?? .null
            ])))
        }
        #expect(try record(ending: sameDayEnd).timeRangeText == "2026.11.19 21:43-22:15")
        #expect(try record(ending: nextDayEnd).timeRangeText == "2026.11.19 21:43-2026.11.20 22:15")
        #expect(try record(ending: nil).timeRangeText == "2026.11.19 21:43")
    }

    private func decode(_ json: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }
}
