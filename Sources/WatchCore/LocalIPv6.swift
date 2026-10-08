import Foundation
import SystemConfiguration
import Darwin

public struct LocalIPv6Status: Sendable {
    public var configurations: [String]
    public var addresses: String
    public var checkedAt: Date
}

public enum LocalIPv6 {
    // 仅读取系统配置和接口地址，不改变网络服务，也不发送探测请求。
    public static func inspect() -> LocalIPv6Status {
        var configurations: [String] = []
        if let store = SCDynamicStoreCreate(nil, "NetworkWatchIPv6" as CFString, nil, nil),
           let preferences = SCPreferencesCreate(nil, "NetworkWatchIPv6" as CFString, nil) {
            var serviceIDs: Set<String> = []
            for family in ["IPv4", "IPv6"] {
                if let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/\(family)" as CFString) as? [String: Any],
                   let id = global["PrimaryService"] as? String { serviceIDs.insert(id) }
            }
            for id in serviceIDs.sorted() {
                guard let service = SCNetworkServiceCopy(preferences, id as CFString) else {
                    configurations.append("主网络服务：读取失败"); continue
                }
                let name = SCNetworkServiceGetName(service) as String? ?? "主网络服务"
                guard let protocols = SCNetworkServiceCopyProtocols(service) as? [SCNetworkProtocol] else {
                    configurations.append("\(name)：IPv6 状态未知"); continue
                }
                let protocol6 = protocols.first { SCNetworkProtocolGetProtocolType($0) as String? == "IPv6" }
                let enabled = protocol6.map { SCNetworkProtocolGetEnabled($0) } ?? false
                let config = protocol6.flatMap { SCNetworkProtocolGetConfiguration($0) as? [String: Any] }
                configurations.append("\(name)：\(configurationLabel(enabled: enabled, method: config?[kSCPropNetIPv6ConfigMethod as String] as? String))")
            }
        }
        if configurations.isEmpty { configurations = ["未知：未找到当前主网络服务"] }

        var addresses: [String] = []
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else {
            return LocalIPv6Status(configurations: configurations, addresses: "未知：无法读取接口地址", checkedAt: Date())
        }
        defer { freeifaddrs(interfaces) }
        var cursor = interfaces
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            let item = current.pointee
            guard item.ifa_flags & UInt32(IFF_UP) != 0, item.ifa_flags & UInt32(IFF_RUNNING) != 0,
                  item.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  let address = item.ifa_addr, address.pointee.sa_family == UInt8(AF_INET6) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                addresses.append(String(cString: host))
            }
        }
        return LocalIPv6Status(configurations: configurations, addresses: addressSummary(addresses), checkedAt: Date())
    }

    static func configurationLabel(enabled: Bool?, method: String?) -> String {
        guard let enabled else { return "IPv6 状态未知" }
        guard enabled else { return "IPv6 已关闭" }
        switch method {
        case "Automatic": return "IPv6 已开启（自动配置）"
        case "Manual": return "IPv6 已开启（手动配置）"
        case "RouterAdvertisement": return "IPv6 已开启（路由通告）"
        case "6to4": return "IPv6 已开启（6to4）"
        case "LinkLocal": return "仅链路本地（未完全关闭）"
        default: return "IPv6 协议已启用，配置方式未知"
        }
    }

    static func addressSummary(_ addresses: [String]) -> String {
        var global = 0, local = 0, other = 0
        for value in addresses {
            var address = in6_addr()
            let ip = String(value.split(separator: "%")[0])
            guard inet_pton(AF_INET6, ip, &address) == 1 else { continue }
            let bytes = withUnsafeBytes(of: address) { Array($0) }
            if bytes[0] & 0xE0 == 0x20 { global += 1 }
            else if (bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80) || bytes[0] & 0xFE == 0xFC { local += 1 }
            else { other += 1 }
        }
        if global > 0 { return "发现 \(global) 个全局单播地址；公网连通性尚未验证" }
        if other > 0 { return "存在其他 IPv6 地址；公网连通性未知" }
        if local > 0 { return "仅发现链路本地／局域网地址，未发现全局单播地址" }
        return "未发现活动接口的 IPv6 地址；不等于设置已关闭"
    }
}
