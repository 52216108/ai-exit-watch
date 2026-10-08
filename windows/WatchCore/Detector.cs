using System.Diagnostics;
using System.Net;
using System.Text.Json;

namespace WatchCore;

public sealed class Detector : IDisposable
{
    private readonly HttpClient client;
    private readonly Dictionary<string, (DateTimeOffset Until, Geo? Value, string? Error)> geos = [];
    private readonly Dictionary<string, (DateTimeOffset Until, Risk? Value, string? Error)> risks = [];
    public Detector() : this(new SocketsHttpHandler {
        AllowAutoRedirect = false, UseCookies = false,
        AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate,
        PooledConnectionLifetime = TimeSpan.FromMinutes(2), ConnectTimeout = TimeSpan.FromSeconds(10)
    }) { }
    public Detector(HttpMessageHandler handler) => client = new(handler) { Timeout = Timeout.InfiniteTimeSpan };

    public async Task<Snapshot> ProbeAsync(Settings settings, CancellationToken token)
    {
        settings.Validate();
        var probes = Target.AI.Concat(Target.References).Select(t => ProbeEndpointAsync(t, token)).ToArray();
        var chainTask = settings.ChainEnabled ? ObserveAsync(settings.PipeName, token) : Task.FromResult(new ChainObservation());
        var endpoints = await Task.WhenAll(probes);
        var chain = await chainTask;
        var sample = new Snapshot {
            Endpoints = endpoints.Take(Target.AI.Length).ToList(),
            References = endpoints.Skip(Target.AI.Length).ToList(),
            Chains = chain.Chains, ChainPath = chain.Path, ChainError = chain.Error
        };
        if (settings.GeoEnabled)
        {
            foreach (var ip in endpoints.Where(e => e.IP != null).Select(e => e.IP!).Distinct())
            {
                token.ThrowIfCancellationRequested();
                if (!geos.TryGetValue(ip, out var cached) || cached.Until <= DateTimeOffset.UtcNow)
                {
                    try { cached = (DateTimeOffset.UtcNow.AddMinutes(15), ParseGeo(await GetAsync(
                        $"https://ipwho.is/{ip}?lang=zh-CN&fields=ip,success,country_code,region,city,postal,timezone.id,connection", token), ip), null); }
                    catch (Exception ex) when (IsProbeError(ex, token)) { cached = (DateTimeOffset.UtcNow.AddMinutes(15), null, Explain(ex)); }
                    geos[ip] = cached;
                }
                if (cached.Value != null) sample.Geo[ip] = cached.Value;
                else sample.GeoErrors[ip] = cached.Error ?? "归属地未知";
            }
            foreach (var ip in sample.Endpoints.Where(e => e.IP != null).Select(e => e.IP!).Distinct())
            {
                token.ThrowIfCancellationRequested();
                if (!risks.TryGetValue(ip, out var cached) || cached.Until <= DateTimeOffset.UtcNow)
                {
                    try { cached = (DateTimeOffset.UtcNow.AddMinutes(15),
                        ParseRisk(await GetAsync($"https://api.ipquery.io/{ip}", token), ip), null); }
                    catch (Exception ex) when (IsProbeError(ex, token)) { cached = (DateTimeOffset.UtcNow.AddMinutes(15), null, Explain(ex)); }
                    risks[ip] = cached;
                }
                if (cached.Value != null) sample.Risks[ip] = cached.Value;
                else sample.RiskErrors[ip] = cached.Error ?? "IP 情报未知";
            }
            foreach (var key in geos.Where(p => p.Value.Until < DateTimeOffset.UtcNow).Select(p => p.Key).ToArray()) geos.Remove(key);
            foreach (var key in risks.Where(p => p.Value.Until < DateTimeOffset.UtcNow).Select(p => p.Key).ToArray()) risks.Remove(key);
        }
        token.ThrowIfCancellationRequested();
        return sample;
    }

