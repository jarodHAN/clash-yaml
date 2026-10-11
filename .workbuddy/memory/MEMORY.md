# 项目长期记忆 (clashVPN)

## GitHub 连接器权限（重要）
- 本机连接的 GitHub 账号是 **jarodHAN**（id 20179121），通过 WorkBuddy 的 github 连接器接入。
- 该连接器只有**只读**权限：`get_me` / `search_repositories` / `get_file_contents` 可用，但
  `POST /user/repos` 建库返回 **403 Resource not accessible by integration**。
- 本机**没有 `gh` CLI**。
- 结论：我无法用连接器或 CLI 创建/推送 GitHub 仓库。要建/推仓库，需用户：
  (a) 在 GitHub 网页手动建库并上传文件；或 (b) 重新授权连接器时授予 repo 写权限（含 create repo）。
- 用户意图：把 Clash/mihomo 订阅配置托管到 `jarodHAN/clash-yaml`（注意：不是 clash-verge-yaml）。
  该仓库当前不存在，需用户先在网页创建。

## 订阅配置（本地产物）
- 已生成可直接被 clashVPN.app 使用的订阅模板：
  `/Users/tkepler/WorkBuddy/clashVPN/subscription/clash.yaml`
  （节点列表格式，含 proxies/proxy-groups/rules；DIRECT 为 mihomo 内置，勿重复定义；
   默认只用域名分流规则，GEOIP 规则需 geoip.metadb 才启用）。
- 发布到 GitHub 后的 raw 路径（待用户建库）：
  `https://raw.githubusercontent.com/jarodHAN/clash-yaml/main/clash.yaml`
- 已用内嵌 mihomo 核心（-t 测试 + HTTP proxy-provider 拉取）端到端验证：节点可被 App 正确加载。
