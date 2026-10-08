import SwiftUI
import AppKit
import UniformTypeIdentifiers
import WatchCore

struct ExitLockView: View {
    @ObservedObject var model: WatchModel
    @State private var socketPath = ""
    @State private var runtime: LockRuntime?
    @State private var landing = ""
    @State private var claude = true
    @State private var openAI = true
    @State private var busy = false
    @State private var error: String?
    @State private var exported = false
    @State private var verification: LockVerification?
    @State private var checkedAt: Date?

    private var planResult: Result<ExitLockPlan, Error>? {
        guard let runtime, !landing.isEmpty else { return nil }
        return Result { try ExitLockPlan(runtime: runtime, landing: landing, claude: claude, openAI: openAI) }
    }
    private var plan: ExitLockPlan? { try? planResult?.get() }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield").font(.system(size: 28)).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 5) {
                    Text("出口锁定").font(.title2.bold())
                    Text("只走指定节点，失败就停止连接").foregroundStyle(.secondary)
                }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    GroupBox("1 · 读取本机节点") {
                        VStack(alignment: .leading, spacing: 9) {
                            HStack {
                                TextField("Mihomo 本地 socket", text: $socketPath)
                                    .textFieldStyle(.roundedBorder).disabled(busy)
                                Button("读取") { refresh() }.disabled(busy)
                            }
                            if let runtime {
                                if runtime.candidates.isEmpty {
                                    Text("没有可用的固定节点链。自动选择组、链路不完整或尚不支持的节点类型不会列入。")
                                        .font(.caption).foregroundStyle(.orange)
                                } else {
                                    Picker("指定落地", selection: $landing) {
                                        Text("请选择固定节点").tag("")
                                        ForEach(runtime.candidates, id: \.self) { Text($0).tag($0) }
                                    }.disabled(busy)
                                }
                                if runtime.mode.lowercased() != "rule" {
                                    Text("当前不是规则模式；导入后仍需切到规则模式才能生效。")
                                        .font(.caption).foregroundStyle(.orange)
                                }
                            }
                            if let plan {
                                Text(plan.path).font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            } else if case .failure(let problem) = planResult {
                                Text(problem.localizedDescription).font(.caption).foregroundStyle(.orange)
                            }
                            Text("仅引用当前固定链路，不读取密码，不修改节点、TUN 或 DNS。通过代理集合提供的节点可能无法由脚本确认，届时会拒绝连接。")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GroupBox("2 · 选择保护范围并导出") {
                        VStack(alignment: .leading, spacing: 9) {
                            Toggle("Claude 网页与 Anthropic API", isOn: $claude).disabled(busy)
                            Toggle("ChatGPT 与 OpenAI（包括 API / Codex）", isOn: $openAI).disabled(busy)
                            if let plan {
                                Text("保护域名及其子域：" + plan.domains.joined(separator: "、"))
                                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            HStack {
                                Button("导出保护脚本…") { export() }
                                    .buttonStyle(.borderedProminent).disabled(plan == nil || busy)
                                if exported { Text("已导出 · 尚不代表生效").font(.caption).foregroundStyle(.secondary) }
                            }
                            Text("节点拨号失败时连接失败；节点缺失、类型或前置关系改变时改为 REJECT。不会检查服务商是否更换实际出口 IP。")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GroupBox("3 · 在 Clash Verge Rev 中启用") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("先备份当前订阅扩展脚本，再把导出的完整区块追加到该脚本末尾，保存并使订阅生效。原有 main 函数会先执行，已有代理链设置会保留。")
                            Text("再次导出时只替换带 BEGIN / END 标记的出口锁定区块。撤销时移除这个区块，重新应用订阅。不要覆盖整个原脚本。")
                            Text("启用后重新打开 AI 页面或客户端，让新连接使用新规则；已有连接不会由本工具关闭。")
                            Link("查看 Clash Verge 扩展脚本文档", destination: URL(string: "https://www.clashverge.dev/guide/extend.html")!)
                        }.font(.caption).foregroundStyle(.secondary)
                            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GroupBox("4 · 核验当前规则") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Button("检查生效情况") { verify() }.disabled(plan == nil || busy)
                                if let checkedAt { Text(checkedAt.formatted(date: .omitted, time: .standard)).font(.caption).foregroundStyle(.secondary) }
                            }
                            Text(verification?.message ?? "尚未核验 · 导出文件不会自动开启保护")
                                .font(.callout).foregroundStyle(verificationColor)
                            Text("这是手动读取时的配置核验，不是持续防火墙。只保护经过该 Mihomo 规则模式、匹配上方域名的新连接；绕过代理、切换模式、脚本停用及未列出的第三方域名不在保护范围。")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let error { Text(error).font(.callout).foregroundStyle(.red) }
                }.padding(.trailing, 4)
            }
        }.padding(20).frame(width: 590, height: 720)
            .onAppear {
                if socketPath.isEmpty { socketPath = ChainReader.suggestedSocket(configuredPath: model.saved.settings.socketPath); refresh() }
            }
            .onChange(of: landing) { _ in invalidate() }
            .onChange(of: claude) { _ in invalidate() }
            .onChange(of: openAI) { _ in invalidate() }
            .onChange(of: socketPath) { _ in runtime = nil; landing = ""; invalidate() }
    }

    private var verificationColor: Color {
        switch verification {
        case .fixed: return .blue
        case .rejected, .unverified: return .orange
        case nil: return .secondary
        }
    }
    private func invalidate() { verification = nil; checkedAt = nil; exported = false; error = nil }

    private func refresh() {
        busy = true; invalidate()
        let path = socketPath
        Task {
            defer { busy = false }
            do {
                let value = try await ExitLockReader.read(socketPath: path)
                runtime = value
                if !value.candidates.contains(landing) { landing = "" }
            } catch {
                runtime = nil; landing = ""; self.error = "读取失败：" + error.localizedDescription
            }
        }
    }

    private func export() {
        guard let plan else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "AI出口锁定.js"
        panel.allowedContentTypes = [.javaScript]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try plan.script().write(to: url, atomically: true, encoding: .utf8)
            exported = true; error = nil
        } catch { self.error = "导出失败，请检查目标目录权限。" }
    }

    private func verify() {
        guard let plan else { return }
        busy = true; verification = nil; checkedAt = nil; error = nil
        let path = socketPath
        Task {
            defer { busy = false }
            do {
                let current = try await ExitLockReader.read(socketPath: path)
                verification = plan.verify(current); checkedAt = Date()
            } catch { self.error = "核验失败，当前保护状态未知：" + error.localizedDescription }
        }
    }
}
