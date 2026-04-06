import XCTest
@testable import CodexSwitcherMenubar

final class UsageRefreshPolicyTests: XCTestCase {
    func testShouldRefreshWhenUsageIsMissing() {
        XCTAssertTrue(
            UsageRefreshPolicy.shouldRefresh(
                usage: nil,
                now: Date(timeIntervalSince1970: 1_700_000_120),
                maxAge: 120
            )
        )
    }

    func testShouldRefreshWhenUsageIsOlderThanMaximumAge() {
        let lastUpdatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let usage = UsageInfo(
            accountID: UUID(uuidString: "FE3B5908-4986-4178-9D47-5D72CE723C65")!,
            planType: "plus",
            primaryUsedPercent: 42,
            primaryWindowMinutes: 300,
            primaryResetsAt: nil,
            secondaryUsedPercent: 18,
            secondaryWindowMinutes: 10_080,
            secondaryResetsAt: nil,
            hasCredits: nil,
            unlimitedCredits: nil,
            creditsBalance: nil,
            error: nil,
            lastUpdatedAt: lastUpdatedAt
        )

        XCTAssertFalse(
            UsageRefreshPolicy.shouldRefresh(
                usage: usage,
                now: Date(timeIntervalSince1970: 1_700_000_119),
                maxAge: 120
            )
        )
        XCTAssertTrue(
            UsageRefreshPolicy.shouldRefresh(
                usage: usage,
                now: Date(timeIntervalSince1970: 1_700_000_120),
                maxAge: 120
            )
        )
    }

    func testBackgroundMaximumStalenessDependsOnCodexActivity() {
        XCTAssertEqual(
            UsageRefreshPolicy.maximumBackgroundStaleness(isCodexRunning: true),
            UsageRefreshPolicy.activeUsageMaximumStalenessWhileCodexRunning
        )
        XCTAssertEqual(
            UsageRefreshPolicy.maximumBackgroundStaleness(isCodexRunning: false),
            UsageRefreshPolicy.activeUsageMaximumStalenessWhileIdle
        )
    }
}
