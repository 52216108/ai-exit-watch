import XCTest
import JavaScriptCore
@testable import WatchCore

final class ExitLockTests: XCTestCase {
    private func runtime() throws -> LockRuntime {
        let data = Data(#"{"落地":{"type":"Socks5","dialer-proxy":"前置"},"前置":{"type":"Hysteria2","dialer-proxy":""},"自动":{"type":"Fallback","all":["落地","DIRECT"],"now":"落地","dialer-proxy":""},"DIRECT":{"type":"Direct","dialer-proxy":""}}"#.utf8)
        return LockRuntime(mode: "rule", proxies: try JSONDecoder().decode([String: LockProxy].self, from: data), rules: [])
    }
    private func plan() throws -> ExitLockPlan {
        try ExitLockPlan(runtime: runtime(), landing: "落地", claude: true, openAI: true)
    }
    private var source: [String: Any] {
        ["proxies": [["name": "落地", "type": "socks5", "dialer-proxy": "前置", "server": "127.0.0.1", "port": 1],
                      ["name": "前置", "type": "hysteria2", "server": "127.0.0.1", "port": 2]],
         "proxy-groups": [["name": "其他分流", "type": "select", "proxies": ["DIRECT", "落地"]]],
         "rules": ["DOMAIN-SUFFIX,example.com,DIRECT", "MATCH,其他分流"],
         "tun": ["enable": true], "dns": ["enable": true, "nameserver": ["https://example.com/dns-query"]]]
    }
    private func apply(_ config: [String: Any], script: String? = nil, previous: String = "") throws -> [String: Any] {
        let context = JSContext()!
        var failure: String?
        context.exceptionHandler = { _, error in failure = error?.toString() }
        context.evaluateScript(previous + "\n" + (try script ?? plan().script()))
        let result = context.objectForKeyedSubscript("main")!.call(withArguments: [config, "测试订阅"])
        XCTAssertNil(failure)
        return try XCTUnwrap(result?.toDictionary() as? [String: Any])
    }
    private func rules(_ config: [String: Any]) throws -> [String] { try XCTUnwrap(config["rules"] as? [String]) }
    private func makeRules(_ target: String) throws -> [LockRule] {
        let objects = try plan().domains.flatMap { domain in [target, "REJECT"].map { ["type": "DomainSuffix", "payload": domain, "proxy": $0, "extra": ["disabled": false]] as [String: Any] } }
        return try JSONDecoder().decode([LockRule].self, from: JSONSerialization.data(withJSONObject: objects))
    }

    func testPreservesExistingChainAndRunsPreviousScriptFirst() throws {
        let generated = try plan().script()
        let result = try apply(source, script: generated, previous: "function main(config, name) { config.originalRan = name; return config; }")
        XCTAssertEqual(result["originalRan"] as? String, "测试订阅")
        for key in ["proxies", "proxy-groups", "tun", "dns"] {
            XCTAssertEqual(result[key] as? NSObject, source[key] as? NSObject)
        }
        XCTAssertEqual(try rules(result).prefix(14), try plan().domains.flatMap { ["DOMAIN-SUFFIX,\($0),落地", "DOMAIN-SUFFIX,\($0),REJECT"] }[...])
        XCTAssertEqual(Array(try rules(result).suffix(2)), source["rules"] as? [String])
        XCTAssertFalse(generated.contains("127.0.0.1"))
        XCTAssertEqual(try rules(apply(result)), try rules(result))
    }

    func testMissingChangedOrAmbiguousNodesRejectInsteadOfFallingBack() throws {
        var variants: [[String: Any]] = []
        var missing = source; missing["proxies"] = []; variants.append(missing)
        var changed = source
        var nodes = source["proxies"] as! [[String: Any]]
        nodes[0]["dialer-proxy"] = "其他分流"; changed["proxies"] = nodes; variants.append(changed)
        nodes = source["proxies"] as! [[String: Any]]
        nodes[0]["type"] = "direct"; changed["proxies"] = nodes; variants.append(changed)
        nodes = source["proxies"] as! [[String: Any]]
        changed["proxies"] = nodes + [nodes[0]]; variants.append(changed)
        var groupCollision = source; groupCollision["proxy-groups"] = [["name": "落地", "type": "select", "proxies": ["DIRECT"]]]; variants.append(groupCollision)
        for config in variants {
            XCTAssertTrue(try rules(apply(config)).prefix(14).allSatisfy { $0.hasSuffix(",REJECT") })
        }
    }

    func testRejectsGroupsCyclesUnknownChainAndRuleInjection() throws {
        var current = try runtime()
        XCTAssertEqual(current.candidates, ["前置", "落地"])
        XCTAssertThrowsError(try ExitLockPlan(runtime: current, landing: "自动", claude: true, openAI: true))
        XCTAssertThrowsError(try ExitLockPlan(runtime: current, landing: "DIRECT", claude: true, openAI: true))
        XCTAssertThrowsError(try ExitLockPlan(runtime: current, landing: "落地", claude: false, openAI: false))
        current.proxies["前置"]?.dialerProxy = "落地"
        XCTAssertThrowsError(try current.chain("落地"))
        current = try runtime(); current.proxies["前置"]?.dialerProxy = nil
        XCTAssertThrowsError(try current.chain("落地"))
        current = try runtime(); current.proxies["bad,DIRECT"] = current.proxies["落地"]
        XCTAssertThrowsError(try ExitLockPlan(runtime: current, landing: "bad,DIRECT", claude: true, openAI: true))
    }

    func testScriptEscapesNodeNamesWithoutExecutingThem() throws {
        var current = try runtime()
        let name = "落地\";globalThis.injection=true;//"
        current.proxies[name] = current.proxies["落地"]
        let planned = try ExitLockPlan(runtime: current, landing: name, claude: true, openAI: false)
        var config = source; var nodes = config["proxies"] as! [[String: Any]]
        nodes[0]["name"] = name; config["proxies"] = nodes
        let context = JSContext()!
        context.evaluateScript(try planned.script())
        let result = context.objectForKeyedSubscript("main")!.call(withArguments: [config])!.toDictionary() as! [String: Any]
        XCTAssertTrue(context.objectForKeyedSubscript("injection")!.isUndefined)
        XCTAssertEqual(try rules(result).first, "DOMAIN-SUFFIX,claude.ai," + name)
    }

    func testVerificationRequiresExactPriorityTargetModeAndEnabledRules() throws {
        let planned = try plan()
        var current = try runtime(); current.rules = try makeRules("落地")
        guard case .fixed = planned.verify(current) else { return XCTFail("固定链路应匹配") }
        current.rules = try makeRules("REJECT")
        guard case .rejected = planned.verify(current) else { return XCTFail("拒绝规则应识别") }
        current.rules = try makeRules("DIRECT")
        guard case .unverified = planned.verify(current) else { return XCTFail("不能认可直连") }
        current.rules = try makeRules("落地"); current.rules[0].extra?.disabled = true
        guard case .unverified = planned.verify(current) else { return XCTFail("不能认可已禁用规则") }
        current.rules = try makeRules("落地"); current.rules[1].proxy = "DIRECT"
        guard case .unverified = planned.verify(current) else { return XCTFail("UDP 拒绝兜底不能变成直连") }
        current.rules = try makeRules("落地"); current.rules[1].extra?.disabled = true
        guard case .unverified = planned.verify(current) else { return XCTFail("UDP 拒绝兜底不能禁用") }
        current.rules = try makeRules("落地").enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
        guard case .unverified = planned.verify(current) else { return XCTFail("仅有固定节点规则不能认可") }
        current.rules = try makeRules("落地"); current.mode = "global"
        guard case .unverified = planned.verify(current) else { return XCTFail("全局模式不受规则保护") }
        current.mode = "rule"; current.rules.reverse()
        guard case .unverified = planned.verify(current) else { return XCTFail("规则顺序不一致") }
        current.rules = try makeRules("落地"); current.proxies["落地"]?.dialerProxy = ""
        guard case .unverified = planned.verify(current) else { return XCTFail("链路变化不能认可") }
    }

    func testIsolatedMihomoStopsFailedChainWithoutDirectFallback() throws {
        guard let binary = ProcessInfo.processInfo.environment["MIHOMO_TEST_BINARY"] else {
            throw XCTSkip("设置 MIHOMO_TEST_BINARY 后运行独立 Mihomo 集成测试")
        }
        var current = try runtime(); current.proxies["前置"]?.type = "Socks5"
        let planned = try ExitLockPlan(runtime: current, landing: "落地", claude: true, openAI: true)
        var config = source
        var nodes = config["proxies"] as! [[String: Any]]; nodes[1]["type"] = "socks5"
        config["proxies"] = nodes; config["proxy-groups"] = []; config["rules"] = ["MATCH,DIRECT"]
        let fixed = try apply(config, script: planned.script())
        config["proxies"] = []
        let rejected = try apply(config, script: planned.script())
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = folder.appendingPathComponent("fixture.json")
        // 测试对照：移除拒绝兜底，应复现不支持 UDP 的节点被跳过而直连。
        var unsafeControl = fixed
        unsafeControl["rules"] = try rules(fixed).filter { !$0.hasSuffix(",REJECT") }
        try JSONSerialization.data(withJSONObject: [fixed, rejected, unsafeControl]).write(to: fixture)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("verify_exit_lock.py")
        process.arguments = ["python3", script.path, binary, fixture.path]
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
