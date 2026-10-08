// 仅供 README 制图。示例模型不读写本地记录、不启动探测、不请求通知。
// 与实际 Dashboard / ExitComparisonView 一起单独编译，不属于应用 target。
#if IS_DEVTOOLS
import AppKit
import SwiftUI
import WatchCore

@MainActor
final class WatchModel: ObservableObject {
    @Published var saved = SavedState()
    @Published var latest: Snapshot?
    @Published var issues: [Issue] = []
    @Published var active: [Issue] = []
    let running = false
    let paused = false
    let sleeping = false
    let error: String? = nil
    let notifications = "已允许"
    var title: String { active.isEmpty ? "与基准一致" : "检测异常" }
    var icon: String { active.isEmpty ? "checkmark.shield.fill" : "exclamationmark.shield.fill" }
    var color: Color { active.isEmpty ? .green : .red }
    var canBaseline: Bool { true }
    func checkNow() {}
    func acceptBaseline(_ value: Snapshot) {}
    func togglePause() {}
    func enableNotifications() {}

    init(changed: Bool = false) {
        let date = ISO8601DateFormatter().date(from: "2026-01-01T01:41:00Z")!
        let ip = "203.0.113.10"
        let alternate = "198.51.100.20"
        let domestic = "192.0.2.30"
        let endpoints = Endpoint.monitoredHosts.enumerated().map { index, host in
            Endpoint(host: host, ip: changed && index == 2 ? alternate : ip,
                     country: "US", milliseconds: [218, 196, 205][index])
        }
        let sample = Snapshot(date: date, endpoints: endpoints, geo: [
            ip: Geo(ip: ip, country: "US", asn: 64500, isp: "示例运营商 A", checkedAt: date,
                    region: "示例州", city: "示例城市"),
            alternate: Geo(ip: alternate, country: "US", asn: 64500, isp: "示例运营商 A", checkedAt: date,
                           region: "示例州", city: "示例城市"),
            domestic: Geo(ip: domestic, country: "CN", asn: 64501, isp: "示例运营商 B", checkedAt: date,
                          region: "示例省", city: "示例城市")
        ], chains: ["api.anthropic.com: 示例落地 → 示例前置"], chainPaths: [
            "本机 → 前置节点：示例前置 → 落地节点：示例落地 → Claude API（api.anthropic.com）"
        ], referenceEndpoints: [
            Endpoint(host: ReferenceTarget.allCases[0].rawValue, ip: domestic, country: "CN", milliseconds: 32),
            Endpoint(host: ReferenceTarget.allCases[1].rawValue, ip: domestic, country: "CN", milliseconds: 186),
            Endpoint(host: ReferenceTarget.allCases[2].rawValue, ip: ip, country: "US", milliseconds: 204)
        ])
        latest = sample
        saved.baseline = sample
        saved.baseline!.endpoints = Endpoint.monitoredHosts.map { Endpoint(host: $0, ip: ip, country: "US") }
        saved.settings.chainEnabled = true
        if changed {
            issues = Comparison.issues(sample, baseline: saved.baseline, settings: saved.settings)
            active = issues
        }
    }
}

@MainActor
final class WindowRouter {
    static let shared = WindowRouter()
    func show(_ name: String) {}
}

struct PreviewFrame<Content: View>: View {
    let width: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach([Color.red, .yellow, .green], id: \.self) { color in
                    Circle().fill(color.opacity(0.8)).frame(width: 9, height: 9)
                }
                Spacer()
                Text("AI落地安全检测").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Color.clear.frame(width: 39, height: 9)
            }.padding(.horizontal, 16).padding(.vertical, 12)
            content
            HStack(spacing: 5) {
                Image(systemName: "eye.slash")
                Text("示例数据 · IP、地区与节点均非真实环境")
            }.font(.system(size: 10)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .background(Color.black.opacity(0.12))
        }.frame(width: width)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.10)))
            .padding(24)
            .background(Color(red: 0.07, green: 0.09, blue: 0.12))
            .environment(\.colorScheme, .dark)
            .environment(\.locale, Locale(identifier: "zh_CN"))
            .environment(\.timeZone, TimeZone(secondsFromGMT: 8 * 3600)!)
    }
}

@main
enum ReadmePreview {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let normal = WatchModel()
        try render(PreviewFrame(width: 420) { Dashboard(model: normal) },
                   to: directory.appendingPathComponent("dashboard.png"))
        try render(PreviewFrame(width: 420) { Dashboard(model: WatchModel(changed: true)) },
                   to: directory.appendingPathComponent("alert.png"))
        try render(PreviewFrame(width: 760) { ExitComparisonView(model: normal) },
                   to: directory.appendingPathComponent("comparison.png"))
    }

    @MainActor static func render<V: View>(_ view: V, to path: URL) throws {
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2),
            pixelsHigh: Int(size.height * 2), bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: path)
        print(path.lastPathComponent)
    }
}
#endif
