import XCTest
import Darwin
@testable import WatchCore

final class WatchCoreTests: XCTestCase {
    func testSocketDiscoveryPreservesValidCustomSocket() throws {
        let path = "/tmp/network-watch-\(UUID().uuidString).sock"
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        guard fd >= 0 else { return }
        defer { close(fd); unlink(path) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(result, 0)
        XCTAssertNil(ChainReader.configurationError(socketPath: path))
        XCTAssertEqual(ChainReader.suggestedSocket(configuredPath: path), path)
    }

    func testChainConfigurationRejectsMissingPathAndRegularFile() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertNotNil(ChainReader.configurationError(socketPath: file.path))
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        // 文件存在并不代表它能用于 Mihomo 的 Unix socket 连接。
        XCTAssertNotNil(ChainReader.configurationError(socketPath: file.path))
    }

    func testTraceRejectsHTMLAndInvalidIP() throws {
        XCTAssertThrowsError(try TraceParser.parse("<html>challenge</html>", host: "claude.ai", milliseconds: 1))
        XCTAssertThrowsError(try TraceParser.parse("ip=999.1.1.1\nloc=US", host: "claude.ai", milliseconds: 1))
        XCTAssertThrowsError(try TraceParser.parse("ip=1.1.1.1", host: "claude.ai", milliseconds: 1))
        XCTAssertEqual(try TraceParser.parse("ip=2606:4700::1111\nloc=US\n", host: "claude.ai", milliseconds: 12).ip, "2606:4700::1111")
    }

    func testChangingDeviationValuesStillConfirmAndUpdateMessage() {
        var settings = WatchSettings(); settings.geoEnabled = false
        let baseline = Snapshot(endpoints: [Endpoint(host: "claude.ai", ip: "1.1.1.1", country: "US")])
        var machine = AlertMachine()
        let first = Snapshot(endpoints: [Endpoint(host: "claude.ai", ip: "2.2.2.2", country: "US")])
        let second = Snapshot(endpoints: [Endpoint(host: "claude.ai", ip: "3.3.3.3", country: "US")])
        let third = Snapshot(endpoints: [Endpoint(host: "claude.ai", ip: "4.4.4.4", country: "US")])
        XCTAssertTrue(machine.consume(Comparison.issues(first, baseline: baseline, settings: settings)).isEmpty)
        XCTAssertEqual(machine.consume(Comparison.issues(second, baseline: baseline, settings: settings)).count, 1)
        XCTAssertTrue(machine.consume(Comparison.issues(third, baseline: baseline, settings: settings)).isEmpty)
        XCTAssertTrue(machine.active["ip:claude.ai"]?.message.contains("4.4.4.4") == true)
    }

    func testIndependentConfirmationDedupAndRecovery() {
        var machine = AlertMachine()
        let failure = Issue("network:claude.ai", "连接超时")
        XCTAssertTrue(machine.consume([failure]).isEmpty)
        XCTAssertEqual(machine.consume([failure]).count, 1)
        XCTAssertTrue(machine.consume([failure]).isEmpty)
        let slow = Issue("slow:api.anthropic.com", "延迟较高")
        XCTAssertTrue(machine.consume([failure, slow]).isEmpty)
        XCTAssertEqual(machine.consume([failure, slow]).count, 1)
        XCTAssertTrue(machine.consume([]).isEmpty)
        XCTAssertEqual(machine.consume([]).count, 1)
        XCTAssertTrue(machine.active.isEmpty)
        XCTAssertTrue(machine.consume([]).isEmpty)
    }

    func testTransientFailureAndPauseDoNotCountAsConsecutive() {
        var machine = AlertMachine()
        let issue = Issue("network:claude.ai", "连接失败")
        XCTAssertTrue(machine.consume([issue]).isEmpty)
        XCTAssertTrue(machine.consume([]).isEmpty)
        XCTAssertTrue(machine.consume([issue]).isEmpty)
        machine.resetPending()
        XCTAssertTrue(machine.consume([issue]).isEmpty)
        XCTAssertEqual(machine.consume([issue]).count, 1)
    }

    func testUnknownDataNeverResolvesEstablishedDeviation() {
        var machine = AlertMachine()
        let changed = Issue("ip:claude.ai:2.2.2.2", "IP 已变化")
        _ = machine.consume([changed]); _ = machine.consume([changed])
        let missing = Issue("network:claude.ai", "连接失败")
        _ = machine.consume([missing]); _ = machine.consume([missing]); _ = machine.consume([missing])
        XCTAssertNotNil(machine.active[changed.id])
        let events = machine.consume([missing])
        XCTAssertTrue(events.isEmpty)
    }

    func testMissingGeoAndChainDoNotProduceFalseRecovery() {
        var machine = AlertMachine()
        let asn = Issue("asn:claude.ai:1234", "ASN 变化")
        let chain = Issue("chain:route", "链路变化")
        _ = machine.consume([asn, chain]); _ = machine.consume([asn, chain])
        let missing = [Issue("geo-unavailable:claude.ai", "未知"), Issue("chain-unavailable", "未知")]
        _ = machine.consume(missing); _ = machine.consume(missing); _ = machine.consume(missing)
        XCTAssertNotNil(machine.active[asn.id]); XCTAssertNotNil(machine.active[chain.id])
    }

