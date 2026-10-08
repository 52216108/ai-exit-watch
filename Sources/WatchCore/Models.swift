import Foundation
import Darwin

public struct Endpoint: Codable, Equatable, Sendable {
    public static let monitoredHosts = ["claude.ai", "api.anthropic.com", "chatgpt.com"]

    public var host: String
    public var ip: String?
    public var country: String?
    public var milliseconds: Int?
    public var error: String?
    public var displayName: String {
        switch host {
        case "claude.ai": return "Claude 网页"
        case "api.anthropic.com": return "Claude API"
        case "chatgpt.com": return "ChatGPT 网页"
        default: return ReferenceTarget(rawValue: host)?.title ?? host
        }
    }
    public init(host: String, ip: String? = nil, country: String? = nil, milliseconds: Int? = nil, error: String? = nil) {
        self.host = host; self.ip = ip; self.country = country
        self.milliseconds = milliseconds; self.error = error
    }
}

public struct Geo: Codable, Equatable, Sendable {
    public var ip: String
    public var country: String
    public var asn: Int
    public var isp: String
    public var checkedAt: Date
    public var region: String?
    public var city: String?
    public var postal: String?
    public var timezone: String?
    public init(ip: String, country: String, asn: Int, isp: String, checkedAt: Date = Date(), region: String? = nil, city: String? = nil, postal: String? = nil, timezone: String? = nil) {
        self.ip = ip; self.country = country; self.asn = asn; self.isp = isp; self.checkedAt = checkedAt
        self.region = region; self.city = city; self.postal = postal; self.timezone = timezone
    }
}

public struct Snapshot: Codable, Sendable {
    public var date: Date
    public var endpoints: [Endpoint]
    public var geo: [String: Geo]
    public var geoErrors: [String: String]
    public var chains: [String]?
    public var chainPaths: [String]?
    public var chainError: String?
    public var risks: [String: IPRisk]?
    public var riskErrors: [String: String]?
    public var referenceEndpoints: [Endpoint]?
    public init(date: Date = Date(), endpoints: [Endpoint], geo: [String: Geo] = [:], geoErrors: [String: String] = [:], chains: [String]? = nil, chainError: String? = nil, chainPaths: [String]? = nil, risks: [String: IPRisk]? = nil, riskErrors: [String: String]? = nil, referenceEndpoints: [Endpoint]? = nil) {
        self.date = date; self.endpoints = endpoints; self.geo = geo
        self.geoErrors = geoErrors; self.chains = chains; self.chainError = chainError; self.chainPaths = chainPaths
        self.risks = risks; self.riskErrors = riskErrors
        self.referenceEndpoints = referenceEndpoints
    }
    public var hasAllTargets: Bool {
        endpoints.count == Endpoint.monitoredHosts.count && Set(endpoints.map(\.host)) == Set(Endpoint.monitoredHosts)
    }
    public var missingBaselineNames: [String] {
        Endpoint.monitoredHosts.filter { host in !endpoints.contains { $0.host == host && $0.ip != nil && $0.error == nil } }
            .map { Endpoint(host: $0).displayName }
    }
    public func canBaseline(settings: WatchSettings) -> Bool {
        hasAllTargets && endpoints.allSatisfy { $0.error == nil && $0.ip != nil && (!settings.geoEnabled || geo[$0.ip!] != nil) }
            && (!settings.chainEnabled || chains?.isEmpty == false)
    }
}

public struct WatchSettings: Codable, Equatable, Sendable {
    public var interval: Double = 60
    public var slowMilliseconds: Int = 3000
    public var geoEnabled: Bool = true
    public var chainEnabled: Bool = false
    public var socketPath: String = ""
    public init() {}
}

public struct Issue: Codable, Equatable, Sendable {
    public var id: String
    public var message: String
    public init(_ id: String, _ message: String) { self.id = id; self.message = message }
}

