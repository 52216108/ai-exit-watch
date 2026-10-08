using System.Globalization;
using System.Net;
using System.Net.Sockets;
using System.Text.RegularExpressions;

namespace WatchCore;

public sealed record Settings(int Interval = 60, int SlowMilliseconds = 3000,
    bool GeoEnabled = true, bool ChainEnabled = false, string PipeName = "verge-mihomo")
{
    public void Validate()
    {
        if (!new[] { 60, 120, 300, 600 }.Contains(Interval) || SlowMilliseconds is < 500 or > 60000)
            throw new InvalidDataException("检测间隔或延迟阈值不受支持。");
        Mihomo.NormalizePipe(PipeName);
    }
}

public sealed record Target(string Host, string Name, string Url, bool Trace = true)
{
    public static readonly Target[] AI = [
        new("claude.ai", "Claude 网页", "https://claude.ai/cdn-cgi/trace"),
        new("api.anthropic.com", "Claude API", "https://api.anthropic.com/cdn-cgi/trace"),
        new("chatgpt.com", "ChatGPT 网页", "https://chatgpt.com/cdn-cgi/trace")
    ];
    public static readonly Target[] References = [
        new("ip.3322.net", "国内参考", "https://ip.3322.net/", false),
        new("checkip.amazonaws.com", "海外参考", "https://checkip.amazonaws.com/", false),
        new("www.cloudflare.com", "Cloudflare 参考", "https://www.cloudflare.com/cdn-cgi/trace")
    ];
}

public sealed record Endpoint(string Host, string? IP = null, string? Country = null,
    int? Milliseconds = null, string? Error = null);
public sealed record Geo(string IP, string Country, long ASN, string ISP,
    string? Region, string? City, string? Postal, string? Timezone)
{
    public string Place => string.Join(" · ", new[] { Presentation.Country(Country), Region, City }
        .Where(s => !string.IsNullOrWhiteSpace(s)).Distinct());
}
public sealed record Risk(bool? VPN, bool? Proxy, bool? Tor, bool? Datacenter, bool? Mobile);
public sealed record Snapshot
{
    public DateTimeOffset Date { get; init; } = DateTimeOffset.Now;
    public List<Endpoint> Endpoints { get; init; } = [];
    public List<Endpoint> References { get; init; } = [];
    public Dictionary<string, Geo> Geo { get; init; } = [];
    public Dictionary<string, string> GeoErrors { get; init; } = [];
    public Dictionary<string, Risk> Risks { get; init; } = [];
    public Dictionary<string, string> RiskErrors { get; init; } = [];
    public List<string>? Chains { get; init; }
    public string? ChainPath { get; init; }
    public string? ChainError { get; init; }

    public bool CanBaseline(Settings settings) =>
        Endpoints.Count == Target.AI.Length &&
        Target.AI.All(t => Endpoints.Count(e => e.Host == t.Host && e.Error == null &&
            e.IP != null && TraceParser.ValidIP(e.IP) && (!settings.GeoEnabled || Geo.ContainsKey(e.IP))) == 1) &&
        (!settings.ChainEnabled || Chains is { Count: > 0 });
}

public sealed record Issue(string ID, string Message);
public sealed record AlertEvent(DateTimeOffset Date, string Title, string Message);

public static class Comparison
{
    public static List<Issue> Issues(Snapshot sample, Snapshot? baseline, Settings settings)
    {
        List<Issue> result = [];
        foreach (var target in Target.AI)
        {
            var endpoint = sample.Endpoints.SingleOrDefault(e => e.Host == target.Host);
            var host = target.Host;
            if (endpoint?.IP == null || endpoint.Error != null)
            {
                result.Add(new("network:" + host, target.Name + "：" + (endpoint?.Error ?? "未获取出口 IP")));
                continue;
            }
            var old = baseline?.Endpoints.Find(e => e.Host == host);
            if (old?.IP != null && old.IP != endpoint.IP)
                result.Add(new("ip:" + host, $"{target.Name} 出口变化：{old.IP} → {endpoint.IP}"));
            if (old?.Country != null && endpoint.Country != null && old.Country != endpoint.Country)
                result.Add(new("country:" + host, $"{target.Name} 探测地区变化"));
            if (settings.GeoEnabled)
            {
                if (!sample.Geo.TryGetValue(endpoint.IP, out var geo))
                    result.Add(new("geo-unavailable:" + host, $"{target.Name} 归属地未知"));
                else if (old?.IP != null && baseline!.Geo.TryGetValue(old.IP, out var oldGeo))
                {
                    if (oldGeo.ASN != geo.ASN)
                        result.Add(new("asn:" + host, $"{target.Name} ASN 变化：AS{oldGeo.ASN} → AS{geo.ASN}"));
                    if (oldGeo.Country != geo.Country)
                        result.Add(new("geo:" + host, $"{target.Name} IP 库地区变化"));
                }
            }
            if (endpoint.Milliseconds > settings.SlowMilliseconds)
                result.Add(new("slow:" + host, $"{target.Name} 延迟 {endpoint.Milliseconds} ms，超过阈值"));
        }
        if (settings.ChainEnabled)
        {
            if (sample.Chains is not { Count: > 0 })
                result.Add(new("chain-unavailable", sample.ChainError ?? "Claude 活动链路未知"));
            else if (baseline?.Chains != null && !baseline.Chains.SequenceEqual(sample.Chains))
                result.Add(new("chain:claude", "观察到的 Claude 活动链路发生变化"));
        }
        return result;
    }
}

