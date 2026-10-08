import Foundation

struct ProxyRouteInfo: Decodable {
    var type: String
    var now: String?
    var dialerProxy: String?
    enum CodingKeys: String, CodingKey { case type, now; case dialerProxy = "dialer-proxy" }
}

enum ChainPresentation {
    static func describe(_ chain: String, proxies: [String: ProxyRouteInfo]?) -> String {
        guard let separator = chain.range(of: ": ") else { return chain }
        let host = String(chain[..<separator.lowerBound])
        let observed = chain[separator.upperBound...].components(separatedBy: " → ")
        guard let landing = observed.first, !landing.isEmpty else { return chain }
        let destination = host == "claude.ai" ? "Claude 网页（\(host)）" : "Claude API（\(host)）"

        // /connections 的首项是实际出站；策略组只是选择规则，不能画成网络节点。
        // 前置节点由该出站在 /proxies 中的运行配置补充，不改变原始告警比较数据。
        func route(to name: String, visiting: Set<String>) -> [String]? {
            guard !visiting.contains(name), let proxy = proxies?[name] else { return nil }
            let visited = visiting.union([name])
            if let selected = proxy.now { return route(to: selected, visiting: visited) }
            if ["Selector", "URLTest", "Fallback", "LoadBalance", "Relay"].contains(proxy.type) { return nil }
            guard let dialer = proxy.dialerProxy else { return nil }
            if !dialer.isEmpty {
                guard let prefix = route(to: dialer, visiting: visited) else { return nil }
                return prefix + [name]
            }
            return [name]
        }

        if proxies?[landing]?.type == "Direct" || landing == "DIRECT" {
            return "本机 → 直连 → \(destination)"
        }
        let nodes = route(to: landing, visiting: [])
        let fronts = nodes?.dropLast()
        let frontText: String
        if let fronts {
            frontText = fronts.isEmpty ? "前置节点：无" : fronts.map { "前置节点：\($0)" }.joined(separator: " → ")
        } else {
            frontText = "前置节点：未获取"
        }
        return "本机 → \(frontText) → 落地节点：\(landing) → \(destination)"
    }
}
