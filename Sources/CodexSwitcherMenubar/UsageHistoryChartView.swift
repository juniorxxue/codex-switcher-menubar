import Charts
import SwiftUI

struct UsageHistoryChartView: View {
    let points: [UsageHistoryPoint]

    @State private var selectedRange: UsageHistoryRange = .day1
    @State private var hoverDate: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $selectedRange) {
                ForEach(UsageHistoryRange.allCases) { range in
                    Text(range.rawValue).tag(range)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            let filteredPoints = UsageHistoryChartInterpolation.filteredPoints(
                points,
                for: selectedRange
            )

            if filteredPoints.isEmpty {
                Text("No history data yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 118, alignment: .center)
            } else {
                chartView(points: filteredPoints)
            }
        }
    }

    @ViewBuilder
    private func chartView(points: [UsageHistoryPoint]) -> some View {
        let interpolated = hoverDate.flatMap {
            UsageHistoryChartInterpolation.interpolateValues(at: $0, in: points)
        }

        Chart {
            ForEach(points) { point in
                LineMark(
                    x: .value("Time", point.timestamp),
                    y: .value("Usage", point.pct5h * 100)
                )
                .foregroundStyle(by: .value("Window", "5h"))
                .interpolationMethod(.catmullRom)
            }

            ForEach(points) { point in
                LineMark(
                    x: .value("Time", point.timestamp),
                    y: .value("Usage", point.pct7d * 100)
                )
                .foregroundStyle(by: .value("Window", "7d"))
                .interpolationMethod(.catmullRom)
            }

            if let interpolated {
                RuleMark(x: .value("Selected", interpolated.date))
                    .foregroundStyle(.secondary.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1))

                PointMark(
                    x: .value("Time", interpolated.date),
                    y: .value("Usage", interpolated.pct5h * 100)
                )
                .foregroundStyle(.blue)
                .symbolSize(24)

                PointMark(
                    x: .value("Time", interpolated.date),
                    y: .value("Usage", interpolated.pct7d * 100)
                )
                .foregroundStyle(.orange)
                .symbolSize(24)
            }
        }
        .chartXScale(domain: Date.now.addingTimeInterval(-selectedRange.interval)...Date.now)
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(values: [0, 25, 50, 75, 100]) { value in
                AxisValueLabel {
                    if let percent = value.as(Int.self) {
                        Text("\(percent)%")
                            .font(.caption2)
                    }
                }
                AxisGridLine()
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { value in
                AxisValueLabel(format: xAxisFormat)
                    .font(.caption2)
                AxisGridLine()
            }
        }
        .chartForegroundStyleScale([
            "5h": Color.blue,
            "7d": Color.orange
        ])
        .chartLegend(.visible)
        .chartPlotStyle { plot in
            plot.clipped()
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let plotFrame = proxy.plotFrame else {
                                return
                            }
                            let plotOrigin = geometry[plotFrame].origin
                            let xPosition = location.x - plotOrigin.x
                            if let date: Date = proxy.value(atX: xPosition) {
                                hoverDate = date
                            }
                        case .ended:
                            hoverDate = nil
                        }
                    }
            }
        }
        .overlay(alignment: .top) {
            if let interpolated {
                tooltipView(date: interpolated.date, pct5h: interpolated.pct5h, pct7d: interpolated.pct7d)
            }
        }
        .frame(height: 120)
        .padding(.top, 4)
    }

    @ViewBuilder
    private func tooltipView(date: Date, pct5h: Double, pct7d: Double) -> some View {
        VStack(spacing: 2) {
            Text(date, format: tooltipDateFormat)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Label("\(Int(round(pct5h * 100)))%", systemImage: "circle.fill")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.blue)

                Label("\(Int(round(pct7d * 100)))%", systemImage: "circle.fill")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
    }

    private var xAxisFormat: Date.FormatStyle {
        switch selectedRange {
        case .hour1:
            return .dateTime.hour().minute()
        case .hour6, .day1:
            return .dateTime.hour()
        case .day7:
            return .dateTime.weekday(.abbreviated)
        case .day30:
            return .dateTime.day().month(.abbreviated)
        }
    }

    private var tooltipDateFormat: Date.FormatStyle {
        switch selectedRange {
        case .hour1, .hour6, .day1:
            return .dateTime.hour().minute()
        case .day7:
            return .dateTime.weekday(.abbreviated).hour().minute()
        case .day30:
            return .dateTime.month(.abbreviated).day().hour()
        }
    }
}

