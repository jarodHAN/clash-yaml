# clash-yaml

Clash / mihomo 订阅配置，供 clashVPN.app 使用。

## 使用方法

1. 把 `clash.yaml` 里的 `proxies:` 整体替换成你机场的 Clash 订阅内容  
   （从机场后台复制 “Clash / 订阅” 格式的 YAML，通常就是 `proxies:` 开头的节点列表）。
2. 在 GitHub 新建仓库 `jarodHAN/clash-yaml`（分支名用 `main`），上传 `clash.yaml`。
3. 在 clashVPN.app 的「订阅 URL」填入：  
   `https://raw.githubusercontent.com/jarodHAN/clash-yaml/main/clash.yaml`
4. 点「应用并重启」，节点即出现在菜单栏面板。

## 注意

- 仓库可公开也可私有：
  - **公开**：`raw.githubusercontent.com/.../clash.yaml` 可直接被 App 拉取，但节点服务器信息会暴露。
  - **私有**：raw 链接默认无法被 App 直接鉴权拉取。若要私有托管，需在使用处带上 token（如 `?token=XXX` 或在 App 订阅 URL 用带令牌的形式），否则 App 内直接填机场订阅即可（不走 GitHub）。
- clashVPN.app 会把该 URL 当作 mihomo 的 proxy-provider 自动拉取，`proxies:` 字段即为节点来源。

