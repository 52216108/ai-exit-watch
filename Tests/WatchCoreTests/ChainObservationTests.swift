import XCTest
@testable import WatchCore

final class ChainObservationTests: XCTestCase {
    private static let web = #"{"metadata":{"host":"claude.ai"},"chains":["出口","策略组"]}"#
    private static let api = #"{"metadata":{"host":"api.anthropic.com"},"chains":["出口","策略组"]}"#

    func testCapturesConnectionEstablishedAfterOldSamplingWindow() async {
        let start = ContinuousClock.now
        let result = await ChainReader.observe { endpoint in
            if endpoint == "proxies" { return Data(#"{"proxies":{}}"#.utf8) }
            // 两条连接不同时存在；API 建立时原来的 0.8 秒观察已结束。
            let connection = start.duration(to: .now) < .milliseconds(900) ? Self.web : Self.api
            return Data("{\"connections\":[\(connection)]}".utf8)
        }
        XCTAssertNil(result.error)
        XCTAssertEqual(result.chains?.count, 2)
        XCTAssertLessThan(start.duration(to: .now), .seconds(5))
    }

    func testIncompleteCaptureStaysUnknownAndDoesNotCarryOver() async {
        let complete = await ChainReader.observe { endpoint in
            if endpoint == "proxies" { return Data(#"{"proxies":{}}"#.utf8) }
            return Data("{\"connections\":[\(Self.web),\(Self.api)]}".utf8)
        }
        XCTAssertNotNil(complete.chains)
        let incomplete = await ChainReader.observe(timeout: .milliseconds(40), pollingInterval: .milliseconds(10)) { _ in
            Data("{\"connections\":[\(Self.web)]}".utf8)
        }
        XCTAssertNil(incomplete.chains)
        XCTAssertNotNil(incomplete.error)
    }

    func testReadFailureDoesNotLookLikeHealthyChain() async {
        let result = await ChainReader.observe { _ in throw ProbeFailure.invalid("查询失败") }
        XCTAssertNil(result.chains)
        XCTAssertNotNil(result.error)
    }

    func testCancelledObservationStopsWithoutWaitingForTimeout() async {
        let observation = Task {
            await ChainReader.observe { _ in Data(#"{"connections":[]}"#.utf8) }
        }
        observation.cancel()
        let result = await observation.value
        XCTAssertNil(result.chains)
        XCTAssertEqual(result.error, "检测已取消")
    }
}
