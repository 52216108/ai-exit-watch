using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using Microsoft.Win32;

namespace AIExitWatch;

internal static class SystemInfo
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    public static bool StartupEnabled()
    {
        using var key = Registry.CurrentUser.OpenSubKey(RunKey);
        return key?.GetValue("AIExitWatch") is string;
    }
    public static void SetStartup(bool enabled)
    {
        using var key = Registry.CurrentUser.CreateSubKey(RunKey, true);
        if (enabled) key.SetValue("AIExitWatch", "\"" + Environment.ProcessPath + "\" --tray", RegistryValueKind.String);
        else key.DeleteValue("AIExitWatch", false);
    }
    public static string IPv6()
    {
        try
        {
            var lines = NetworkInterface.GetAllNetworkInterfaces()
                .Where(n => n.OperationalStatus == OperationalStatus.Up && n.NetworkInterfaceType != NetworkInterfaceType.Loopback)
                .Select(n => {
                    var addresses = n.GetIPProperties().UnicastAddresses.Select(a => a.Address)
                        .Where(a => a.AddressFamily == AddressFamily.InterNetworkV6 && !IPAddress.IsLoopback(a)).ToArray();
                    var global = addresses.Count(a => !a.IsIPv6LinkLocal && !a.IsIPv6Multicast &&
                        (a.GetAddressBytes()[0] & 0xfe) != 0xfc);
                    var local = addresses.Count(a => a.IsIPv6LinkLocal);
                    var unique = addresses.Length - global - local;
                    return $"{n.Name}：{(n.Supports(NetworkInterfaceComponent.IPv6) ? "接口支持 IPv6" : "接口未报告 IPv6 支持")}；全局地址 {global}，链路本地 {local}，本地专用 {unique}";
                }).ToArray();
            return (lines.Length == 0 ? "未发现活动网络接口。" : string.Join("\r\n", lines)) +
                "\r\n\r\n这是只读接口观察，无法据此确认系统 IPv6 已彻底关闭；没有全局地址不等于开关关闭，有地址不等于公网连通或浏览器无泄露。";
        }
        catch (NetworkInformationException) { return "无法读取网络接口，IPv6 状态未知。"; }
    }
    public static string[] Pipes()
    {
        try
        {
            return Directory.GetFiles(@"\\.\pipe\")
                .Select(p => p[(p.LastIndexOf('\\') + 1)..])
                .Where(p => p.Contains("mihomo", StringComparison.OrdinalIgnoreCase))
                .Order().ToArray();
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { return []; }
    }
}
