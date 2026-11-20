import Charts
import SwiftUI

struct ChargingHistoryView: View {
    var body: some View {
        ScrollView {
            ChargingHistorySection()
                .padding(16)
                .padding(.bottom, 8)
        }
        .scrollIndicators(.hidden)
        .background { LeapBackground(tint: LeapStyle.cool) }
        .navigationTitle("充电记录")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
    }
}

struct ChargingHistorySection: View {
    @Environment(VehicleStore.self) private var store
    var embedded = false

    var body: some View {
        if let vehicle = VehicleIdentity(session: store.session) {
            ChargingHistoryContent(vehicle: vehicle, embedded: embedded)
                .id(vehicle)
        } else {
            ContentUnavailableView("请先选择车辆", systemImage: "car")
        }
    }
}

private struct ChargingHistoryContent: View {
    let vehicle: VehicleIdentity
    let embedded: Bool

    @Environment(VehicleStore.self) private var store
    @State private var period = ChargingPeriod.week
    @State private var offset = 0
    @State private var selectedDate: Date?
    @State private var refreshID = UUID()
    @State private var summary: ChargingSummary?
    @State private var summaryError: String?
    @State private var records: [ChargingRecord] = []
    @State private var detailError: String?
    @State private var hasMore = false
    @State private var loadedPage = 0
    @State private var isLoadingRecords = false
    @State private var moreTask: Task<Void, Never>?

    private struct Query: Equatable {
        let period: ChargingPeriod
        let interval: DateInterval
        let refreshID: UUID
    }

    private var calendar: Calendar { ChargingPeriod.calendar }

    private var summaryQuery: Query {
        let current = period.interval(containing: .now)
        let anchor = calendar.date(byAdding: period.component, value: offset, to: current.start) ?? current.start
        return Query(period: period, interval: period.interval(containing: anchor), refreshID: refreshID)
    }

    private var detailQuery: Query {
        let query = summaryQuery
        guard let selectedDate, selectedDate >= query.interval.start, selectedDate < query.interval.end,
              let bucket = calendar.dateInterval(of: period.bucket, for: selectedDate) else { return query }
        return Query(period: period, interval: bucket, refreshID: refreshID)
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            if embedded || store.isDemo {
                HStack {
                    if embedded {
                        Text("充电记录")
                            .font(.title3.weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                    }
                    if store.isDemo {
                        Text("演示数据")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if embedded { refreshButton }
                }
            }
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    controls
                    Divider()
                    summaryContent
                }
            }

            HStack {
                Text(detailQuery.interval == summaryQuery.interval ? "全部明细" : intervalTitle(detailQuery))
                    .font(.subheadline.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if selectedDate != nil {
                    Button("显示全部") { selectedDate = nil }
                }
            }
            .padding(.horizontal, 4)

            detailContent
            Text("日期按北京时间显示")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        }
        .toolbar {
            if !embedded {
                ToolbarItem(placement: .topBarTrailing) { refreshButton }
            }
        }
        .task(id: summaryQuery) { [query = summaryQuery] in await loadSummary(query) }
        .task(id: detailQuery) { [query = detailQuery] in await loadFirstPage(query) }
        .onDisappear { moreTask?.cancel() }
    }

    private var refreshButton: some View {
        Button {
            refreshID = UUID()
        } label: {
            Image(systemName: "arrow.clockwise")
                .frame(minWidth: 36, minHeight: 36)
        }
        .accessibilityLabel("刷新充电记录")
    }

    private var controls: some View {
        VStack(spacing: 12) {
            Picker("统计周期", selection: $period) {
                ForEach(ChargingPeriod.allCases, id: \.self) { period in
                    Text(period.rawValue).tag(period)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: period) {
                selectedDate = nil
                offset = 0
            }

            HStack {
                periodButton("上一期", symbol: "chevron.left", step: -1)
                Spacer()
                Text(intervalTitle(summaryQuery))
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.center)
                Spacer()
                periodButton("下一期", symbol: "chevron.right", step: 1)
                    .disabled(offset == 0)
            }
            .buttonStyle(.borderless)
        }
    }

