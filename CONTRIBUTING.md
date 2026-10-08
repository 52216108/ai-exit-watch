# 参与贡献

欢迎提交已脱敏的问题报告和 Pull Request。大范围功能或交互变更请先用 Issue 说明目标，避免重复开发。

## 构建和验证

macOS 需要 macOS 13+、完整 Xcode 与 Python 3：

    swift test
    bash scripts/build-app.sh

Windows 需要 .NET 10 SDK；验证脚本另用 Node.js：

    dotnet run --project windows/WatchCore.Tests -c Release -- .build/windows-tests
    node windows/WatchCore.Tests/verify-lock.mjs .build/windows-tests
    pwsh windows/build.ps1

按受影响平台运行直接相关测试；公共构建和发行脚本修改还需检查两端打包。若有 Mihomo，可按 README 运行独立回环测试，不要用真实代理链做故障注入。

## 代码约定

- 用户提示与新增注释优先中文，沿用所在平台代码风格。
- 网络失败、数据未知和确认正常必须区分；生产路径不允许演示数据或假数据兜底。
- 保留 HTTPS 证书校验、请求上限、只读本地控制器和手动基准。
- 不改变用户的代理链、TUN、DNS 或系统安全设置；保护配置只导出，由用户手动导入。
- 不提交密码、证书、订阅地址、个人 IP、检测历史或本地用户路径。
- PR 说明行为变化、验证结果与未验证项。构建成功不等于真实桌面交互验收。

项目按 MIT 接收贡献。提交贡献意味着你有权提供相应代码，并同意将该贡献按项目 MIT 许可证发布。第三方代码或资源须注明来源和保留其原许可。
