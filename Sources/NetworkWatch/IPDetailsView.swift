import SwiftUI
import WatchCore

struct IPDetailsView: View {
    @ObservedObject var model: WatchModel
    @State private var ipv6: LocalIPv6Status?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let latest = model.latest {
                    ForEach(latest.endpoints, id: \.host) { endpoint in
                        GroupBox("\(endpoint.displayName)出口") {
                            VStack(alignment: .leading, spacing: 9) {
                                row("出口 IP", endpoint.ip ?? "未知")
                                if let error = endpoint.error { row("检测状态", error).foregroundStyle(.orange) }
                                if let ip = endpoint.ip, let geo = latest.geo[ip] {
                                    row("归属地", GeoPresentation.location(geo))
                                    row("邮政编码", geo.postal.flatMap { $0.isEmpty ? nil : $0 } ?? "未知")
                                    row("ASN", "AS\(geo.asn)")
                                    row("运营商", geo.isp)
                                    row("出口时区", GeoPresentation.timezone(geo.timezone, at: latest.date))
                                    if let identifier = geo.timezone, let zone = TimeZone(identifier: identifier) {
                                        let minutes = (zone.secondsFromGMT(for: latest.date) - TimeZone.current.secondsFromGMT(for: latest.date)) / 60
                                        let difference = "\(abs(minutes) / 60) 小时\(abs(minutes) % 60 == 0 ? "" : " \(abs(minutes) % 60) 分钟")"
                                        row("与本机时差", minutes == 0 ? "当前 UTC 偏移相同" : "出口比本机\(minutes > 0 ? "快" : "慢") \(difference)")
                                    }
                                } else {
                                    Text(model.saved.settings.geoEnabled ? "归属地未知：\(endpoint.ip.flatMap { latest.geoErrors[$0] } ?? "未获取数据")" : "属性查询未启用")
                                        .foregroundStyle(.secondary)
                                }
                                Divider()
                                if model.saved.settings.geoEnabled, let ip = endpoint.ip, let risk = latest.risks?[ip] {
                                    flag("VPN", risk.vpn)
                                    flag("公开代理", risk.proxy)
                                    flag("Tor", risk.tor)
                                    flag("机房 / 托管网络", risk.datacenter)
                                    flag("移动网络", risk.mobile)
                                    row("住宅 IP", "无法仅凭以上结果确定")
                                    Text("来源：ipquery.io · \(risk.checkedAt.formatted(date: .omitted, time: .standard))")
                                        .font(.caption).foregroundStyle(.secondary)
                                } else {
                                    Text(model.saved.settings.geoEnabled ? "IP 情报未知：\(endpoint.ip.flatMap { latest.riskErrors?[$0] } ?? "等待检测")" : "IP 情报查询未启用")
                                        .foregroundStyle(.secondary)
                                }
                            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    Text("归属地来源：ipwho.is，仅为大致位置，无法确定街道或门牌。情报库未标记不代表没有代理或绝对安全；这些结果不是 Claude 或 ChatGPT 官方风控结论，暂不参与基准告警。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("出口来自本应用对相应网站的请求；浏览器若单独设置代理或按进程分流，实际出口可能不同。ChatGPT 网页出口不代表 OpenAI API 或 Codex 出口。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("等待新的出口检测结果…").foregroundStyle(.secondary)
                }
                GroupBox("本机系统环境") {
                    VStack(alignment: .leading, spacing: 9) {
                        if let ipv6 {
                            row("主网络 IPv6", ipv6.configurations.joined(separator: "\n"))
                            row("本机 IPv6 地址", ipv6.addresses)
                            HStack {
                                Text("本机读取于 \(ipv6.checkedAt.formatted(date: .omitted, time: .standard))")
                                    .font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("刷新 IPv6 状态") { self.ipv6 = LocalIPv6.inspect() }
                                    .font(.caption)
                            }
                            Text("地址检查包含隧道接口；本机状态不能代替浏览器的 IPv6／WebRTC 泄露检测。")
                                .font(.caption).foregroundStyle(.secondary)
                            Divider()
                        }
                        row("系统时区", GeoPresentation.timezone(TimeZone.current.identifier))
                        row("系统语言", Locale.preferredLanguages.map {
                            Locale(identifier: "zh_Hans_CN").localizedString(forIdentifier: $0) ?? $0
                        }.joined(separator: "、"))
                        Text("这是 macOS 设置，浏览器语言可能不同。时区或语言与出口不同，本身不代表异常。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }
                GroupBox("浏览器登录环境") {
                    VStack(alignment: .leading, spacing: 10) {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("登录前务必确认", systemImage: "exclamationmark.triangle.fill")
                                .font(.headline).foregroundStyle(.orange)
                            Text("登录时务必保持以下条件：").font(.subheadline.weight(.semibold))
                            Text("• 落地 IP 保持干净，无已知滥用或风险标记\n• 关闭 IPv6\n• DNS 解析正常，无泄露\n• 关闭 WebRTC")
                                .font(.subheadline).lineSpacing(5)
                            Text("请在实际登录 Claude 或 ChatGPT 的浏览器中逐项确认；以上为检查提醒，不代表已检测通过。")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                        Text("DNS、WebRTC、浏览器时区／语言、指纹，以及本应用未提供的爬虫与滥用记录，可在实际使用的浏览器中检测。下方链接针对 Claude，不能验证 ChatGPT 的出口路径。")
                            .font(.callout)
                        Link("查看Claude登录环境检测", destination: URL(string: "https://ip.net.coffee/claude/")!)
                        Text("链接由默认浏览器打开；如与实际使用的浏览器不同，请复制链接到对应浏览器。网页结果仅供参考。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(20)
        }.frame(width: 570, height: 640).textSelection(.enabled)
            .onReceive(model.$latest) { _ in ipv6 = LocalIPv6.inspect() }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title).foregroundStyle(.secondary).frame(width: 108, alignment: .leading)
            Text(value).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func flag(_ title: String, _ value: Bool?) -> some View {
        row(title, IPRisk.label(value)).foregroundStyle(value == true ? Color.orange : Color.primary)
    }
}