    private func periodButton(_ title: String, symbol: String, step: Int) -> some View {
        Button {
            selectedDate = nil
            offset += step
        } label: {
            Image(systemName: symbol)
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel(title)
    }

    @ViewBuilder
    private var summaryContent: some View {
        if let summary {
            LabeledContent("充电次数", value: summary.count.map { "\($0) 次" } ?? "—")
            LabeledContent("充入电量", value: summary.energy.map { "\(number($0)) kWh" } ?? "—")
            LabeledContent("快充占比", value: summary.fastPercent.map { "\(number($0))%" } ?? "—")
            if summary.buckets.contains(where: { $0.energy > 0 }) {
                Chart(summary.buckets) { bucket in
                    BarMark(
                        x: .value("日期", bucket.date, unit: period.bucket, calendar: calendar),
                        y: .value("充入电量（kWh）", bucket.energy)
                    )
                    .foregroundStyle(LeapStyle.accent.opacity(isSelected(bucket.date) ? 1 : 0.4))
                    .accessibilityLabel(bucket.date.formatted(dateStyle))
                    .accessibilityValue("\(number(bucket.energy)) kWh")
                }
                .environment(\.calendar, calendar)
                .environment(\.timeZone, calendar.timeZone)
                .chartXSelection(value: $selectedDate)
                .frame(height: 155)
            }
        } else if let summaryError {
            Label(summaryError, systemImage: "exclamationmark.circle")
        } else {
            ProgressView("正在读取充电统计")
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        ForEach(records) { record in
            GlassCard(radius: LeapStyle.tileRadius) {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent {
                        Text(record.energy.map { "\(number($0)) kWh" } ?? "—")
                            .monospacedDigit()
                    } label: {
                        Label {
                            Text(record.kind.rawValue)
                        } icon: {
                            Image(systemName: chargeSymbol(record.kind))
                                .foregroundStyle(chargeTint(record.kind))
                        }
                    }
                    Text(record.timeRangeText)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
        if let detailError {
            Label(detailError, systemImage: "exclamationmark.circle")
        } else if !isLoadingRecords && records.isEmpty && loadedPage > 0 {
            ContentUnavailableView("暂无充电记录", systemImage: "bolt.slash")
        }
        if isLoadingRecords || (loadedPage == 0 && detailError == nil) {
            ProgressView("正在读取充电明细")
        } else if hasMore {
            Button(detailError == nil ? "加载更多" : "重试加载更多") {
                let query = detailQuery
                moreTask = Task { await loadPage(query, page: loadedPage + 1) }
            }
        } else if loadedPage == 0 && detailError != nil {
            Button("重试") { refreshID = UUID() }
        }
    }

    private func chargeSymbol(_ kind: ChargingRecord.Kind) -> String {
        switch kind {
        case .fast: "bolt.fill"
        case .slow: "powerplug.fill"
        case .unknown: "questionmark.circle"
        }
    }

    private func chargeTint(_ kind: ChargingRecord.Kind) -> Color {
        switch kind {
        case .fast: LeapStyle.accent
        case .slow: LeapStyle.cool
        case .unknown: .secondary
        }
    }

    private var dateStyle: Date.FormatStyle {
        dateFormat.year().month().day()
    }

    private var dateFormat: Date.FormatStyle {
        .init(locale: Locale(identifier: "zh_CN"), calendar: calendar, timeZone: calendar.timeZone)
    }

    private func intervalTitle(_ query: Query) -> String {
        let start = query.interval.start
        if query.interval.duration == calendar.dateInterval(of: .year, for: start)?.duration {
            return start.formatted(dateFormat.year())
        }
        if query.interval.duration == calendar.dateInterval(of: .month, for: start)?.duration {
            return start.formatted(dateFormat.year().month())
        }
        if query.interval.duration == calendar.dateInterval(of: .day, for: start)?.duration {
            return start.formatted(dateStyle)
        }
        let end = query.interval.end.addingTimeInterval(-1)
        let endStyle = calendar.isDate(start, equalTo: end, toGranularity: .year)
            ? dateFormat.month().day() : dateStyle
        return "\(start.formatted(dateStyle)) – \(end.formatted(endStyle))"
    }

    private func isSelected(_ date: Date) -> Bool {
        selectedDate == nil || date == detailQuery.interval.start
    }

    private func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }

    private func loadSummary(_ query: Query) async {
        guard !Task.isCancelled, query == summaryQuery else { return }
        summary = nil
        summaryError = nil
        do {
            let result = try await store.loadChargingSummary(vehicle: vehicle, period: query.period,
                                                               interval: query.interval)
            guard !Task.isCancelled, query == summaryQuery else { return }
            summary = result
        } catch {
            guard !Task.isCancelled, query == summaryQuery else { return }
            summaryError = "充电统计加载失败。\(error.localizedDescription)"
        }
    }

    private func loadFirstPage(_ query: Query) async {
        guard !Task.isCancelled, query == detailQuery else { return }
        moreTask?.cancel()
        records = []
        hasMore = false
        loadedPage = 0
        isLoadingRecords = false
        await loadPage(query, page: 1)
    }

    private func loadPage(_ query: Query, page: Int) async {
        guard !Task.isCancelled, !isLoadingRecords, query == detailQuery else { return }
        isLoadingRecords = true
        detailError = nil
        do {
            let result = try await store.loadChargingRecordPage(vehicle: vehicle, interval: query.interval, page: page)
            guard !Task.isCancelled, query == detailQuery else { return }
            var seen = Set(records.map(\.id))
            records.append(contentsOf: result.records.filter { seen.insert($0.id).inserted })
            hasMore = result.hasMore
            loadedPage = page
        } catch {
            guard !Task.isCancelled, query == detailQuery else { return }
            detailError = "充电明细加载失败。\(error.localizedDescription)"
        }
        isLoadingRecords = false
    }
}
