# 隐私与网络请求

本工具不需要 Claude / OpenAI 登录、API Key 或代理订阅。没有自建数据接收服务器、账号系统、统计埋点或自动更新下载。

## 每轮检测

| 请求来源 | 用途 |
| --- | --- |
| claude.ai/cdn-cgi/trace | Claude 网页请求出口 |
| api.anthropic.com/cdn-cgi/trace | Claude API 域名请求出口 |
| chatgpt.com/cdn-cgi/trace | ChatGPT 网页请求出口 |
| ip.3322.net | 国内参考出口 |
| checkip.amazonaws.com | 海外参考出口 |
| www.cloudflare.com/cdn-cgi/trace | Cloudflare 参考出口 |

均使用 HTTPS 和系统证书校验，拒绝重定向，不携带 AI 账号凭据或浏览器 Cookie。每个来源正常接收请求的公网出口 IP。应用沿用本机网络路径，浏览器若单独配置代理或按进程分流，其实际出口可能不同。

## 可关闭的第三方查询

“归属地 / IP 情报”默认开启，可在设置关闭：

- ipwho.is：收到探测 IP，返回中文地区、ASN、运营商和时区等。
- api.ipquery.io：收到 AI 目标的探测 IP，返回 VPN、公开代理、Tor、机房、移动网络标签。

同一 IP 的成功结果缓存 15 分钟，失败冷却 15 分钟；失败时不拿过期数据冒充当前结果。参考来源只查归属地，不额外查询 IP 情报。第三方服务可能按自己的政策记录请求。

## 本机只读观察

Mihomo 链路观察默认关闭。启用后读取本地 Unix socket（macOS）或命名管道（Windows）的活动连接与节点元数据；出口锁定页面额外读取模式和规则。不会写入代理配置、切换节点、改变 DNS / TUN 或重启内核，不请求节点认证配置。

IPv6 检查读取活动网络接口与地址类别，macOS 另读取系统网络服务配置。不上传或保存本机 IPv6 地址。

## 浏览器检测

只有点击“查看 Claude 登录环境检测”时，才在默认浏览器打开 https://ip.net.coffee/claude/。该站点会执行自己的浏览器环境检测并适用其自身政策；后台监测不依赖它。请在实际登录 Claude 的同一浏览器检查。

## 本地保存与分享

- macOS：~/Library/Application Support/NetworkWatch/state.json。
- Windows：%LOCALAPPDATA%\AIExitWatch\state.json。

保存设置、手动基准、最近 1,440 次样本和 500 条事件，可能包含公网 IP、归属地和节点名称，不云同步。文件损坏时保留原件并提示。

通知只展示摘要，不展示 IP 和节点名称。导出的保护脚本包含节点名称、类型、前置关系和域名，节点名称也可能包含个人信息，公开前请检查。

提交 Issue、日志或截图前，请去除 IP、节点名、订阅链接、认证信息和本地用户路径。不要提交 state.json 或代理配置。退出应用后可自行备份或移除本地数据；卸载应用不会自动移除这些数据。
