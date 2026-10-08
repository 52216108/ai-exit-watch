import SwiftUI
import AppKit
import UserNotifications
import ServiceManagement
import WatchCore

final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }
}

@MainActor
final class WatchModel: ObservableObject {
    static let shared = WatchModel()
    @Published var saved = SavedState()
    @Published var latest: Snapshot?
    @Published var issues: [Issue] = []
    @Published var active: [Issue] = []
    @Published var running = false
    @Published var paused = false
    @Published var sleeping = false
    @Published var error: String?
    @Published var notifications = "检查中"
    @Published var loginEnabled = false
    @Published var loginText = ""
    private let detector = Detector()
    private let store = Store()
    private var machine = AlertMachine()
    private var loop: Task<Void, Never>?
    private var generation = UUID()
    private var observers: [NSObjectProtocol] = []
    private var storageOK = true
    private let notificationDelegate = NotificationDelegate()

    init() {
        do { saved = try store.read() }
        catch { storageOK = false; self.error = "本地记录无法读取，已保留原文件；修复前不会覆盖，也无法保存基准。" }
        saved.settings.socketPath = ChainReader.suggestedSocket(configuredPath: saved.settings.socketPath)
        UNUserNotificationCenter.current().delegate = notificationDelegate
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sleeping = true; self?.stop() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sleeping = false; self?.start() }
        })
        refreshLogin()
        Task { await refreshNotifications() }
        start()
    }

    var title: String {
        if sleeping { return "休眠暂停" }
        if paused { return "监控已暂停" }
        if error != nil { return "需要处理" }
        if !active.isEmpty { return "检测异常" }
        if !issues.isEmpty { return "异常待复核" }
        if saved.baseline == nil { return "待确认正常基准" }
        if latest == nil { return "正在检测" }
        if let baseline = saved.baseline, !baseline.missingBaselineNames.isEmpty { return "新增出口待确认基准" }
        return "与基准一致"
    }
    var icon: String {
        if paused || sleeping { return "pause.circle" }
        if error != nil || !active.isEmpty { return "exclamationmark.shield.fill" }
        if saved.baseline == nil || saved.baseline?.missingBaselineNames.isEmpty == false || !issues.isEmpty || latest == nil { return "shield.lefthalf.filled" }
        return "checkmark.shield.fill"
    }
    var color: Color {
        if paused || sleeping { return .secondary }
        if error != nil || !active.isEmpty { return .red }
        return saved.baseline == nil || saved.baseline?.missingBaselineNames.isEmpty == false || !issues.isEmpty || latest == nil ? .orange : .green
    }
    var canBaseline: Bool {
        guard storageOK, !paused, !sleeping, let latest else { return false }
        return Date().timeIntervalSince(latest.date) < max(120, saved.settings.interval * 2) && latest.canBaseline(settings: saved.settings)
    }

    private func persist() {
        guard storageOK else { return }
        do { try store.write(saved) }
        catch { self.error = "无法保存本地记录，请检查磁盘空间和目录权限。" }
    }
    private func stop() {
        generation = UUID(); loop?.cancel(); loop = nil; running = false
        machine.resetPending()
    }
    func start() {
        stop()
        guard !paused, !sleeping else { return }
        let token = generation
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.generation == token else { return }
                let started = Date()
                await self.check(token: token)
                guard !Task.isCancelled, self.generation == token else { return }
                let delay = max(1, self.saved.settings.interval - Date().timeIntervalSince(started))
                do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
            }
        }
    }
    func checkNow() { guard !running, !paused, !sleeping else { return }; start() }
    func togglePause() { paused.toggle(); start() }

    private func check(token: UUID) async {
        running = true
        let sample = await detector.collect(settings: saved.settings)
        guard token == generation, !Task.isCancelled else { return }
        latest = sample; running = false
        issues = Comparison.issues(sample, baseline: saved.baseline, settings: saved.settings)
        let events = machine.consume(issues)
        active = machine.active.values.sorted { $0.id < $1.id }
        saved.samples.append(sample)
        saved.samples = Array(saved.samples.suffix(1440))
        saved.events.append(contentsOf: events)
        saved.events = Array(saved.events.suffix(500))
        persist()
        await refreshNotifications()
        guard token == generation, !Task.isCancelled else { return }
        for event in events { await notify(event) }
    }

    func acceptBaseline(_ candidate: Snapshot) {
        guard storageOK, canBaseline, candidate.date == latest?.date else { error = "检测结果已更新，请重新查看并确认基准。"; return }
        var proposed = saved
        proposed.baseline = candidate
        proposed.events.append(AlertEvent(title: "已手动更新正常基准", message: candidate.endpoints.map { "\($0.host)：\($0.ip ?? "未知")" }.joined(separator: "\n")))
        do { try store.write(proposed) }
        catch { self.error = "基准保存失败，原基准保持不变。"; return }
        saved = proposed; machine = AlertMachine(); active = []
        issues = Comparison.issues(candidate, baseline: candidate, settings: saved.settings)
        error = nil
    }

    func apply(_ settings: WatchSettings) -> Bool {
        guard storageOK else { return false }
        if settings.chainEnabled, let message = ChainReader.configurationError(socketPath: settings.socketPath) {
            error = message
            return false
        }
        var proposed = saved
        if settings.geoEnabled != saved.settings.geoEnabled || settings.chainEnabled != saved.settings.chainEnabled || settings.socketPath != saved.settings.socketPath {
            proposed.baseline = nil
            proposed.events.append(AlertEvent(title: "检测范围已调整", message: "请重新确认正常基准。"))
        }
        proposed.settings = settings
        do { try store.write(proposed) } catch { self.error = "设置保存失败，原设置保持不变。"; return false }
        saved = proposed; machine = AlertMachine(); active = []; issues = []; latest = nil; error = nil
        start(); return true
    }

    func refreshNotifications() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            notifications = settings.alertSetting == .enabled ? "已允许" : "横幅已关闭"
            if error == "无法请求系统通知权限。" { error = nil }
        case .denied: notifications = "系统已禁止"
        default: notifications = "尚未授权"
        }
    }
    func enableNotifications() {
        Task {
            do { _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
            catch { self.error = "无法请求系统通知权限。" }
            await refreshNotifications()
        }
    }
    func testNotification() {
        Task { await notify(AlertEvent(title: "AI落地安全检测 测试通知", message: "通知通道可用。真实异常将连续两次确认后提醒。")); await refreshNotifications() }
    }
    private func notify(_ event: AlertEvent) async {
        let content = UNMutableNotificationContent()
        content.title = event.title
        // 锁屏通知只显示事件摘要；出口 IP、节点名称留在本机界面和历史中。
        content.body = event.title.contains("测试") ? event.message : "请点击菜单栏盾牌查看详情。"
        content.sound = .default
        do { try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: event.id.uuidString, content: content, trigger: nil)) }
        catch { notifications = "通知发送失败，请检查权限" }
    }
    func refreshLogin() {
        loginEnabled = SMAppService.mainApp.status == .enabled
        loginText = SMAppService.mainApp.status == .requiresApproval ? "需要在系统设置中允许" : ""
    }
    func setLogin(_ enabled: Bool) {
        do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { self.error = "登录启动设置失败：请检查系统设置中的登录项。" }
        refreshLogin()
    }
}

