using System.Text.Json;
using System.Text.Json.Serialization;

namespace WatchCore;

public sealed record LockProxy(string Type, [property: JsonPropertyName("dialer-proxy")] string? DialerProxy = null,
    List<string>? All = null, string? Now = null)
{
    public string? ConfigType => Type?.ToLowerInvariant() switch {
        "shadowsocks" => "ss", "shadowsocksr" => "ssr",
        "socks5" or "http" or "snell" or "vmess" or "vless" or "trojan" or "hysteria" or "hysteria2" or "tuic" or "wireguard" or "anytls" or "ssh" => Type.ToLowerInvariant(),
        _ => null
    };
}
public sealed record LockNode(string Name, string Type, string Dialer);
public sealed record RuleExtra(bool Disabled = false);
public sealed record LockRule(string Type, string Payload, string Proxy, RuleExtra? Extra = null);
public sealed record LockRuntime(string Mode, Dictionary<string, LockProxy> Proxies, List<LockRule> Rules)
{
    public List<LockNode> Chain(string landing)
    {
        List<LockNode> nodes = [];
        HashSet<string> visited = [];
        var name = landing;
        while (!string.IsNullOrEmpty(name))
        {
            if (!visited.Add(name) || !Proxies.TryGetValue(name, out var proxy) || proxy == null ||
                proxy.ConfigType == null || proxy.All != null || proxy.Now != null || proxy.DialerProxy == null)
                throw new InvalidDataException("仅支持前置关系明确的固定节点链；不能选择自动切换组、直连或未知链路。");
            nodes.Add(new(name, proxy.ConfigType, proxy.DialerProxy));
            name = proxy.DialerProxy;
        }
        if (nodes.Count == 0) throw new InvalidDataException("请选择固定落地节点。");
        return nodes;
    }
    public List<string> Candidates => Proxies.Keys.Where(k => {
        try { Chain(k); return true; } catch (InvalidDataException) { return false; }
    }).Order().ToList();
}
public sealed record LockVerification(string Status, string Message);

public sealed class ExitLockPlan
{
    public List<LockNode> Nodes { get; }
    public List<string> Domains { get; }
    [JsonIgnore] public string Landing => Nodes[0].Name;
    [JsonIgnore] public string Path => "本机 → " + string.Join(" → ", Nodes.AsEnumerable().Reverse().Select(n => n.Name)) + " → AI 服务";
    public ExitLockPlan(LockRuntime runtime, string landing, bool claude, bool openAI)
    {
        if (!claude && !openAI) throw new InvalidDataException("请至少选择一类 AI 服务。");
        Nodes = runtime.Chain(landing);
        if (Nodes.Any(n => n.Name.Contains(',') || n.Name.Any(char.IsControl)))
            throw new InvalidDataException("节点名含规则分隔符或控制字符，无法安全生成配置。");
        Domains = [];
        if (claude) Domains.AddRange(["claude.ai", "anthropic.com", "claudeusercontent.com"]);
        if (openAI) Domains.AddRange(["chatgpt.com", "openai.com", "oaistatic.com", "oaiusercontent.com"]);
    }
    public string Script() => """
        // BEGIN AI落地安全检测 出口锁定
        // 追加在 Clash Verge Rev 订阅扩展脚本末尾，先备份原脚本。
        // 更新时替换整个 BEGIN / END 区块，不覆盖原有前置、落地配置脚本。
        // 仅保护经过 Mihomo 规则模式的新连接，不修改 TUN、DNS 或节点定义。
        var main = (function (previousMain) {
          const plan =
        """ + JsonSerializer.Serialize(this, StateStore.Json) + """
        ;
          return function (config, profileName) {
            const next = typeof previousMain === "function" ? previousMain(config, profileName) : config;
            const proxies = Array.isArray(next.proxies) ? next.proxies : [];
            const groups = Array.isArray(next["proxy-groups"]) ? next["proxy-groups"] : [];
            const valid = plan.nodes.every(function (expected) {
              const matches = proxies.filter(function (p) { return p.name === expected.name; });
              return matches.length === 1
                && !groups.some(function (g) { return g.name === expected.name; })
                && matches[0].type === expected.type
                && (matches[0]["dialer-proxy"] || "") === expected.dialer;
            });
            const target = valid ? plan.nodes[0].name : "REJECT";
            const lockRules = plan.domains.flatMap(function (domain) {
              // 节点不支持 UDP 时 Mihomo 会继续匹配，用相邻拒绝规则阻止回落。
              return ["DOMAIN-SUFFIX," + domain + "," + target, "DOMAIN-SUFFIX," + domain + ",REJECT"];
            });
            const original = Array.isArray(next.rules) ? next.rules : [];
            next.rules = lockRules.concat(original.filter(function (rule) { return !lockRules.includes(rule); }));
            return next;
          };
        })(typeof main === "function" ? main : null);
        // END AI落地安全检测 出口锁定
        """;

    public LockVerification Verify(LockRuntime runtime)
    {
        LockVerification Unknown(string message) => new("未确认生效", message);
        if (!string.Equals(runtime.Mode, "rule", StringComparison.OrdinalIgnoreCase))
            return Unknown("Mihomo 当前不是规则模式。");
        if (runtime.Rules.Count < Domains.Count * 2) return Unknown("缺少完整的置顶保护规则。");
        var first = runtime.Rules.Take(Domains.Count * 2).ToList();
        for (var i = 0; i < first.Count; i++)
        {
            var rule = first[i];
            if (rule == null || rule.Type != "DomainSuffix" || rule.Payload != Domains[i / 2] || rule.Extra?.Disabled == true)
                return Unknown("保护规则未完整置顶或被禁用。");
            if (i % 2 == 1 && rule.Proxy != "REJECT")
                return Unknown("缺少相邻拒绝规则，UDP 可能回落到其他出口。");
        }
        if (first.All(r => r.Proxy == "REJECT"))
            return new("已配置拒绝", "该时刻保护域名的新连接指向 REJECT。");
        try
        {
            if (first.Where((_, i) => i % 2 == 0).Any(r => r.Proxy != Landing) ||
                !runtime.Chain(Landing).SequenceEqual(Nodes))
                return Unknown("规则目标或固定前置链与当前方案不同。");
        }
        catch (InvalidDataException) { return Unknown("固定节点链已改变或信息缺失。"); }
        return new("已配置固定节点", "该时刻保护规则指向指定节点，失败不回退直连；不代表节点可用或系统全流量已保护。");
    }
}
