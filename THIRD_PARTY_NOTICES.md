# 第三方声明

项目自身的 Swift / C# 代码、脚本和自绘盾牌图标采用根目录 MIT 许可证。图标生成源码位于 scripts/generate-icon.swift；Windows ICO 使用同一图标资源。

## macOS

应用使用 Apple 系统提供的 SwiftUI、AppKit、Foundation、UserNotifications、ServiceManagement、SystemConfiguration 和 JavaScriptCore 等框架，没有通过 Swift Package Manager 引入第三方库，也不随应用复制 Apple 系统框架。编译工具与系统组件适用各自的许可条款。

## Windows

便携包包含 Microsoft .NET 与 Windows Desktop Runtime。它们及所含第三方组件保持各自许可，不能用本项目 MIT 声明替代。运行库原始 LICENSE 和 THIRD-PARTY-NOTICES 随发行包保存在 runtime-licenses 目录；构建脚本从实际还原的运行包复制声明。源码工程没有额外的第三方生产 NuGet 依赖。

## 外部服务与兼容软件

Claude、Anthropic、ChatGPT、OpenAI、Cloudflare、Mihomo、Clash Verge Rev、Net.Coffee 及其他名称属于各自权利人。本项目是独立工具，不隶属于这些服务，不表示获得其认可。

应用会请求这些服务的公开网络端点；服务使用规则、可用性和数据准确性由各提供方决定。Mihomo / Clash Verge Rev 不包含在安装包内，需要用户自行安装；集成仅通过本地接口只读访问及导出供用户手动导入的脚本。

第三方数据来源与开关详见 PRIVACY.md。