    public async Task<Endpoint> ProbeEndpointAsync(Target target, CancellationToken token)
    {
        var clock = Stopwatch.StartNew();
        try { return TraceParser.Parse(await GetAsync(target.Url, token), target, (int)clock.ElapsedMilliseconds); }
        catch (Exception ex) when (IsProbeError(ex, token)) { return new(target.Host, Error: Explain(ex)); }
    }
    private async Task<string> GetAsync(string url, CancellationToken token)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token);
        timeout.CancelAfter(TimeSpan.FromSeconds(12));
        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.CacheControl = new() { NoCache = true, NoStore = true };
        using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token);
        if (response.StatusCode != HttpStatusCode.OK)
            throw new InvalidDataException($"来源返回 HTTP {(int)response.StatusCode}，未获得有效检测结果。");
        return await BoundedBody.ReadAsync(response, 128000, timeout.Token);
    }
    internal static bool IsProbeError(Exception ex, CancellationToken token) =>
        ex is HttpRequestException or IOException or InvalidDataException or JsonException or InvalidOperationException or KeyNotFoundException or FormatException or OverflowException ||
        (ex is OperationCanceledException && !token.IsCancellationRequested);
    public static string Explain(Exception ex) => ex switch {
        OperationCanceledException => "请求超时",
        HttpRequestException => "HTTPS 请求失败，请检查网络或系统代理",
        InvalidDataException => ex.Message,
        _ => "来源响应无法解析或无法读取"
    };
    public static Geo ParseGeo(string json, string ip)
    {
        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;
        if (root.GetProperty("success").ValueKind != JsonValueKind.True ||
            root.GetProperty("ip").GetString() != ip) throw new InvalidDataException("归属地来源未确认该 IP。");
        var country = root.GetProperty("country_code").GetString();
        var connection = root.GetProperty("connection");
        var asn = connection.GetProperty("asn").GetInt64();
        if (!TraceParser.ValidCountry(country) || asn <= 0) throw new InvalidDataException("归属地数据不完整。");
        return new(ip, country!, asn, Text(connection, "isp") ?? "未知", Text(root, "region"),
            Text(root, "city"), Text(root, "postal"),
            root.TryGetProperty("timezone", out var tz) && tz.ValueKind == JsonValueKind.Object ? Text(tz, "id") : null);
    }
    public static Risk ParseRisk(string json, string ip)
    {
        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;
        if (Text(root, "ip") != ip || !root.TryGetProperty("risk", out var risk) || risk.ValueKind != JsonValueKind.Object)
            throw new InvalidDataException("IP 情报来源未确认该 IP。");
        bool? Flag(string key) => risk.TryGetProperty(key, out var v) ? v.ValueKind switch {
            JsonValueKind.True => true, JsonValueKind.False => false, _ => null } : null;
        var result = new Risk(Flag("is_vpn"), Flag("is_proxy"), Flag("is_tor"), Flag("is_datacenter"), Flag("is_mobile"));
        if (result == new Risk(null, null, null, null, null)) throw new InvalidDataException("来源未提供风险标签。");
        return result;
    }
    internal static string? Text(JsonElement e, string key) =>
        e.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;

    private static async Task<ChainObservation> ObserveAsync(string name, CancellationToken token)
    {
        try
        {
            using var mihomo = new Mihomo(name);
            var observed = new List<ObservedConnection>();
            for (var i = 0; i < 4; i++)
            {
                await Task.Delay(200, token);
                observed.AddRange(await mihomo.ConnectionsAsync(token));
            }
            var hosts = new[] { "claude.ai", "api.anthropic.com" };
            if (!hosts.All(h => observed.Any(c => c.Host == h && c.Chains.Count > 0)))
                return new(Error: "未同时捕获 Claude 网页和 API 的活动连接，链路未知。");
            var chains = observed.Select(c => c.Host + ": " + string.Join(" → ", c.Chains)).Distinct().Order().ToList();
            string? path = null;
            try
            {
                var proxies = await mihomo.ProxiesAsync(token);
                var landing = observed.First(c => c.Host == "api.anthropic.com").Chains[0];
                path = "本机 → " + string.Join(" → ", new LockRuntime("rule", proxies, []).Chain(landing).AsEnumerable().Reverse().Select(n => n.Name)) +
                    " → Claude API (api.anthropic.com)";
            }
            catch (Exception ex) when (IsProbeError(ex, token)) { path = "已捕获连接；固定前置关系未获取。"; }
            return new(chains, path);
        }
        catch (Exception ex) when (IsProbeError(ex, token) || ex is UnauthorizedAccessException)
        { return new(Error: "未接入 Mihomo：请检查命名管道、访问权限和代理运行状态。"); }
    }
    public void Dispose() => client.Dispose();
}

public sealed record ChainObservation(List<string>? Chains = null, string? Path = null, string? Error = null);

internal static class BoundedBody
{
    public static async Task<string> ReadAsync(HttpResponseMessage response, int limit, CancellationToken token)
    {
        if (response.Content.Headers.ContentLength > limit) throw new InvalidDataException("来源响应过大。");
        await using var stream = await response.Content.ReadAsStreamAsync(token);
        using var memory = new MemoryStream();
        byte[] buffer = new byte[8192];
        int count;
        while ((count = await stream.ReadAsync(buffer, token)) != 0)
        {
            if (memory.Length + count > limit) throw new InvalidDataException("来源响应过大。");
            memory.Write(buffer, 0, count);
        }
        return System.Text.Encoding.UTF8.GetString(memory.ToArray());
    }
}
