# Windows 版

独立的 .NET 10 / Windows Forms x64 托盘应用，源代码位于 WatchCore 与 AIExitWatch，不改变 macOS 实现。首版目标为 Windows 11 Intel / AMD。

无第三方生产 NuGet 依赖；运行包包含 .NET 与 Windows Desktop Runtime。默认不签名，不使用 Apple 或公司证书。

## 开发与验证

安装 .NET 10 SDK。在 Windows、macOS 或 Linux 上验证可移植核心：

    dotnet run --project windows/WatchCore.Tests -c Release -- .build/windows-tests
    node windows/WatchCore.Tests/verify-lock.mjs .build/windows-tests

如有本机 Mihomo，可复用独立回环验证（不接入现有系统代理 / TUN）：

    python3 Tests/WatchCoreTests/verify_exit_lock.py /path/to/mihomo .build/windows-tests/mihomo-fixture.json

Windows 上执行 pwsh windows/build.ps1，或在任一平台交叉构建：

    dotnet publish windows/AIExitWatch/AIExitWatch.csproj -c Release -r win-x64 \
      --self-contained true -p:PublishSingleFile=true \
      -p:IncludeNativeLibrariesForSelfExtract=true -p:PublishTrimmed=false \
      -o dist/windows-x64

执行 python3 scripts/package-release.py windows 打包，自动附带使用说明、MIT 许可证和实际运行库声明。单文件运行时将原生运行库解压到 .NET 的当前用户缓存目录；不要求安装全局 .NET。构建需要从 NuGet 获取 Windows Desktop 目标包和 win-x64 运行包。

## 设计与边界

- 核心负责真实 HTTPS 请求、解析、缓存、基准比较、两次告警确认、原子本地存储、命名管道只读访问及保护脚本。测试夹具只在测试工程。
- UI 串行触发探测，暂停、设置变更、休眠递增轮次并取消旧请求；旧轮次不保存或通知。恢复后重新探测。关闭窗口保留托盘，明确退出才停止。
- 使用 Windows 系统网络路径，拒绝重定向，保留系统 TLS 证书校验；请求 12 秒超时、128 KB 上限。Mihomo 仅连接本机命名管道，禁用 HTTP 代理，限四个 GET 端点，3 秒超时与 8 MB 上限。
- 保护逻辑与 macOS 一致：完整固定物理链、前置核验、规则置顶、每域名节点规则后紧邻 REJECT。只导出供手动导入，不加载代理配置或变更节点。
- Windows 使用 NotifyIcon 通知，图标来自原有蓝绿色盾牌资源。通知是否显示受系统设置影响。
- 首版 Windows 的基础能力已经实现，实机 GUI / 高 DPI、通知、登录启动、休眠恢复和实际 Clash Verge 管道兼容性必须在 Windows 上验收。交叉编译成功不能代替这些结果。

参考：[Microsoft 发布说明](https://learn.microsoft.com/en-us/dotnet/core/deploying/single-file/overview)、[Mihomo API](https://wiki.metacubex.one/api/)、[Clash Verge Rev 扩展脚本](https://www.clashverge.dev/guide/extend.html)。
