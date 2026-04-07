import XCTest
@testable import CodexSwitcherMenubar

final class DebugLoggerTests: XCTestCase {
    func testDebugLoggingDisabledByDefault() {
        XCTAssertFalse(DebugLogger.isEnabled(in: [:]))
    }

    func testDebugLoggingAcceptsTruthyValues() {
        XCTAssertTrue(DebugLogger.isEnabled(in: ["CODEX_SWITCHER_MENUBAR_DEBUG": "1"]))
        XCTAssertTrue(DebugLogger.isEnabled(in: ["CODEX_SWITCHER_MENUBAR_DEBUG": "true"]))
        XCTAssertTrue(DebugLogger.isEnabled(in: ["CODEX_SWITCHER_MENUBAR_DEBUG": "YES"]))
        XCTAssertTrue(DebugLogger.isEnabled(in: ["CODEX_SWITCHER_MENUBAR_DEBUG": " on "]))
    }

    func testDebugLoggingRejectsFalseyValues() {
        XCTAssertFalse(DebugLogger.isEnabled(in: ["CODEX_SWITCHER_MENUBAR_DEBUG": "0"]))
        XCTAssertFalse(DebugLogger.isEnabled(in: ["CODEX_SWITCHER_MENUBAR_DEBUG": "false"]))
        XCTAssertFalse(DebugLogger.isEnabled(in: ["CODEX_SWITCHER_MENUBAR_DEBUG": ""]))
    }
}
