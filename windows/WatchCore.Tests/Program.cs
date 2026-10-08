using System.Net;
using System.IO.Pipes;
using System.Text;
using System.Text.Json;
using WatchCore;

var passed = 0;
void Test(string name, Action run)
{
    run(); passed++; Console.WriteLine("通过：" + name);
}
void Require(bool value, string description = "断言失败")
{
    if (!value) throw new Exception(description);
}
void Reject(Action action)
{
    try { action(); } catch (Exception e) when (e is InvalidDataException or ArgumentException) { return; }
    throw new Exception("无效输入未被拒绝");
}
Snapshot Sample(string ip = "203.0.113.7") => new() {
    Endpoints = Target.AI.Select(t => new Endpoint(t.Host, ip, "US", 200)).ToList(),
    Geo = new() { [ip] = new(ip, "US", 64500, "测试运营商", "测试州", "测试城市", null, "America/New_York") }
};
LockRuntime Runtime() => new("rule", new() {
    ["落地"] = new("Socks5", "前置"), ["前置"] = new("Socks5", ""),
    ["自动"] = new("Fallback", "", ["落地", "DIRECT"], "落地"),
    ["DIRECT"] = new("Direct", "")
}, []);
List<LockRule> Rules(ExitLockPlan p, string name) => p.Domains.SelectMany(d => new[] {
    new LockRule("DomainSuffix", d, name), new LockRule("DomainSuffix", d, "REJECT")
}).ToList();

