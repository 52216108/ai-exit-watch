import SwiftUI
import AppKit
import WatchCore

struct Dashboard: View {
    @ObservedObject var model: WatchModel
    @State private var candidate: Snapshot?
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if let sample = model.latest {
                if let ip = sharedIP(in: sample) {
                    sharedExit(ip, sample: sample)
                } else {
                    separateExits(sample)
                }
                chain(sample)
            } else {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("正在采集出口信息…").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, minHeight: 110)
            }
            notices
            HStack(spacing: 10) {
                Button { model.checkNow() } label: {
                    Label(model.running ? "检测中…" : "立即检测", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent)
                    .disabled(model.running || model.paused || model.sleeping)
                Button(model.saved.baseline == nil ? "确认正常基准…" : "更新基准…") {
                    candidate = model.latest; confirming = true
                }.buttonStyle(.bordered).disabled(!model.canBaseline)
            }.controlSize(.large).buttonBorderShape(.roundedRectangle)
            HStack(spacing: 10) {
                destination("出口详情", icon: "info.circle", window: "details")
                destination("多出口对照", icon: "square.grid.2x2", window: "comparison")
                destination("出口锁定", icon: "lock.shield", window: "exit-lock")
            }
            Button {
                NSWorkspace.shared.open(URL(string: "https://ip.net.coffee/claude/")!)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "safari")
                    Text("查看 Claude 登录环境")
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }.buttonStyle(.plain).help("在默认浏览器打开 Net.Coffee 的 Claude 登录环境检测")
            Divider()
            footer
        }.padding(20).frame(width: 420)
            .fixedSize(horizontal: false, vertical: true)
            .alert("将以下结果作为正常基准？", isPresented: $confirming) {
                Button("取消", role: .cancel) {}
                Button("确认") { if let candidate { model.acceptBaseline(candidate) } }
            } message: {
                Text((candidate?.endpoints.map { "\($0.host)\n\($0.ip ?? "未知") · \(GeoPresentation.country($0.country))" }.joined(separator: "\n\n") ?? "") + "\n\n这会替换旧基准；后续变化将与此比较。")
            }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: model.icon)
                .font(.system(size: 24, weight: .medium)).foregroundStyle(model.color)
                .frame(width: 44, height: 44)
                .background(model.color.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 5) {
                Text(model.title).font(.system(size: 18, weight: .semibold))
                HStack(spacing: 5) {
                    if let sample = model.latest {
                        Text(sample.date.formatted(date: .omitted, time: .standard))
                        Text("更新 · 每 \(Int(model.saved.settings.interval)) 秒")
                    } else { Text("AI落地安全检测") }
                }.font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if model.running { ProgressView().controlSize(.small) }
        }
    }

    // 仅全部目标成功且 IP 相同才合并展示，失败和不同出口始终逐项显示。
    private func sharedIP(in sample: Snapshot) -> String? {
        guard sample.hasAllTargets,
              sample.endpoints.allSatisfy({ $0.error == nil && $0.ip != nil }),
              Set(sample.endpoints.compactMap(\.ip)).count == 1 else { return nil }
        return sample.endpoints.first?.ip
    }

    private func sharedExit(_ ip: String, sample: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("当前落地 IP").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Text("\(sample.endpoints.count) 个目标 · 同一出口").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Text(ip).font(.system(size: 26, weight: .medium, design: .monospaced))
                .lineLimit(1).minimumScaleFactor(0.55).textSelection(.enabled)
            metadata(ip: ip, sample: sample)
            Divider().padding(.vertical, 1)
            VStack(spacing: 11) {
                ForEach(sample.endpoints, id: \.host) { endpoint in
                    HStack {
                        Text(endpoint.displayName).font(.system(size: 12, weight: .medium))
                        Spacer()
                        latency(endpoint)
                    }
                }
            }
        }.padding(15)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
    }

    private func separateExits(_ sample: Snapshot) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(sample.endpoints.enumerated()), id: \.element.host) { index, endpoint in
                if index > 0 { Divider().padding(.horizontal, 14) }
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text(endpoint.displayName).font(.system(size: 12, weight: .semibold))
                        Spacer()
                        latency(endpoint)
                    }
                    Text(endpoint.ip ?? "未获取出口 IP")
                        .font(.system(size: 17, weight: .medium, design: .monospaced))
                        .lineLimit(1).minimumScaleFactor(0.65).textSelection(.enabled)
                    if let error = endpoint.error {
                        Text(error).font(.system(size: 11)).foregroundStyle(.orange)
                    } else if let ip = endpoint.ip {
                        metadata(ip: ip, sample: sample)
                    }
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
    }

    private func metadata(ip: String, sample: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let geo = sample.geo[ip] {
                let locality = [geo.city, geo.region].compactMap { $0 }.first { !$0.isEmpty }
                let place = locality?.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? locality
                Text([GeoPresentation.country(geo.country), place].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 12))
                Text("AS\(String(geo.asn)) · \(geo.isp)")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).help(geo.isp)
            } else {
                let countries = Set(sample.endpoints.filter { $0.ip == ip }.map { GeoPresentation.country($0.country) }).sorted()
                Text("探测地区：\(countries.joined(separator: "、"))")
                    .font(.system(size: 12))
                Text(model.saved.settings.geoEnabled ? "IP 归属地未知 · 查看出口详情" : "归属地查询未启用")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }.textSelection(.enabled)
    }

    private func latency(_ endpoint: Endpoint) -> some View {
        HStack(spacing: 5) {
            if endpoint.error != nil { Image(systemName: "exclamationmark.circle") }
            Text(endpoint.milliseconds.map { "\($0) ms" } ?? "未连通").monospacedDigit()
        }.font(.system(size: 11))
            .foregroundStyle(endpoint.error != nil || (endpoint.milliseconds ?? 0) > model.saved.settings.slowMilliseconds ? Color.orange : Color.secondary)
    }

    private func chain(_ sample: Snapshot) -> some View {
        let path = sample.chainPaths?.first { $0.hasSuffix("Claude API（api.anthropic.com）") }
        let raw = sample.chains?.first { $0.hasPrefix("api.anthropic.com: ") }
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label("Claude API 链路", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Text("Mihomo").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Text(model.saved.settings.chainEnabled ? (path ?? raw ?? sample.chainError ?? "未捕获链路") : "未启用 · 在设置中接入本地 socket")
                .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                .help("前置节点按当前运行配置补充；仅观察，不修改代理。")
        }
    }

    @ViewBuilder private var notices: some View {
        if let error = model.error {
            Text(error).font(.caption).foregroundStyle(.red)
        }
        let visible = model.issues.isEmpty ? model.active : model.issues
        if !visible.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(visible, id: \.id) { Text($0.message).font(.caption).foregroundStyle(.orange) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: min(CGFloat(visible.count) * 32, 96))
        }
        if model.saved.baseline == nil {
            Text("确认当前出口符合预期后，保存为正常基准。")
                .font(.caption).foregroundStyle(.secondary)
        } else if let baseline = model.saved.baseline, !baseline.missingBaselineNames.isEmpty {
            Text("\(baseline.missingBaselineNames.joined(separator: "、")) 尚未设置基准，更新基准后启用变化提醒。")
                .font(.caption).foregroundStyle(.orange)
        }
    }

    private func destination(_ title: String, icon: String, window: String) -> some View {
        Button { WindowRouter.shared.show(window) } label: {
            HStack(spacing: 7) {
                Image(systemName: icon).foregroundStyle(.secondary)
                Text(title).lineLimit(1).minimumScaleFactor(0.85)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
            }.font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 11).padding(.vertical, 11)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Label("通知\(model.notifications == "已允许" ? "已开启" : "：" + model.notifications)", systemImage: "bell")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            if model.notifications == "尚未授权" {
                Button("开启") { model.enableNotifications() }.font(.system(size: 10))
            }
            Spacer(minLength: 0)
            Button { WindowRouter.shared.show("history") } label: { Image(systemName: "clock.arrow.circlepath") }.help("检测历史").accessibilityLabel("检测历史")
            Button { WindowRouter.shared.show("settings") } label: { Image(systemName: "slider.horizontal.3") }.help("设置").accessibilityLabel("设置")
            Button { model.togglePause() } label: { Image(systemName: model.paused ? "play.fill" : "pause.fill") }.help(model.paused ? "继续检测" : "暂停检测").accessibilityLabel(model.paused ? "继续检测" : "暂停检测")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .help("退出 AI落地安全检测").accessibilityLabel("退出 AI落地安全检测")
        }.font(.system(size: 12)).buttonStyle(.plain).foregroundStyle(.secondary)
    }
}
