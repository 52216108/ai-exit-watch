import Foundation

public struct LockProxy: Decodable, Sendable {
    public var type: String
    public var dialerProxy: String?
    public var all: [String]?
    public var now: String?
    enum CodingKeys: String, CodingKey { case type, all, now; case dialerProxy = "dialer-proxy" }

    var configType: String? {
        switch type.lowercased() {
        case "shadowsocks": return "ss"
        case "shadowsocksr": return "ssr"
        case "socks5", "http", "snell", "vmess", "vless", "trojan", "hysteria", "hysteria2", "tuic", "wireguard", "anytls", "ssh": return type.lowercased()
        default: return nil
        }
    }
}

public struct LockNode: Codable, Equatable, Sendable {
    public var name: String
    public var type: String
    public var dialer: String
}

public struct LockRule: Decodable, Sendable {
    public struct Extra: Decodable, Sendable { public var disabled: Bool }
    public var type: String
    public var payload: String
    public var proxy: String
    public var extra: Extra?
}

public struct LockRuntime: Sendable {
    public var mode: String
    public var proxies: [String: LockProxy]
    public var rules: [LockRule]

    public var candidates: [String] {
        proxies.keys.filter { (try? chain($0)) != nil }.sorted()
    }

    public func chain(_ landing: String) throws -> [LockNode] {
        var result: [LockNode] = [], visited: Set<String> = []
        var name = landing
        while !name.isEmpty {
            guard visited.insert(name).inserted, let proxy = proxies[name],
                  let type = proxy.configType, proxy.all == nil, proxy.now == nil,
                  let dialer = proxy.dialerProxy else {
                throw ProbeFailure.invalid("仅支持明确的固定节点链；不能选择自动切换组、直连或链路信息不完整的节点。")
            }
            result.append(LockNode(name: name, type: type, dialer: dialer))
            name = dialer
        }
        return result
    }
}

public struct ExitLockPlan: Codable, Equatable, Sendable {
    public static let claudeDomains = ["claude.ai", "anthropic.com", "claudeusercontent.com"]
    public static let openAIDomains = ["chatgpt.com", "openai.com", "oaistatic.com", "oaiusercontent.com"]
    public var nodes: [LockNode]
    public var domains: [String]
    public var landing: String { nodes[0].name }
    public var path: String { (["本机"] + nodes.reversed().map(\.name) + ["AI 服务"]).joined(separator: " → ") }

    public init(runtime: LockRuntime, landing: String, claude: Bool, openAI: Bool) throws {
        guard claude || openAI else { throw ProbeFailure.invalid("请至少选择一类要保护的 AI 服务。") }
        nodes = try runtime.chain(landing)
        guard !nodes.isEmpty, nodes.allSatisfy({ node in
            !node.name.contains(",") && !node.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        }) else { throw ProbeFailure.invalid("节点名称含规则分隔符或控制字符，不能安全生成配置。") }
        domains = (claude ? Self.claudeDomains : []) + (openAI ? Self.openAIDomains : [])
    }

