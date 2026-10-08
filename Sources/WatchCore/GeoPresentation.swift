import Foundation

enum GeoParser {
    static func parse(_ data: Data, ip: String) throws -> Geo {
        struct Reply: Decodable {
            var ip: String
            var success: Bool
            var country_code: String
            var region: String?
            var city: String?
            var postal: String?
            struct Zone: Decodable { var id: String? }
            var timezone: Zone?
            struct Connection: Decodable { var asn: Int; var isp: String }
            var connection: Connection
        }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        guard reply.success, reply.ip == ip, reply.connection.asn > 0,
              reply.country_code.range(of: "^[A-Z]{2}$", options: .regularExpression) != nil else {
            throw ProbeFailure.invalid("IP 属性查询返回无效数据")
        }
        return Geo(ip: ip, country: reply.country_code, asn: reply.connection.asn, isp: reply.connection.isp,
                   region: reply.region, city: reply.city, postal: reply.postal, timezone: reply.timezone?.id)
    }
}

public enum GeoPresentation {
    public static func country(_ code: String?) -> String {
        guard let code, !code.isEmpty else { return "未知" }
        return Locale(identifier: "zh_Hans_CN").localizedString(forRegionCode: code) ?? code
    }

    public static func location(_ geo: Geo) -> String {
        var parts = [country(geo.country)]
        for value in [geo.region, geo.city].compactMap({ $0 }) where !value.isEmpty {
            let name = value.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? value
            if parts.last != name { parts.append(name) }
        }
        return parts.joined(separator: " · ")
    }

    public static func timezone(_ identifier: String?, at date: Date = Date()) -> String {
        guard let identifier, let zone = TimeZone(identifier: identifier) else { return "未知" }
        let seconds = zone.secondsFromGMT(for: date)
        let offset = String(format: "%@%02d:%02d", seconds >= 0 ? "+" : "−", abs(seconds) / 3600, abs(seconds) / 60 % 60)
        let name = zone.localizedName(for: .generic, locale: Locale(identifier: "zh_Hans_CN")) ?? identifier
        return "\(name)（UTC\(offset)）"
    }
}
