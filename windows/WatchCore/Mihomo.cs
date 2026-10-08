using System.IO.Pipes;
using System.Net;
using System.Security.Principal;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace WatchCore;

public sealed record ObservedConnection(string Host, List<string> Chains);

// 只允许本机命名管道和四个 GET 端点，不打开 TCP 控制器，也不写入代理配置。
public sealed partial class Mihomo : IDisposable
{
    private readonly HttpClient client;
    [GeneratedRegex(@"^[a-zA-Z0-9_.-]{1,180}$")] private static partial Regex PipePattern();
    public static string NormalizePipe(string name)
    {
        const string prefix = @"\\.\pipe\";
        var value = (name ?? "").Trim();
        if (value.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) value = value[prefix.Length..];
        if (!PipePattern().IsMatch(value)) throw new ArgumentException("请输入本机 Mihomo 管道名，例如 verge-mihomo；不接受远程路径。");
        return value;
    }
    public Mihomo(string name)
    {
        var pipeName = NormalizePipe(name);
        var handler = new SocketsHttpHandler {
            AllowAutoRedirect = false, UseProxy = false, UseCookies = false,
            ConnectCallback = async (_, token) => {
                var pipe = new NamedPipeClientStream(".", pipeName, PipeDirection.InOut, PipeOptions.Asynchronous,
                    TokenImpersonationLevel.Anonymous);
                try { await pipe.ConnectAsync(token); return pipe; }
                catch { pipe.Dispose(); throw; }
            }
        };
        client = new(handler) { BaseAddress = new Uri("http://localhost/"), Timeout = Timeout.InfiniteTimeSpan };
    }
    private async Task<JsonDocument> ReadAsync(string endpoint, CancellationToken token)
    {
        if (!new[] { "configs", "proxies", "rules", "connections" }.Contains(endpoint))
            throw new ArgumentException("不支持的只读端点");
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token);
        timeout.CancelAfter(TimeSpan.FromSeconds(3));
        using var response = await client.GetAsync(endpoint, HttpCompletionOption.ResponseHeadersRead, timeout.Token);
        if (response.StatusCode != HttpStatusCode.OK)
            throw new InvalidDataException($"Mihomo 返回 HTTP {(int)response.StatusCode}。请检查管道权限。");
        return JsonDocument.Parse(await BoundedBody.ReadAsync(response, 8 * 1024 * 1024, timeout.Token));
    }
    public async Task<Dictionary<string, LockProxy>> ProxiesAsync(CancellationToken token)
    {
        using var doc = await ReadAsync("proxies", token);
        return JsonSerializer.Deserialize<Dictionary<string, LockProxy>>(doc.RootElement.GetProperty("proxies").GetRawText(), StateStore.Json)
            ?? throw new InvalidDataException("节点信息为空。");
    }
    public async Task<LockRuntime> RuntimeAsync(CancellationToken token)
    {
        using var configs = await ReadAsync("configs", token);
        var mode = configs.RootElement.GetProperty("mode").GetString() ?? "";
        var proxies = await ProxiesAsync(token);
        using var rules = await ReadAsync("rules", token);
        var entries = JsonSerializer.Deserialize<List<LockRule>>(rules.RootElement.GetProperty("rules").GetRawText(), StateStore.Json)
            ?? throw new InvalidDataException("规则信息为空。");
        return new(mode, proxies, entries);
    }
    public async Task<List<ObservedConnection>> ConnectionsAsync(CancellationToken token)
    {
        using var doc = await ReadAsync("connections", token);
        List<ObservedConnection> result = [];
        if (!doc.RootElement.TryGetProperty("connections", out var connections) || connections.ValueKind == JsonValueKind.Null) return result;
        foreach (var c in connections.EnumerateArray())
        {
            var host = Detector.Text(c.GetProperty("metadata"), "host");
            if (host is not ("claude.ai" or "api.anthropic.com")) continue;
            var chains = c.GetProperty("chains").EnumerateArray().Select(v => v.GetString()).OfType<string>().ToList();
            if (chains.Count > 0) result.Add(new(host, chains));
        }
        return result;
    }
    public void Dispose() => client.Dispose();
}