Test("严格解析 IPv4 / IPv6 和 trace，不接受 HTML、缩写或缺字段", () => {
    foreach (var value in new[] { "203.0.113.9", "2001:db8::1" }) Require(TraceParser.ValidIP(value));
    foreach (var value in new[] { "123", "127.1", "0177.0.0.1", "0x7f.0.0.1", "::1%eth0", "999.1.1.1" }) Require(!TraceParser.ValidIP(value));
    Require(TraceParser.Parse("ip=203.0.113.9\nloc=US\n", Target.AI[0], 50).IP == "203.0.113.9");
    Reject(() => TraceParser.Parse("<html>blocked</html>", Target.AI[0], 5));
    Reject(() => TraceParser.Parse("ip=203.0.113.9\nloc=USA", Target.AI[0], 5));
    Reject(() => TraceParser.Parse("203.0.113.9 extra", Target.References[0], 5));
});
Test("属性与风险响应必须属于被查询 IP，未知不能变成否", () => {
    var raw = """{"success":true,"ip":"203.0.113.7","country_code":"US","connection":{"asn":64500,"isp":"test"},"timezone":{"id":"America/New_York"},"city":"华盛顿"}""";
    Require(Detector.ParseGeo(raw, "203.0.113.7").City == "华盛顿");
    Reject(() => Detector.ParseGeo(raw, "203.0.113.8"));
    Reject(() => Detector.ParseGeo(raw.Replace("64500", "0"), "203.0.113.7"));
    var r = Detector.ParseRisk("""{"ip":"203.0.113.7","risk":{"is_vpn":false,"is_proxy":true}}""", "203.0.113.7");
    Require(r.VPN == false && r.Proxy == true && r.Tor == null);
    Reject(() => Detector.ParseRisk("""{"ip":"203.0.113.7","risk":{}}""", "203.0.113.7"));
});
Test("基准需三项完整，参考失败不影响 AI 基准", () => {
    Require(Sample().CanBaseline(new()));
    Require(!Sample().CanBaseline(new(ChainEnabled: true)));
    Require(!(Sample() with { Endpoints = Sample().Endpoints.Take(2).ToList() }).CanBaseline(new()));
    Require(!(Sample() with { Geo = [] }).CanBaseline(new()));
    Require((Sample() with { References = [new("ip.3322.net", Error: "失败")] }).CanBaseline(new()));
});
Test("比较各目标 IP 和 ASN，参考来源不产生告警", () => {
    var sample = Sample("203.0.113.8") with { References = [new("ip.3322.net", Error: "失败")] };
    var issues = Comparison.Issues(sample, Sample(), new());
    Require(issues.Count == 3 && issues.All(i => i.ID.StartsWith("ip:")));
    sample.Geo["203.0.113.8"] = sample.Geo["203.0.113.8"] with { ASN = 64501 };
    Require(Comparison.Issues(sample, Sample(), new()).Count == 6);
});
Test("两次异常、去重与两次恢复，持续网络未知不能误报恢复", () => {
    var machine = new AlertMachine();
    List<Issue> issue = [new("ip:claude.ai", "IP 变化")];
    Require(machine.Consume(issue).Count == 0);
    Require(machine.Consume(issue).Count == 1);
    Require(machine.Consume(issue).Count == 0);
    machine.Consume([new("network:claude.ai", "失败")]);
    machine.Consume([new("network:claude.ai", "失败")]);
    Require(machine.Active.ContainsKey("ip:claude.ai"));
    machine.Consume([]);
    Require(machine.Active.ContainsKey("ip:claude.ai"));
    Require(machine.Consume([]).Count == 1 && machine.Active.Count == 0);
});
Test("归属地和链路未知阻止恢复，暂停重置待确认计数", () => {
    var machine = new AlertMachine();
    List<Issue> issue = [new("asn:claude.ai", "ASN"), new("chain:claude", "链路")];
    machine.Consume(issue); machine.Consume(issue);
    List<Issue> unknown = [new("geo-unavailable:claude.ai", "未知"), new("chain-unavailable", "未知")];
    machine.Consume(unknown); machine.Consume(unknown);
    Require(machine.Active.ContainsKey("asn:claude.ai") && machine.Active.ContainsKey("chain:claude"));
    var fresh = new AlertMachine(); fresh.Consume(issue); fresh.ResetPending();
    Require(fresh.Consume(issue).Count == 0);
});
Test("命名管道仅限本机，拒绝远程路径和路径注入", () => {
    Require(Mihomo.NormalizePipe(@"\\.\pipe\verge-mihomo") == "verge-mihomo");
    Require(Mihomo.NormalizePipe("verge-mihomo-sidecar-release-user1") == "verge-mihomo-sidecar-release-user1");
    foreach (var name in new[] { @"\\server\pipe\mihomo", "/tmp/pipe", "../pipe", "bad\npipe", "" })
        Reject(() => Mihomo.NormalizePipe(name));
});
Test("固定链拒绝策略组、未知前置、循环和规则分隔符", () => {
    var runtime = Runtime();
    Require(runtime.Candidates.SequenceEqual(new[] { "前置", "落地" }.Order()));
    Reject(() => new ExitLockPlan(runtime, "自动", true, true));
    Reject(() => new ExitLockPlan(runtime, "DIRECT", true, true));
    Reject(() => new ExitLockPlan(runtime, "落地", false, false));
    runtime.Proxies["前置"] = new("Socks5", "落地");
    Reject(() => runtime.Chain("落地"));
    runtime.Proxies["前置"] = new("Socks5");
    Reject(() => runtime.Chain("落地"));
    runtime = Runtime(); runtime.Proxies["bad,DIRECT"] = new("Socks5", "");
    Reject(() => new ExitLockPlan(runtime, "bad,DIRECT", true, true));
});
Test("核验必须是规则模式、置顶启用规则、相邻 REJECT 和相同物理链", () => {
    var runtime = Runtime();
    var plan = new ExitLockPlan(runtime, "落地", true, true);
    var rules = Rules(plan, "落地");
    Require(plan.Verify(runtime with { Rules = rules }).Status == "已配置固定节点");
    Require(plan.Verify(runtime with { Rules = Rules(plan, "REJECT") }).Status == "已配置拒绝");
    Require(plan.Verify(runtime with { Rules = rules, Mode = "global" }).Status == "未确认生效");
    Require(plan.Verify(runtime with { Rules = Rules(plan, "DIRECT") }).Status == "未确认生效");
    var disabled = rules.ToList(); disabled[0] = disabled[0] with { Extra = new(true) };
    Require(plan.Verify(runtime with { Rules = disabled }).Status == "未确认生效");
    var noGuard = rules.Where((_, i) => i % 2 == 0).ToList();
    Require(plan.Verify(runtime with { Rules = noGuard }).Status == "未确认生效");
    var directGuard = rules.ToList(); directGuard[1] = directGuard[1] with { Proxy = "DIRECT" };
    Require(plan.Verify(runtime with { Rules = directGuard }).Status == "未确认生效");
    runtime.Proxies["落地"] = new("Socks5", "");
    Require(plan.Verify(runtime with { Rules = rules }).Status == "未确认生效");
});
Test("本地原子存储往返，损坏文件和未知版本不得覆盖", () => {
    var dir = Path.Combine(Path.GetTempPath(), "ai-exit-tests-" + Guid.NewGuid());
    Directory.CreateDirectory(dir);
    try
    {
        var path = Path.Combine(dir, "state.json");
        var store = new StateStore(path);
        Require(store.Save(new() { Baseline = Sample(), Samples = [Sample()] }));
        Require(new StateStore(path).Load().Baseline!.Endpoints[0].IP == "203.0.113.7");
        foreach (var raw in new[] { "broken-json", """{"version":99}""", """{"version":1,"settings":null}""",
            """{"version":1,"samples":[{"endpoints":null}]}""" })
        {
            File.WriteAllText(path, raw);
            var damaged = new StateStore(path); damaged.Load();
            Require(damaged.Error != null && !damaged.Save(new()) && File.ReadAllText(path) == raw);
        }
    }
    finally { Directory.Delete(dir, true); }
});