public enum Comparison {
    public static func issues(_ sample: Snapshot, baseline: Snapshot?, settings: WatchSettings) -> [Issue] {
        var issues: [Issue] = []
        for endpoint in sample.endpoints {
            let host = endpoint.host
            guard endpoint.error == nil, let ip = endpoint.ip else {
                issues.append(Issue("network:\(host)", "\(host)：\(endpoint.error ?? "未获取出口 IP")")); continue
            }
            if let previous = baseline?.endpoints.first(where: { $0.host == host }) {
                if let old = previous.ip, old != ip { issues.append(Issue("ip:\(host)", "\(host) 出口变化：\(old) → \(ip)")) }
                if let old = previous.country, let new = endpoint.country, old != new {
                    issues.append(Issue("country:\(host)", "\(host) 探测地区变化：\(GeoPresentation.country(old)) → \(GeoPresentation.country(new))"))
                }
                if settings.geoEnabled, let oldIP = previous.ip, let oldGeo = baseline?.geo[oldIP], let newGeo = sample.geo[ip] {
                    if oldGeo.asn != newGeo.asn { issues.append(Issue("asn:\(host)", "\(host) ASN 变化：AS\(oldGeo.asn) → AS\(newGeo.asn)")) }
                    if oldGeo.country != newGeo.country { issues.append(Issue("geo:\(host)", "\(host) IP 库地区变化：\(GeoPresentation.country(oldGeo.country)) → \(GeoPresentation.country(newGeo.country))")) }
                }
            }
            if settings.geoEnabled && sample.geo[ip] == nil { issues.append(Issue("geo-unavailable:\(host)", "\(host) IP 属性未知：\(sample.geoErrors[ip] ?? "无数据")")) }
            if let latency = endpoint.milliseconds, latency > settings.slowMilliseconds {
                issues.append(Issue("slow:\(host)", "\(host) 延迟 \(latency) ms，超过 \(settings.slowMilliseconds) ms"))
            }
        }
        if settings.chainEnabled {
            if let chains = sample.chains, !chains.isEmpty {
                if let old = baseline?.chains, old != chains { issues.append(Issue("chain:claude", "观察到的 Claude 链路变化：\(chains.joined(separator: "；"))")) }
            } else { issues.append(Issue("chain-unavailable", sample.chainError ?? "未捕获 Claude 连接，代理链路未知")) }
        }
        return issues
    }
}

public struct AlertEvent: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var date = Date()
    public var title: String
    public var message: String
    public init(title: String, message: String) { self.title = title; self.message = message }
}

// 每项异常独立计数；新异常不延迟已有告警，缺失数据不会被判作恢复。
public struct AlertMachine: Sendable {
    private var streak: [String: Int] = [:]
    private var clearStreak: [String: Int] = [:]
    public private(set) var active: [String: Issue] = [:]
    public init() {}
    public mutating func resetPending() { streak = [:]; clearStreak = [:] }
    public mutating func consume(_ issues: [Issue]) -> [AlertEvent] {
        let current = Dictionary(issues.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        streak = streak.filter { current[$0.key] != nil }
        var started: [String] = [], ended: [String] = []
        for (id, issue) in current {
            streak[id, default: 0] += 1; clearStreak[id] = nil
            if streak[id, default: 0] >= 2 && active[id] == nil { active[id] = issue; started.append(issue.message) }
            if active[id] != nil { active[id] = issue }
        }
        for (id, issue) in active where current[id] == nil {
            // 同一目标未能取数时，不能宣称其 IP/ASN/地区/链路偏离恢复。
            let host = id.split(separator: ":").dropFirst().first.map(String.init)
            let blocked = (host != nil && current["network:\(host!)"] != nil)
                || ((id.hasPrefix("asn:") || id.hasPrefix("geo:")) && host != nil && current["geo-unavailable:\(host!)"] != nil)
                || (id.hasPrefix("chain:") && current["chain-unavailable"] != nil)
            if blocked { clearStreak[id] = nil; continue }
            clearStreak[id, default: 0] += 1
            if clearStreak[id, default: 0] >= 2 { active[id] = nil; clearStreak[id] = nil; ended.append(issue.message) }
        }
        var events: [AlertEvent] = []
        if !started.isEmpty { events.append(AlertEvent(title: "网络监测发现异常", message: started.sorted().joined(separator: "\n"))) }
        if !ended.isEmpty { events.append(AlertEvent(title: "部分检测项已恢复或变化", message: "以下先前异常已连续两次不再出现：\n" + ended.sorted().joined(separator: "\n"))) }
        return events
    }
}

public enum ProbeFailure: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

public enum TraceParser {
    public static func validIP(_ value: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        return value.withCString { inet_pton(AF_INET, $0, &v4) == 1 || inet_pton(AF_INET6, $0, &v6) == 1 }
    }
    public static func parse(_ text: String, host: String, milliseconds: Int) throws -> Endpoint {
        var fields: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let pieces = line.split(separator: "=", maxSplits: 1)
            if pieces.count == 2 { fields[String(pieces[0])] = String(pieces[1]).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        guard let ip = fields["ip"], validIP(ip), let country = fields["loc"], country.range(of: "^[A-Z]{2}$", options: .regularExpression) != nil else {
            throw ProbeFailure.invalid("检测响应不完整或不是有效 trace")
        }
        return Endpoint(host: host, ip: ip, country: country, milliseconds: milliseconds)
    }
}