// 按异常逐项确认；缺失证据不能把已有偏离判成恢复。
public sealed class AlertMachine
{
    private readonly Dictionary<string, int> streak = [], cleared = [];
    public Dictionary<string, Issue> Active { get; } = [];
    public void ResetPending() { streak.Clear(); cleared.Clear(); }
    public List<AlertEvent> Consume(List<Issue> issues)
    {
        var current = issues.ToDictionary(i => i.ID);
        foreach (var id in streak.Keys.Except(current.Keys).ToArray()) streak.Remove(id);
        List<string> started = [], ended = [];
        foreach (var (id, issue) in current)
        {
            streak[id] = Math.Min(streak.GetValueOrDefault(id) + 1, 2);
            cleared.Remove(id);
            if (streak[id] >= 2 && !Active.ContainsKey(id)) { Active[id] = issue; started.Add(issue.Message); }
            if (Active.ContainsKey(id)) Active[id] = issue;
        }
        foreach (var (id, issue) in Active.ToArray())
        {
            if (current.ContainsKey(id)) continue;
            var host = id.Split(':').ElementAtOrDefault(1);
            var unknown = (host != null && current.ContainsKey("network:" + host)) ||
                ((id.StartsWith("asn:") || id.StartsWith("geo:")) && current.ContainsKey("geo-unavailable:" + host)) ||
                (id.StartsWith("chain:") && current.ContainsKey("chain-unavailable"));
            if (unknown) { cleared.Remove(id); continue; }
            cleared[id] = cleared.GetValueOrDefault(id) + 1;
            if (cleared[id] >= 2) { Active.Remove(id); cleared.Remove(id); ended.Add(issue.Message); }
        }
        List<AlertEvent> events = [];
        if (started.Count > 0) events.Add(new(DateTimeOffset.Now, "网络监测发现异常", string.Join("\n", started)));
        if (ended.Count > 0) events.Add(new(DateTimeOffset.Now, "部分检测项已恢复或变化",
            "以下异常已连续两次不再出现：\n" + string.Join("\n", ended)));
        return events;
    }
}

public static partial class TraceParser
{
    [GeneratedRegex(@"^[A-Z]{2}$")] private static partial Regex CountryPattern();
    [GeneratedRegex(@"^(0|[1-9]\d{0,2})(\.(0|[1-9]\d{0,2})){3}$")] private static partial Regex V4Pattern();
    public static bool ValidCountry(string? value) => value != null && CountryPattern().IsMatch(value);
    public static bool ValidIP(string value)
    {
        // IPAddress.TryParse 单独使用会把整数、八进制和缩写地址也视为合法。
        if (value.Contains('%') || !IPAddress.TryParse(value, out var ip)) return false;
        return ip.AddressFamily == AddressFamily.InterNetworkV6 ? value.Contains(':') : V4Pattern().IsMatch(value);
    }
    public static Endpoint Parse(string text, Target target, int milliseconds)
    {
        if (!target.Trace)
        {
            var ip = text.Trim();
            if (!ValidIP(ip)) throw new InvalidDataException("来源未返回有效 IP。");
            return new(target.Host, ip, Milliseconds: milliseconds);
        }
        var fields = text.Split('\n').Select(l => l.Split('=', 2)).Where(p => p.Length == 2)
            .GroupBy(p => p[0]).ToDictionary(g => g.Key, g => g.Last()[1].Trim());
        var address = fields.GetValueOrDefault("ip");
        var country = fields.GetValueOrDefault("loc");
        if (address == null || !ValidIP(address) || !ValidCountry(country))
            throw new InvalidDataException("检测响应不完整或不是有效 trace。");
        return new(target.Host, address, country, milliseconds);
    }
}

public static class Presentation
{
    public static string Country(string? code)
    {
        if (code == null) return "未知";
        // Geo 服务已请求中文，其余国家代码交由系统区域库显示。
        var common = new Dictionary<string, string> {
            ["US"]="美国", ["CN"]="中国", ["TW"]="中国台湾", ["HK"]="中国香港", ["MO"]="中国澳门",
            ["JP"]="日本", ["SG"]="新加坡", ["GB"]="英国", ["DE"]="德国", ["CA"]="加拿大",
            ["AU"]="澳大利亚", ["FR"]="法国", ["KR"]="韩国", ["NL"]="荷兰", ["IN"]="印度"
        };
        if (common.TryGetValue(code, out var chinese)) return chinese;
        try { return new RegionInfo(code).DisplayName; } catch (ArgumentException) { return code; }
    }
    public static string Flag(bool? flag) => flag switch { true => "已标记", false => "情报库未标记", null => "未知" };
}