var mock = new FixtureHandler();
using (var detector = new Detector(mock))
{
    var result = await detector.ProbeAsync(new(), CancellationToken.None);
    Test("生产探测流程隔离夹具：六来源、按 IP 共享缓存、参考失败独立", () => {
        Require(result.Endpoints.All(e => e.IP == "203.0.113.7") && result.Geo.Count == 1);
        Require(result.References[0].Error != null);
        Require(mock.GeoCalls == 1 && mock.RiskCalls == 1);
    });
    await detector.ProbeAsync(new(), CancellationToken.None);
    Test("成功 IP 情报缓存不会每分钟重复请求", () => Require(mock.GeoCalls == 1 && mock.RiskCalls == 1));
    var rejected = await detector.ProbeEndpointAsync(new("redirect", "测试", "https://redirect.test/"), CancellationToken.None);
    Test("HTTP 重定向和超大响应拒绝作为出口证据", () => Require(rejected.IP == null && rejected.Error!.Contains("302")));
    var tooBig = await detector.ProbeEndpointAsync(new("large", "测试", "https://large.test/"), CancellationToken.None);
    Require(tooBig.IP == null && tooBig.Error!.Contains("过大"));
    using var cancelled = new CancellationTokenSource(); cancelled.Cancel();
    try { await detector.ProbeAsync(new(), cancelled.Token); throw new Exception("取消未传播"); }
    catch (OperationCanceledException) { passed++; Console.WriteLine("通过：取消丢弃本轮结果"); }
}
using (var detector = new Detector(new FixtureHandler { BadGeo = true }))
{
    var result = await detector.ProbeAsync(new(), CancellationToken.None);
    Test("字段缺失是属性未知，不崩溃、不生成假数据", () => Require(result.Geo.Count == 0 && result.GeoErrors.Count == 1));
}