@MainActor
final class WindowRouter {
    static let shared = WindowRouter()
    private var windows: [String: NSWindow] = [:]
    func show(_ id: String) {
        if let window = windows[id] { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let model = WatchModel.shared
        let content: AnyView
        let title: String
        switch id {
        case "settings": content = AnyView(SettingsView(model: model)); title = "AI落地安全检测 设置"
        case "history": content = AnyView(HistoryView(model: model)); title = "AI落地安全检测 历史"
        case "details": content = AnyView(IPDetailsView(model: model)); title = "AI落地安全检测 出口详情"
        case "comparison": content = AnyView(ExitComparisonView(model: model)); title = "AI落地安全检测 多出口对照"
        case "exit-lock": content = AnyView(ExitLockView(model: model)); title = "AI落地安全检测 出口锁定"
        default: content = AnyView(Dashboard(model: model)); title = "AI落地安全检测"
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: content))
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center(); window.makeKeyAndOrderFront(nil)
        windows[id] = window
        NSApp.activate(ignoringOtherApps: true)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if !UserDefaults.standard.bool(forKey: "welcomeShown") || CommandLine.arguments.contains("--show-window") {
            WindowRouter.shared.show("welcome")
            UserDefaults.standard.set(true, forKey: "welcomeShown")
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        WindowRouter.shared.show("welcome"); return false
    }
}

@main
struct NetworkWatchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = WatchModel.shared
    var body: some Scene {
        MenuBarExtra {
            Dashboard(model: model)
        } label: {
            Image(systemName: model.icon).renderingMode(.template).accessibilityLabel("AI落地安全检测：\(model.title)")
        }.menuBarExtraStyle(.window)
    }
}