    public func script() throws -> String {
        let data = try JSONEncoder().encode(self)
        let json = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return """
        // BEGIN AI落地安全检测 出口锁定
        // 适用于 Clash Verge Rev 的订阅扩展脚本，追加在现有脚本末尾。
        // 更新时替换整个 BEGIN / END 区块；不要覆盖原有前置、落地配置脚本。
        // 仅对经过 Mihomo 规则模式的新连接生效；不更改 TUN、DNS 或节点定义。
        var main = (function (previousMain) {
          const plan = \(json);
          return function (config, profileName) {
            const next = typeof previousMain === "function" ? previousMain(config, profileName) : config;
            const proxies = Array.isArray(next.proxies) ? next.proxies : [];
            const groups = Array.isArray(next["proxy-groups"]) ? next["proxy-groups"] : [];
            // 任一固定节点缺失、变成策略组或前置关系改变，均改为拒绝。
            const valid = plan.nodes.every(function (expected) {
              const matches = proxies.filter(function (p) { return p.name === expected.name; });
              return matches.length === 1
                && !groups.some(function (g) { return g.name === expected.name; })
                && matches[0].type === expected.type
                && (matches[0]["dialer-proxy"] || "") === expected.dialer;
            });
            const target = valid ? plan.nodes[0].name : "REJECT";
            const lockRules = plan.domains.flatMap(function (domain) {
              // Mihomo 会跳过不支持 UDP 的节点；紧邻的拒绝规则阻止流量落入其他出口。
              return ["DOMAIN-SUFFIX," + domain + "," + target, "DOMAIN-SUFFIX," + domain + ",REJECT"];
            });
            // 固定指向该节点：拨号失败即连接失败，不回退直连或其他代理。
            const original = Array.isArray(next.rules) ? next.rules : [];
            next.rules = lockRules.concat(original.filter(function (rule) { return !lockRules.includes(rule); }));
            return next;
          };
        })(typeof main === "function" ? main : null);
        // END AI落地安全检测 出口锁定
        """
    }

    public func verify(_ runtime: LockRuntime) -> LockVerification {
        guard runtime.mode.lowercased() == "rule" else {
            return .unverified("Mihomo 当前不是规则模式，不能确认出口锁定生效。")
        }
        guard runtime.rules.count >= domains.count * 2 else {
            return .unverified("未找到完整的置顶保护规则，请先导入并启用扩展脚本。")
        }
        let first = Array(runtime.rules.prefix(domains.count * 2))
        let expectedDomains = domains.flatMap { [$0, $0] }
        guard zip(expectedDomains, first).allSatisfy({ domain, rule in
            rule.type == "DomainSuffix" && rule.payload == domain && rule.extra?.disabled != true
        }) else { return .unverified("保护规则未完整置顶或已被禁用，不能确认锁定生效。") }
        guard stride(from: 1, to: first.count, by: 2).allSatisfy({ first[$0].proxy == "REJECT" }) else {
            return .unverified("缺少域名拒绝兜底，UDP 可能绕到后续规则，不能确认锁定生效。")
        }
        if first.allSatisfy({ $0.proxy == "REJECT" }) {
            return .rejected("保护域名的置顶规则均指向 REJECT，新连接会被拒绝。")
        }
        guard stride(from: 0, to: first.count, by: 2).allSatisfy({ first[$0].proxy == landing }),
              let current = try? runtime.chain(landing), current == nodes else {
            return .unverified("规则目标或前置链路与所选方案不一致，请重新检查配置。")
        }
        return .fixed("置顶规则指向指定固定节点；连接失败不会改走其他出口。")
    }
}

public enum LockVerification: Equatable, Sendable {
    case unverified(String)
    case fixed(String)
    case rejected(String)
    public var message: String {
        switch self { case .unverified(let text), .fixed(let text), .rejected(let text): return text }
    }
}

public enum ExitLockReader {
    public static func read(socketPath: String) async throws -> LockRuntime {
        if let message = ChainReader.configurationError(socketPath: socketPath) { throw ProbeFailure.invalid(message) }
        return try await Task.detached {
            func get(_ endpoint: String) throws -> Data {
                let process = Process(), pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
                process.arguments = ["--silent", "--fail", "--noproxy", "*", "--max-time", "3", "--unix-socket", socketPath, "http://localhost/" + endpoint]
                process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw ProbeFailure.invalid("无法读取 Mihomo 配置，请检查本地 socket 和访问权限。") }
                return data
            }
            struct Config: Decodable { var mode: String }
            struct Proxies: Decodable { var proxies: [String: LockProxy] }
            struct Rules: Decodable { var rules: [LockRule] }
            let decoder = JSONDecoder()
            let config = try decoder.decode(Config.self, from: get("configs"))
            let proxies = try decoder.decode(Proxies.self, from: get("proxies"))
            let rules = try decoder.decode(Rules.self, from: get("rules"))
            return LockRuntime(mode: config.mode, proxies: proxies.proxies, rules: rules.rules)
        }.value
    }
}
