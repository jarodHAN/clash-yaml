# clashVPN

原生 macOS 菜单栏 Clash 客户端，内嵌 [mihomo](https://github.com/MetaCubeX/mihomo)（Clash.Meta）核心，开箱即用，无需另装内核。

> 当前为 **x86_64（Intel Mac）** 构建。Apple Silicon 需重新编译 `swiftc` 目标并替换 `Resources/mihomo` 为 `darwin-arm64` 版本。

## 功能

- 菜单栏图标一键开关、左键展开面板、右键快速操作
- 内嵌 mihomo 核心，自动拉起 `external-controller` 并接管订阅
- 订阅支持两种格式：
  - **节点列表**（仅 `proxies:` 开头）→ 作为 `proxy-provider` 自动加载
  - **完整 Clash 配置**（含 `proxies`/`proxy-groups`/`rules`）→ 直接作为配置使用（仅补充缺失的 `external-controller` 与 `secret`，不重复注入字段）
- 节点列表展示、点击切换、延迟测速（颜色分级）
- 定时/手动更新订阅
- 完整菜单：退出（⌘Q）、编辑（复制/粘贴/全选）
- 实时日志面板（可选文本选择，便于复制报错）

## 目录结构

```
clashVPN/
├── Sources/                 # Swift 源码（AppDelegate / AppState / ContentView / MihomoCore / ClashController / Models / main）
├── Resources/
│   ├── Info.plist           # 打包清单（LSUIElement=true，菜单栏常驻）
│   ├── mihomo               # 内嵌 mihomo 核心（darwin-amd64，构建时下载，不入库）
│   └── geo/                 # geoip.metadb / geosite.dat（构建时下载，不入库）
├── subscription/
│   ├── clash.yaml           # 订阅模板，托管到 jarodHAN/clash-yaml
│   └── README.md            # 订阅托管说明
├── build.sh                 # 一键编译 + 打包 .app + 下载内核/geo
└── .gitignore
```

> `.gitignore` 已排除 `build/`、`.app`、`mihomo`、`*.metadb`、`*.dat` 等二进制，仓库只保留源码与配置。

## 构建

```bash
cd clashVPN
bash build.sh
```

脚本会：下载 mihomo（darwin-amd64）、用 `swiftc` 编译、组装 `build/clashVPN.app`、尽力下载 geo 数据库、ad-hoc 签名并移除 quarantine。

首次运行若被系统拦截（ad-hoc 签名未受信任）：

```bash
xattr -d com.apple.quarantine build/clashVPN.app
```

## 使用

1. 启动后菜单栏出现图标，左键展开面板
2. 「订阅 URL」**已预填**公开仓库地址（见下），首次启动即自动拉取节点，无需手动粘贴；也可在此改为你自己的订阅（节点列表或完整配置均可）
3. 点「应用并重启」→ mihomo 拉起，节点出现在面板
4. 点击节点切换，或「测速全部」查看延迟
5. 退出：面板底部「退出应用」按钮，或菜单「退出」（⌘Q）

### 预构建（免编译）

`build/clashVPN.app.zip` 为已打包好的成品（内嵌 mihomo 核心），解压后直接拖到「应用程序」或双击运行即可：

```bash
# 解压
tar -xzf build/clashVPN.app.zip -C ~/Applications  # 或双击解压到任意位置
xattr -d com.apple.quarantine ~/Applications/clashVPN.app   # 若被拦截
open ~/Applications/clashVPN.app
```

> 预构建包不随源码提交（`.gitignore` 排除），仅在本地 `build/` 目录提供。

### 订阅托管（clash.yaml）

`subscription/clash.yaml` 已托管到公开仓库 `jarodHAN/clash-yaml`（分支 `main`），**App 默认即填此地址**：

```
https://raw.githubusercontent.com/jarodHAN/clash-yaml/main/subscription/clash.yaml
```

详见 `subscription/README.md`。公开仓库会暴露节点信息，注意风险；机密场景建议私有仓库 + token raw 链接，或 App 内直连机场订阅。

## 已知限制

- 仅 x86_64；非 Apple Silicon 原生
- 完整配置模式下，「更新」按钮不会自动重载（无 `sub` provider），需重新下载并重启核心
- 默认规则仅用域名分流；GEOIP 规则需 `geoip.metadb` 才启用