struct SettingsView: View {
    @ObservedObject var model: WatchModel
    @State private var draft = WatchSettings()
    @State private var applied = false
    var body: some View {
        Form {
            Section("检测与通知") {
                Picker("检测间隔", selection: $draft.interval) {
                    Text("1 分钟").tag(60.0); Text("2 分钟").tag(120.0); Text("5 分钟").tag(300.0); Text("10 分钟").tag(600.0)
                }
                Picker("持续延迟告警", selection: $draft.slowMilliseconds) {
                    Text("超过 1 秒").tag(1000); Text("超过 3 秒").tag(3000); Text("超过 5 秒").tag(5000)
                }
                Text("异常和恢复均连续两次确认；同一异常持续期间只提醒一次。休眠暂停，唤醒立即检测。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("系统通知：\(model.notifications)")
                    Spacer()
                    Button("请求权限") { model.enableNotifications() }
                    Button("测试通知") { model.testNotification() }
                }
                Toggle("登录时启动", isOn: Binding(get: { model.loginEnabled }, set: { model.setLogin($0) }))
                if !model.loginText.isEmpty { Text(model.loginText).foregroundStyle(.orange) }
            }
            Section("出口锁定") {
                Button("配置指定出口或阻断…") { WindowRouter.shared.show("exit-lock") }
                Text("生成 Clash Verge Rev 专用保护脚本，由你导入后生效。只允许指定固定节点；失败停止连接，不自动切换其他出口。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("数据来源") {
                Toggle("查询中文归属地、ASN 与 IP 情报", isOn: $draft.geoEnabled)
                Text("启用后将探测到的公网 IP 发给 ipwho.is 查询归属地、发给 ipquery.io 查询 VPN／代理等情报，均使用 HTTPS；结果缓存 15 分钟。关闭后只检测出口、trace 地区与连通性。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("多出口对照每轮另访问 ip.3322.net、checkip.amazonaws.com 和 www.cloudflare.com，读取对方看到的公网 IP；参考出口仅查询归属地，不参与基准告警。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("观察 Mihomo 中的 Claude 活动连接链路", isOn: $draft.chainEnabled)
                if let message = ChainReader.configurationError(socketPath: draft.socketPath) {
                    Text("当前未接入：\(message)").font(.caption).foregroundStyle(.orange)
                }
                if draft.chainEnabled {
                    HStack {
                        TextField("本地 Unix socket 绝对路径", text: $draft.socketPath)
                        Button("自动查找") { draft.socketPath = ChainReader.suggestedSocket(configuredPath: draft.socketPath) }
                    }
                    Text("填写路径后点击“保存设置”才会生效。").font(.caption).foregroundStyle(.secondary)
                    Text("仅读取本地 /connections，不读取密码、不修改代理。连接捕获可能不完整；缺失会显示未知并告警，不能证明所有 Claude 请求的路由。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("更改数据来源后需要重新确认正常基准。连通检测不验证账户权限、模型服务或官方风控。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text("历史仅存本机：最近 1,440 次检测、500 条事件。通知隐藏 IP 和节点详情。后台检测不依赖 Net.Coffee；登录环境链接仅在点击时打开，也不调用模型。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("保存设置") { applied = model.apply(draft) }.buttonStyle(.borderedProminent)
                    if applied { Text("已保存").foregroundStyle(.secondary) }
                }
                if let error = model.error { Text(error).foregroundStyle(.red).font(.caption) }
            }
        }.formStyle(.grouped).padding(8).frame(minWidth: 510, minHeight: 490)
            .onAppear {
                draft = model.saved.settings
                draft.socketPath = ChainReader.suggestedSocket(configuredPath: draft.socketPath)
                model.refreshLogin(); Task { await model.refreshNotifications() }
            }
            .onChange(of: draft) { _ in applied = false }
    }
}

struct HistoryView: View {
    @ObservedObject var model: WatchModel
    var body: some View {
        TabView {
            List(model.saved.events.reversed()) { event in
                VStack(alignment: .leading, spacing: 5) {
                    HStack { Text(event.title).bold(); Spacer(); Text(event.date.formatted()).font(.caption).foregroundStyle(.secondary) }
                    Text(event.message).font(.caption).textSelection(.enabled)
                }.padding(.vertical, 4)
            }.overlay { if model.saved.events.isEmpty { Text("还没有事件").foregroundStyle(.secondary) } }.tabItem { Text("异常与事件") }
            List(model.saved.samples.reversed(), id: \.date) { sample in
                VStack(alignment: .leading, spacing: 4) {
                    Text(sample.date.formatted()).font(.caption).foregroundStyle(.secondary)
                    ForEach(sample.endpoints + (sample.referenceEndpoints ?? []), id: \.host) { endpoint in
                        Text("\(endpoint.host) · \(endpoint.ip ?? "未知") · \(endpoint.error ?? "\(endpoint.milliseconds ?? 0) ms")").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                    ForEach(sample.geoErrors.keys.sorted(), id: \.self) { ip in Text("属性查询：\(sample.geoErrors[ip] ?? "未知")").font(.caption).foregroundStyle(.orange) }
                    if let message = sample.chainError { Text(message).font(.caption).foregroundStyle(.orange) }
                }.padding(.vertical, 4)
            }.tabItem { Text("检测记录") }
        }.padding(14).frame(minWidth: 640, minHeight: 420)
    }
}
