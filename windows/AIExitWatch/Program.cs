using System.Globalization;
using System.Security.Principal;

namespace AIExitWatch;

internal static class Program
{
    public static readonly string SystemLanguage = CultureInfo.CurrentUICulture.DisplayName;
    [STAThread]
    private static void Main(string[] args)
    {
        using var mutex = new Mutex(true, @"Local\AIExitWatch-" + WindowsIdentity.GetCurrent().User?.Value, out var first);
        if (!first)
        {
            MessageBox.Show("AI落地安全检测已在运行，请双击任务栏通知区域（右下角）的盾牌图标打开。", "AI落地安全检测");
            return;
        }
        ApplicationConfiguration.Initialize();
        CultureInfo.CurrentUICulture = CultureInfo.GetCultureInfo("zh-CN");
        Application.Run(new MainForm(args.Contains("--tray")));
    }
}
