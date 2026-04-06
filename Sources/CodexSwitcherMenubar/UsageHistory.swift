import Foundation

struct UsageHistoryPoint: Codable, Identifiable, Equatable {
    var id = UUID()
    var timestamp: Date
    var pct5h: Double
    var pct7d: Double

    init(timestamp: Date = Date(), pct5h: Double, pct7d: Double) {
        self.timestamp = timestamp
        self.pct5h = pct5h
        self.pct7d = pct7d
    }
}

struct PersistedUsageHistory: Codable {
    var pointsByAccount: [String: [UsageHistoryPoint]] = [:]
}

enum UsageHistoryRange: String, CaseIterable, Identifiable {
    case hour1 = "1h"
    case hour6 = "6h"
    case day1 = "1d"
    case day7 = "7d"
    case day30 = "30d"

    var id: String { rawValue }

    var interval: TimeInterval {
        switch self {
        case .hour1:
            return 3600
        case .hour6:
            return 6 * 3600
        case .day1:
            return 24 * 3600
        case .day7:
            return 7 * 24 * 3600
        case .day30:
            return 30 * 24 * 3600
        }
    }

    var targetPointCount: Int {
        switch self {
        case .hour1:
            return 120
        case .hour6:
            return 180
        case .day1, .day7, .day30:
            return 200
        }
    }
}

enum UsageHistoryStore {
    private static let retentionInterval: TimeInterval = 30 * 24 * 3600
    private static let mergeInterval: TimeInterval = 60

    static func load() throws -> [UUID: [UsageHistoryPoint]] {
        let fileURL = AppPaths.usageHistoryFile
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return [:]
        }

        let data = try Data(contentsOf: fileURL)
        let persisted = try JSONCoding.decoder().decode(PersistedUsageHistory.self, from: data)

        var historyByAccount: [UUID: [UsageHistoryPoint]] = [:]
        for (rawAccountID, points) in persisted.pointsByAccount {
            guard let accountID = UUID(uuidString: rawAccountID) else {
                continue
            }
            historyByAccount[accountID] = pruned(points)
        }

        return historyByAccount
    }

    static func save(_ historyByAccount: [UUID: [UsageHistoryPoint]]) throws {
        let persisted = PersistedUsageHistory(
            pointsByAccount: Dictionary(uniqueKeysWithValues: historyByAccount.map { accountID, points in
                (accountID.uuidString, pruned(points))
            })
        )

        let data = try JSONCoding.encoder().encode(persisted)
        try AppPaths.ensureParentDirectory(for: AppPaths.usageHistoryFile)
        try data.write(to: AppPaths.usageHistoryFile, options: [.atomic])
        try LocalStore.setRestrictedPermissions(AppPaths.usageHistoryFile)
    }

    static func record(
        usage: UsageInfo,
        for accountID: UUID,
        historyByAccount: [UUID: [UsageHistoryPoint]]
    ) -> [UUID: [UsageHistoryPoint]] {
        guard let pct5h = usage.primaryFraction,
              let pct7d = usage.secondaryFraction
        else {
            return historyByAccount
        }

        var nextHistory = historyByAccount
        var points = nextHistory[accountID] ?? []
        let point = UsageHistoryPoint(
            timestamp: usage.lastUpdatedAt,
            pct5h: pct5h,
            pct7d: pct7d
        )

        if let lastPoint = points.last,
           point.timestamp.timeIntervalSince(lastPoint.timestamp) < mergeInterval
        {
            points[points.count - 1] = point
        } else {
            points.append(point)
        }

        nextHistory[accountID] = pruned(points)
        return nextHistory
    }

    static func downsampledPoints(
        for accountID: UUID,
        range: UsageHistoryRange,
        historyByAccount: [UUID: [UsageHistoryPoint]]
    ) -> [UsageHistoryPoint] {
        let now = Date()
        let rangeStart = now.addingTimeInterval(-range.interval)
        let points = (historyByAccount[accountID] ?? [])
            .filter { $0.timestamp >= rangeStart }
            .sorted { $0.timestamp < $1.timestamp }

        guard points.count > range.targetPointCount else {
            return points
        }

        let bucketCount = range.targetPointCount
        let bucketDuration = range.interval / Double(bucketCount)
        var buckets = [[UsageHistoryPoint]](repeating: [], count: bucketCount)

        for point in points {
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

    private static func pruned(_ points: [UsageHistoryPoint]) -> [UsageHistoryPoint] {
        let cutoff = Date().addingTimeInterval(-retentionInterval)
        return points.filter { $0.timestamp >= cutoff }
    }
}
