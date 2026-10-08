import SwiftUI
import WatchCore

struct ExitComparisonView: View {
    @ObservedObject var model: WatchModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("多出口对照").font(.title2.bold())
                Spacer()
                if model.running { ProgressView().controlSize(.small) }
                Button("立即检测") { model.checkNow() }
                    .disabled(model.running || model.paused || model.sleeping)
            }
            Text("分别查看访问不同检测地址时的出口，沿用当前分流规则。不同 IP 不等于异常，也不代表同类网站都走这一出口。")
                .font(.callout).foregroundStyle(.secondary)
            if model.paused || model.sleeping {
                Text("监控已暂停，以下为上次检测结果。").font(.caption).foregroundStyle(.orange)
            }
            if let sample = model.latest {
                Text("检测于 \(sample.date.formatted(date: .omitted, time: .standard)) · 每 \(Int(model.saved.settings.interval)) 秒刷新")
                    .font(.caption).foregroundStyle(.secondary)
                let results = ReferenceTarget.allCases.map { target in
                    sample.referenceEndpoints?.first { $0.host == target.rawValue } ?? Endpoint(host: target.rawValue, error: "等待本轮检测")
                } + sample.endpoints
                ScrollView {
                    VStack(spacing: 14) {
                        ForEach(Array(stride(from: 0, to: results.count, by: 2)), id: \.self) { index in
                            HStack(alignment: .top, spacing: 14) {
                                card(results[index], sample: sample)
                                if index + 1 < results.count { card(results[index + 1], sample: sample) }
                            }
                        }
                    }
                }.frame(height: 480)
            } else {
                Text("正在采集出口结果…").frame(maxWidth: .infinity, minHeight: 480)
            }
            Text("国内／海外／Cloudflare 三项仅供对照，不参与基准告警。参考出口归属地沿用设置中的查询开关；关闭后仅显示 IP 和可取得的 trace 地区。")
                .font(.caption).foregroundStyle(.secondary)
            Text("Google 出口暂未接入可靠查询来源。上述参考结果不能代替 Google 的实际出口。")
                .font(.caption).foregroundStyle(.secondary)
            Text("此处测量本应用的网络路径；浏览器若单独配置代理或按进程分流，请在实际浏览器中核对。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(width: 760)
    }

    private func card(_ endpoint: Endpoint, sample: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(endpoint.displayName).font(.headline)
                Spacer()
                Text(endpoint.milliseconds.map { "\($0) ms" } ?? "未知")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(endpoint.ip ?? "未获取出口 IP")
                .font(.system(.title3, design: .monospaced)).textSelection(.enabled)
            if let error = endpoint.error {
                Text(error).font(.caption).foregroundStyle(.orange)
            } else if let ip = endpoint.ip, let geo = sample.geo[ip] {
                Text(GeoPresentation.location(geo)).font(.subheadline)
                Text("AS\(String(geo.asn)) · \(geo.isp)").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("地区：\(GeoPresentation.country(endpoint.country))").font(.subheadline)
                Text(model.saved.settings.geoEnabled ? "归属地未知：\(endpoint.ip.flatMap { sample.geoErrors[$0] } ?? "未获取数据")" : "归属地查询未启用")
                    .font(.caption).foregroundStyle(.secondary)
            }
            let source = ReferenceTarget(rawValue: endpoint.host)?.url.absoluteString ?? "https://\(endpoint.host)/cdn-cgi/trace"
            Text("来源：\(source)").font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }.padding(14).frame(maxWidth: .infinity, minHeight: 145, alignment: .topLeading)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }
}
