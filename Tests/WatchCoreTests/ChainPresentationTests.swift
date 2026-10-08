import XCTest
@testable import WatchCore

final class ChainPresentationTests: XCTestCase {
    func testShowsPhysicalNodesInForwardOrderWithRoles() {
        let proxies: [String: ProxyRouteInfo] = [
            "落地": .init(type: "Socks5", dialerProxy: "前置选择"),
            "前置选择": .init(type: "Selector", now: "美国节点"),
            "美国节点": .init(type: "Hysteria2", dialerProxy: ""),
            "分流组": .init(type: "Selector", now: "落地")
        ]
        XCTAssertEqual(
            ChainPresentation.describe("claude.ai: 落地 → 分流组", proxies: proxies),
            "本机 → 前置节点：美国节点 → 落地节点：落地 → Claude 网页（claude.ai）"
        )
    }

    func testMissingProxyDetailsAreUnknownInsteadOfNoFrontProxy() {
        let raw = "api.anthropic.com: 落地 → 分流组"
        XCTAssertEqual(ChainPresentation.describe(raw, proxies: nil),
                       "本机 → 前置节点：未获取 → 落地节点：落地 → Claude API（api.anthropic.com）")
        XCTAssertTrue(ChainPresentation.describe(raw, proxies: ["落地": .init(type: "Socks5")]).contains("前置节点：未获取"))
    }

    func testDirectConnectionDoesNotInventProxyNodes() {
        XCTAssertEqual(ChainPresentation.describe("claude.ai: DIRECT", proxies: nil),
                       "本机 → 直连 → Claude 网页（claude.ai）")
    }

    func testOldSnapshotRemainsReadableAndPresentationDoesNotTriggerDrift() throws {
        var settings = WatchSettings(); settings.geoEnabled = false; settings.chainEnabled = true
        let original = Snapshot(endpoints: [Endpoint(host: "claude.ai", ip: "1.1.1.1", country: "US")], chains: ["claude.ai: 落地 → 分流组"])
        let data = try JSONEncoder().encode(original)
        let baseline = try JSONDecoder().decode(Snapshot.self, from: data)
        XCTAssertNil(baseline.chainPaths)
        var current = baseline
        current.chainPaths = ["本机 → 前置节点：美国节点 → 落地节点：落地 → Claude 网页（claude.ai）"]
        XCTAssertTrue(Comparison.issues(current, baseline: baseline, settings: settings).isEmpty)
    }
}