    func testComparisonChecksBothRoutesAndDoesNotMutateBaseline() {
        let old = Snapshot(endpoints: [Endpoint(host: "claude.ai", ip: "1.1.1.1", country: "US", milliseconds: 100), Endpoint(host: "api.anthropic.com", ip: "1.1.1.1", country: "US", milliseconds: 100)], geo: ["1.1.1.1": Geo(ip: "1.1.1.1", country: "US", asn: 1, isp: "baseline")])
        let new = Snapshot(endpoints: [Endpoint(host: "claude.ai", ip: "1.1.1.1", country: "US", milliseconds: 100), Endpoint(host: "api.anthropic.com", ip: "8.8.8.8", country: "DE", milliseconds: 5000)], geo: ["1.1.1.1": old.geo["1.1.1.1"]!, "8.8.8.8": Geo(ip: "8.8.8.8", country: "DE", asn: 2, isp: "changed")])
        let issues = Comparison.issues(new, baseline: old, settings: WatchSettings())
        XCTAssertEqual(issues.count, 5)
        XCTAssertTrue(issues.allSatisfy { $0.id.contains("api.anthropic.com") })
        XCTAssertEqual(old.endpoints.last?.ip, "1.1.1.1")
    }

    func testCannotBaselinePartialOrUnknownResults() {
        let endpoints = [Endpoint(host: "claude.ai", ip: "1.1.1.1", country: "US"), Endpoint(host: "api.anthropic.com", error: "失败")]
        XCTAssertFalse(Snapshot(endpoints: endpoints).canBaseline(settings: WatchSettings()))
        var sample = Snapshot(endpoints: [endpoints[0], Endpoint(host: "api.anthropic.com", ip: "1.1.1.1", country: "US"), Endpoint(host: "chatgpt.com", ip: "1.1.1.1", country: "US")])
        XCTAssertFalse(sample.canBaseline(settings: WatchSettings()))
        sample.geo["1.1.1.1"] = Geo(ip: "1.1.1.1", country: "US", asn: 1, isp: "test")
        XCTAssertTrue(sample.canBaseline(settings: WatchSettings()))
        var settings = WatchSettings(); settings.chainEnabled = true
        XCTAssertFalse(sample.canBaseline(settings: settings))
    }

    func testOldClaudeBaselineRemainsReadableAndRequiresChatGPTConfirmation() throws {
        let data = Data(#"{"date":0,"endpoints":[{"host":"claude.ai","ip":"1.1.1.1","country":"US"},{"host":"api.anthropic.com","ip":"1.1.1.1","country":"US"}],"geo":{},"geoErrors":{}}"#.utf8)
        let baseline = try JSONDecoder().decode(Snapshot.self, from: data)
        var settings = WatchSettings(); settings.geoEnabled = false
        XCTAssertEqual(baseline.missingBaselineNames, ["ChatGPT 网页"])
        XCTAssertFalse(baseline.canBaseline(settings: settings))
        var sample = baseline
        sample.endpoints.append(Endpoint(host: "chatgpt.com", ip: "8.8.8.8", country: "US"))
        XCTAssertTrue(sample.canBaseline(settings: settings))
        XCTAssertTrue(sample.missingBaselineNames.isEmpty)
        XCTAssertTrue(Comparison.issues(sample, baseline: baseline, settings: settings).isEmpty)
        sample.endpoints[0].ip = "2.2.2.2"
        XCTAssertEqual(Comparison.issues(sample, baseline: baseline, settings: settings).map(\.id), ["ip:claude.ai"])
        XCTAssertEqual(baseline.endpoints.count, 2)
        XCTAssertEqual(baseline.endpoints[0].ip, "1.1.1.1")
    }

    func testChatGPTChangesAndFailuresUseIndependentAlerts() {
        var settings = WatchSettings(); settings.geoEnabled = false
        let baseline = Snapshot(endpoints: Endpoint.monitoredHosts.map { Endpoint(host: $0, ip: "1.1.1.1", country: "US") })
        var sample = baseline
        sample.endpoints[2].ip = "8.8.8.8"
        let issues = Comparison.issues(sample, baseline: baseline, settings: settings)
        XCTAssertEqual(issues.map(\.id), ["ip:chatgpt.com"])
        var machine = AlertMachine()
        XCTAssertTrue(machine.consume(issues).isEmpty)
        XCTAssertEqual(machine.consume(issues).count, 1)
        sample.endpoints[2] = Endpoint(host: "chatgpt.com", error: "HTTP 403")
        XCTAssertFalse(sample.canBaseline(settings: settings))
        let unavailable = Comparison.issues(sample, baseline: baseline, settings: settings)
        XCTAssertEqual(unavailable.map(\.id), ["network:chatgpt.com"])
        _ = machine.consume(unavailable); _ = machine.consume(unavailable)
        XCTAssertNotNil(machine.active["ip:chatgpt.com"])
        XCTAssertNotNil(machine.active["network:chatgpt.com"])
        sample.endpoints[2] = baseline.endpoints[0]
        XCTAssertFalse(sample.canBaseline(settings: settings), "重复 Claude 结果不能替代 ChatGPT 出口")
    }

    func testStateRoundTripAndCorruptionIsAnError() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = Store(directory: directory)
        var state = SavedState()
        state.settings.interval = 120
        state.events.append(AlertEvent(title: "test", message: "evidence"))
        try store.write(state)
        XCTAssertEqual(try store.read().settings.interval, 120)
        XCTAssertEqual(try store.read().events.first?.message, "evidence")
        let permissions = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("state.json").path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        try Data("broken".utf8).write(to: directory.appendingPathComponent("state.json"))
        XCTAssertThrowsError(try store.read())
    }
}
