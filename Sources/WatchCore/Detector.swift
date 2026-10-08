import Foundation
import Darwin

private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public actor Detector {
    private let session: URLSession
    private var cache: [String: Geo] = [:]
    private var retryAfter: [String: Date] = [:]
    private var riskCache: [String: IPRisk] = [:]
    private var riskRetryAfter: [String: Date] = [:]
    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 12
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
    }

    private func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw ProbeFailure.invalid("缺少 HTTP 响应") }
        guard http.statusCode == 200 else { throw ProbeFailure.invalid("HTTP \(http.statusCode)") }
        guard data.count <= 128_000 else { throw ProbeFailure.invalid("响应超出预期大小") }
        return data
    }

    private func probe(_ host: String) async -> Endpoint {
        let start = ContinuousClock.now
        do {
            let data = try await get(URL(string: "https://\(host)/cdn-cgi/trace")!)
            let seconds = start.duration(to: .now).components
            let milliseconds = Int(seconds.seconds * 1000 + seconds.attoseconds / 1_000_000_000_000_000)
            return try TraceParser.parse(String(decoding: data, as: UTF8.self), host: host, milliseconds: milliseconds)
        } catch { return Endpoint(host: host, error: Self.describe(error)) }
    }

    private func probeReference(_ target: ReferenceTarget) async -> Endpoint {
        let start = ContinuousClock.now
        do {
            let data = try await get(target.url)
            let elapsed = start.duration(to: .now).components
            let milliseconds = Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000)
            return try target.parse(data, milliseconds: milliseconds)
        } catch { return Endpoint(host: target.rawValue, error: Self.describe(error)) }
    }

    public static func describe(_ error: Error) -> String {
        if let failure = error as? ProbeFailure { return failure.localizedDescription }
        if let error = error as? URLError {
            switch error.code {
            case .timedOut: return "连接超时"
            case .notConnectedToInternet: return "网络未连接"
            case .cannotFindHost, .dnsLookupFailed: return "DNS 解析失败"
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot: return "TLS / 证书验证失败"
            case .cancelled: return "检测已取消"
            default: return "网络请求失败（\(error.code.rawValue)）"
            }
        }
        return "数据解析或本地检测失败"
    }

    private func lookup(_ ip: String) async throws -> Geo {
        try Task.checkCancellation()
        if let cached = cache[ip], Date().timeIntervalSince(cached.checkedAt) < 900 { return cached }
        if let retry = retryAfter[ip], retry > Date() { throw ProbeFailure.invalid("属性查询暂不可用，冷却后重试") }
        do {
            let url = URL(string: "https://ipwho.is/\(ip)?lang=zh-CN&fields=ip,success,country_code,region,city,postal,timezone.id,connection")!
            let data = try await get(url)
            let geo = try GeoParser.parse(data, ip: ip)
            cache = cache.filter { Date().timeIntervalSince($0.value.checkedAt) < 900 }
            cache[ip] = geo; retryAfter[ip] = nil
            return geo
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            // 限流或服务失败时放慢重试，不使用已过期结果冒充当前数据。
            retryAfter = retryAfter.filter { $0.value > Date() }
            retryAfter[ip] = Date().addingTimeInterval(900)
            throw error
        }
    }

    private func lookupRisk(_ ip: String) async throws -> IPRisk {
        try Task.checkCancellation()
        if let cached = riskCache[ip], Date().timeIntervalSince(cached.checkedAt) < 900 { return cached }
        if let retry = riskRetryAfter[ip], retry > Date() { throw ProbeFailure.invalid("IP 情报暂不可用，冷却后重试") }
        do {
            let data = try await get(URL(string: "https://api.ipquery.io/\(ip)")!)
            let risk = try IPRisk.parse(data, ip: ip)
            riskCache = riskCache.filter { Date().timeIntervalSince($0.value.checkedAt) < 900 }
            riskCache[ip] = risk; riskRetryAfter[ip] = nil
            return risk
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            riskRetryAfter = riskRetryAfter.filter { $0.value > Date() }
            riskRetryAfter[ip] = Date().addingTimeInterval(900)
            throw error
        }
    }

    public func collect(settings: WatchSettings) async -> Snapshot {
        async let web = probe("claude.ai")
        async let api = probe("api.anthropic.com")
        async let chatgpt = probe("chatgpt.com")
        async let domestic = probeReference(.domestic)
        async let overseas = probeReference(.overseas)
        async let cloudflare = probeReference(.cloudflare)
        // 在探测请求尚在进行时采集连接，避免仅靠出口 IP 推断中转节点。
        async let chain = ChainReader.observe(enabled: settings.chainEnabled, socketPath: settings.socketPath)
        let endpoints = await [web, api, chatgpt]
        let references = await [domestic, overseas, cloudflare]
        var geo: [String: Geo] = [:], errors: [String: String] = [:]
        var risks: [String: IPRisk] = [:], riskErrors: [String: String] = [:]
        if settings.geoEnabled {
            for ip in Set(endpoints.compactMap(\.ip)) {
                async let location = lookup(ip)
                async let reputation = lookupRisk(ip)
                do { geo[ip] = try await location } catch { errors[ip] = Self.describe(error) }
                do { risks[ip] = try await reputation } catch { riskErrors[ip] = Self.describe(error) }
            }
            // 参考出口只补充归属地；相同 IP 复用本轮数据，不重复查询或参与告警。
            for ip in Set(references.compactMap(\.ip)).subtracting(Set(endpoints.compactMap(\.ip))) {
                do { geo[ip] = try await lookup(ip) } catch { errors[ip] = Self.describe(error) }
            }
        }
        let observed = await chain
        return Snapshot(endpoints: endpoints, geo: geo, geoErrors: errors, chains: observed.chains, chainError: observed.error, chainPaths: observed.paths, risks: risks, riskErrors: riskErrors, referenceEndpoints: references)
    }
}