// 命名管道上的实际 HTTP 往返，只使用测试管道，不访问用户代理。
var pipeName = "ai-" + Guid.NewGuid().ToString("N")[..12];
using (var stop = new CancellationTokenSource(TimeSpan.FromSeconds(15)))
{
    var requests = new List<string>();
    var server = Task.Run(async () => {
        for (int i = 0; i < 4; i++)
        {
            await using var pipeServer = new NamedPipeServerStream(pipeName, PipeDirection.InOut, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous);
            await pipeServer.WaitForConnectionAsync(stop.Token);
            using var reader = new StreamReader(pipeServer, Encoding.UTF8, leaveOpen: true);
            var first = await reader.ReadLineAsync(stop.Token) ?? "";
            requests.Add(first);
            while (!string.IsNullOrEmpty(await reader.ReadLineAsync(stop.Token))) { }
            var json = first.Split(' ')[1] switch {
                "/configs" => """{"mode":"rule"}""",
                "/proxies" => """{"proxies":{"测试":{"type":"Socks5","dialer-proxy":""}}}""",
                "/rules" => """{"rules":[]}""",
                "/connections" => """{"connections":[{"metadata":{"host":"api.anthropic.com"},"chains":["测试"]}]}""",
                _ => throw new Exception("意外端点")
            };
            var bytes = Encoding.UTF8.GetBytes(json);
            await pipeServer.WriteAsync(Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: " + bytes.Length + "\r\n\r\n"), stop.Token);
            await pipeServer.WriteAsync(bytes, stop.Token);
            await pipeServer.FlushAsync(stop.Token);
        }
    }, stop.Token);
    using var mihomo = new Mihomo(pipeName);
    var runtime = await mihomo.RuntimeAsync(stop.Token);
    var connections = await mihomo.ConnectionsAsync(stop.Token);
    await server;
    Test("命名管道实际 HTTP 往返与只读端点", () => {
        Require(runtime.Mode == "rule" && runtime.Chain("测试").Count == 1 && connections.Count == 1);
        Require(requests.Count == 4 && requests.All(r => r.StartsWith("GET ")));
    });
}

if (args.FirstOrDefault(a => !a.StartsWith("--")) is string outputFolder)
{
    var folder = outputFolder; Directory.CreateDirectory(folder);
    File.WriteAllText(Path.Combine(folder, "exit-lock.js"), new ExitLockPlan(Runtime(), "落地", true, true).Script());
    var malicious = Runtime(); var name = "落地\";globalThis.injected=true;//";
    malicious.Proxies[name] = malicious.Proxies["落地"];
    File.WriteAllText(Path.Combine(folder, "escaped-lock.js"), new ExitLockPlan(malicious, name, true, false).Script());
}
Console.WriteLine($"全部 {passed} 组验证通过。");
if (args.Contains("--live"))
{
    using var live = new Detector();
    using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(120));
    var result = await live.ProbeAsync(new(), timeout.Token);
    foreach (var endpoint in result.Endpoints.Concat(result.References))
        Console.WriteLine($"{endpoint.Host}: {(endpoint.Error ?? "已取得真实 IP")} · {endpoint.Milliseconds} ms");
    Console.WriteLine($"真实归属地：{result.Geo.Count}；情报：{result.Risks.Count}；失败：{result.GeoErrors.Count + result.RiskErrors.Count}");
}

// 此 HTTP 夹具只编译进测试可执行文件；发行应用仅引用 WatchCore。
sealed class FixtureHandler : HttpMessageHandler
{
    public int GeoCalls, RiskCalls;
    public bool BadGeo;
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        var host = request.RequestUri!.Host;
        var status = HttpStatusCode.OK;
        string text;
        if (host == "ipwho.is") { GeoCalls++; text = BadGeo ? "{}" : """{"success":true,"ip":"203.0.113.7","country_code":"US","connection":{"asn":64500,"isp":"test"}}"""; }
        else if (host == "api.ipquery.io") { RiskCalls++; text = """{"ip":"203.0.113.7","risk":{"is_vpn":false}}"""; }
        else if (host == "ip.3322.net") text = "not-an-ip";
        else if (host == "checkip.amazonaws.com") text = "203.0.113.7\n";
        else if (host == "redirect.test") { status = HttpStatusCode.Found; text = ""; }
        else if (host == "large.test") text = new string('x', 128001);
        else text = "ip=203.0.113.7\nloc=US\n";
        return Task.FromResult(new HttpResponseMessage(status) { Content = new StringContent(text) });
    }
}
