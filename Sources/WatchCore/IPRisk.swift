import Foundation

public struct IPRisk: Codable, Equatable, Sendable {
    public var vpn: Bool?
    public var proxy: Bool?
    public var tor: Bool?
    public var datacenter: Bool?
    public var mobile: Bool?
    public var checkedAt: Date

    public static func label(_ value: Bool?) -> String {
        switch value {
        case true: return "情报库已标记"
        case false: return "情报库未标记"
        case nil: return "未知"
        }
    }

    static func parse(_ data: Data, ip: String) throws -> IPRisk {
        struct Reply: Decodable {
            var ip: String
            struct Risk: Decodable {
                var is_vpn: Bool?
                var is_proxy: Bool?
                var is_tor: Bool?
                var is_datacenter: Bool?
                var is_mobile: Bool?
            }
            var risk: Risk
        }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        let risk = reply.risk
        guard reply.ip == ip,
              [risk.is_vpn, risk.is_proxy, risk.is_tor, risk.is_datacenter, risk.is_mobile].contains(where: { $0 != nil }) else {
            throw ProbeFailure.invalid("IP 情报查询返回无效数据")
        }
        return IPRisk(vpn: risk.is_vpn, proxy: risk.is_proxy, tor: risk.is_tor,
                      datacenter: risk.is_datacenter, mobile: risk.is_mobile, checkedAt: Date())
    }
}