public enum ChainReader {
    public static func configurationError(socketPath: String) -> String? {
        guard socketPath.hasPrefix("/"),
              let attributes = try? FileManager.default.attributesOfItem(atPath: socketPath),
              attributes[.type] as? FileAttributeType == .typeSocket else {
            return "未找到可访问的 Mihomo 本地 socket，请填写有效路径后再启用链路观察。"
        }
        return nil
    }

    public static func suggestedSocket(configuredPath: String = "") -> String {
        // 优先保留仍然有效的手动路径，再识别新版服务为当前用户创建的接口。
        let serviceSocket = "/var/run/clash-verge-service/users/\(getuid())/verge-mihomo.sock"
        var candidates = [configuredPath, serviceSocket]
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/io.github.clash-verge-rev.clash-verge-rev")
        if let text = try? String(contentsOf: root.appendingPathComponent("clash-verge.yaml"), encoding: .utf8),
           let line = text.split(separator: "\n").first(where: { $0.hasPrefix("external-controller-unix:") }) {
            candidates.append(String(line.dropFirst("external-controller-unix:".count)).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")))
        }
        candidates.append(NSTemporaryDirectory() + "verge-mihomo.sock")
        return candidates.first { configurationError(socketPath: $0) == nil }
            ?? (configuredPath.isEmpty ? serviceSocket : configuredPath)
    }

    private static func read(socketPath: String, endpoint: String) throws -> Data {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = ["--silent", "--fail", "--noproxy", "*", "--max-time", "2", "--unix-socket", socketPath, "http://localhost/\(endpoint)"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ProbeFailure.invalid("Mihomo 只读连接查询失败") }
        return data
    }

    public static func observe(enabled: Bool, socketPath: String) async -> (chains: [String]?, paths: [String]?, error: String?) {
        guard enabled else { return (nil, nil, nil) }
        if let error = configurationError(socketPath: socketPath) { return (nil, nil, error) }
        return await Task.detached {
            var chains: Set<String> = []
            do {
                for _ in 0..<4 {
                    let data = try read(socketPath: socketPath, endpoint: "connections")
                    struct Reply: Decodable {
                        struct Connection: Decodable {
                            struct Metadata: Decodable { var host: String }
                            var metadata: Metadata; var chains: [String]
                        }
                        var connections: [Connection]
                    }
                    let reply = try JSONDecoder().decode(Reply.self, from: data)
                    for connection in reply.connections where ["claude.ai", "api.anthropic.com"].contains(connection.metadata.host) && !connection.chains.isEmpty {
                        chains.insert(connection.metadata.host + ": " + connection.chains.joined(separator: " → "))
                    }
                    try await Task.sleep(nanoseconds: 200_000_000)
                }
                let complete = ["claude.ai", "api.anthropic.com"].allSatisfy { host in chains.contains { $0.hasPrefix(host + ": ") } }
                guard complete else { return (nil, nil, "未完整捕获网页和 API 活动连接，链路未知") }
                struct ProxiesReply: Decodable { var proxies: [String: ProxyRouteInfo] }
                // 只读补充展示信息；无法补充时明确显示未知，不影响原始链路监测。
                let proxies = try? JSONDecoder().decode(ProxiesReply.self, from: read(socketPath: socketPath, endpoint: "proxies")).proxies
                let ordered = chains.sorted()
                return (ordered, ordered.map { ChainPresentation.describe($0, proxies: proxies) }, nil)
            } catch { return (nil, nil, Detector.describe(error)) }
        }.value
    }
}
