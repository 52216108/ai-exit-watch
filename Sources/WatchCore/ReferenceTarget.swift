import Foundation

// 参考目标只描述该检测地址看到的出口，不代表同一地区的所有网站。
public enum ReferenceTarget: String, CaseIterable, Sendable {
    case domestic = "ip.3322.net"
    case overseas = "checkip.amazonaws.com"
    case cloudflare = "www.cloudflare.com"

    public var title: String {
        switch self {
        case .domestic: return "国内参考 · 3322"
        case .overseas: return "海外参考 · AWS"
        case .cloudflare: return "Cloudflare 参考"
        }
    }

    public var url: URL {
        URL(string: "https://\(rawValue)\(self == .cloudflare ? "/cdn-cgi/trace" : "/")")!
    }

    public func parse(_ data: Data, milliseconds: Int) throws -> Endpoint {
        let text = String(decoding: data, as: UTF8.self)
        if self == .cloudflare {
            return try TraceParser.parse(text, host: rawValue, milliseconds: milliseconds)
        }
        let ip = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard TraceParser.validIP(ip) else { throw ProbeFailure.invalid("检测来源未返回有效出口 IP") }
        return Endpoint(host: rawValue, ip: ip, milliseconds: milliseconds)
    }
}