private struct InterpolatedUsageValues {
    let date: Date
    let pct5h: Double
    let pct7d: Double
}

enum UsageHistoryChartInterpolation {
    static func filteredPoints(_ points: [UsageHistoryPoint], for range: UsageHistoryRange) -> [UsageHistoryPoint] {
        let now = Date()
        let rangeStart = now.addingTimeInterval(-range.interval)
        let rangePoints = points
            .filter { $0.timestamp >= rangeStart }
            .sorted { $0.timestamp < $1.timestamp }

        guard rangePoints.count > range.targetPointCount else {
            return rangePoints
        }

        let bucketCount = range.targetPointCount
        let bucketDuration = range.interval / Double(bucketCount)
        var buckets = [[UsageHistoryPoint]](repeating: [], count: bucketCount)

        for point in rangePoints {
            let offset = point.timestamp.timeIntervalSince(rangeStart)
            var bucketIndex = Int(offset / bucketDuration)
            if bucketIndex < 0 {
                bucketIndex = 0
            }
            if bucketIndex >= bucketCount {
                bucketIndex = bucketCount - 1
            }
            buckets[bucketIndex].append(point)
        }

        return buckets.compactMap { bucket in
            guard !bucket.isEmpty else {
                return nil
            }

            let averageTimestamp = bucket.map { $0.timestamp.timeIntervalSince1970 }.reduce(0, +) / Double(bucket.count)
            let average5h = bucket.map(\.pct5h).reduce(0, +) / Double(bucket.count)
            let average7d = bucket.map(\.pct7d).reduce(0, +) / Double(bucket.count)

            return UsageHistoryPoint(
                timestamp: Date(timeIntervalSince1970: averageTimestamp),
                pct5h: average5h,
                pct7d: average7d
            )
        }
    }

    fileprivate static func interpolateValues(at date: Date, in points: [UsageHistoryPoint]) -> InterpolatedUsageValues? {
        guard points.count >= 2 else {
            return nil
        }

        let sorted = points.sorted { $0.timestamp < $1.timestamp }
        guard date >= sorted.first!.timestamp,
              date <= sorted.last!.timestamp
        else {
            return nil
        }

        for index in 0..<(sorted.count - 1) where date >= sorted[index].timestamp && date <= sorted[index + 1].timestamp {
            let span = sorted[index + 1].timestamp.timeIntervalSince(sorted[index].timestamp)
            let t = span > 0 ? date.timeIntervalSince(sorted[index].timestamp) / span : 0

            let i0 = max(0, index - 1)
            let i3 = min(sorted.count - 1, index + 2)

            return InterpolatedUsageValues(
                date: date,
                pct5h: clamp(
                    catmullRom(
                        sorted[i0].pct5h,
                        sorted[index].pct5h,
                        sorted[index + 1].pct5h,
                        sorted[i3].pct5h,
                        t: t
                    )
                ),
                pct7d: clamp(
                    catmullRom(
                        sorted[i0].pct7d,
                        sorted[index].pct7d,
                        sorted[index + 1].pct7d,
                        sorted[i3].pct7d,
                        t: t
                    )
                )
            )
        }

        return nil
    }

    private static func catmullRom(_ p0: Double, _ p1: Double, _ p2: Double, _ p3: Double, t: Double) -> Double {
        let t2 = t * t
        let t3 = t2 * t

        return 0.5 * (
            (2 * p1) +
            (-p0 + p2) * t +
            (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 +
            (-p0 + 3 * p1 - 3 * p2 + p3) * t3
        )
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}
