import Foundation
import SwiftUI

final class AppState: ObservableObject {
    @Published var isRunning = false
    @Published var mode = "rule"
    @Published var version = "—"
    @Published var groups: [Proxy] = []
    @Published var logs: [String] = []
    @Published var upSpeed: Double = 0
    @Published var downSpeed: Double = 0
    @Published var subscriptionURL = ""
    /// 当前选中的预设订阅 ID（与 Picker 绑定）。自定义输入时为 "custom"。
    @Published var selectedPresetID: String = ""
    @Published var statusMessage = "未启动"
    @Published var systemProxyOn = false
    /// Per-node latency keyed by "group|node". Value <0 means timeout.
    @Published var delayMap: [String: Int] = [:]

    // 订阅地址连通性测试结果
    @Published var subscriptionTesting = false
    @Published var subscriptionTestResult = ""
    // 代理通路测试结果（经本地 mixed-port 实测出网）
    @Published var connectivityTesting = false
    @Published var connectivityResult = ""

    let core = MihomoCore()
    private var controller: ClashController?
    private var trafficConn: SSEConnection?
    private var logsConn: SSEConnection?
    private var refreshTimer: Timer?
    private var lastUp: Double = 0
    private var lastDown: Double = 0

    private let udKey = "clashVPN.subscriptionURL"
    /// 默认订阅：公开 Clash-Meta 节点聚合，走 ghproxy 镜像以保证本机可达。
    private let defaultSubscriptionURL = "https://ghproxy.net/https://raw.githubusercontent.com/chengaopan/AutoMergePublicNodes/master/list.meta.yml"

    /// 可选订阅地址列表（公开 YAML）。raw.githubusercontent.com 在国内被墙，
    /// 统一加 ghproxy.net 镜像前缀确保可达。
    let presetSubscriptions: [PresetSubscription] = [
        PresetSubscription(id: "direct",    name: "直连（不使用订阅）", url: ""),
        PresetSubscription(id: "automerged", name: "AutoMergePublicNodes (Meta)", url: "https://ghproxy.net/https://raw.githubusercontent.com/chengaopan/AutoMergePublicNodes/master/list.meta.yml"),
        PresetSubscription(id: "proxypool", name: "proxypool (Meta)", url: "https://ghproxy.net/https://raw.githubusercontent.com/snakem982/proxypool/main/source/clash-meta-2.yaml"),
        PresetSubscription(id: "mfuu",      name: "mfuu/FreeProxies", url: "https://ghproxy.net/https://raw.githubusercontent.com/mfuu/FreeProxies/master/sub.yaml"),
        PresetSubscription(id: "freenodes", name: "FreeNodes (AI)", url: "https://ghproxy.net/https://raw.githubusercontent.com/Barabama/FreeNodes/feat/ai-crawler-v2/nodes/merged.yaml"),
        PresetSubscription(id: "lyqnihao",  name: "lyqnihao/proxy (Meta)", url: "https://ghproxy.net/https://raw.githubusercontent.com/lyqnihao/proxy/main/clash-meta/output.yaml"),
        PresetSubscription(id: "kooker",    name: "FreeSubsCheck (Meta)", url: "https://ghproxy.net/https://raw.githubusercontent.com/kooker/FreeSubsCheck/main/mihomo.yaml"),
        PresetSubscription(id: "shuaidaoya",name: "shuaidaoya/FreeNodes", url: "https://ghproxy.net/https://raw.githubusercontent.com/shuaidaoya/FreeNodes/main/nodes/all.yaml"),
        PresetSubscription(id: "mine",      name: "我的 clash-yaml", url: "https://ghproxy.net/https://raw.githubusercontent.com/jarodHAN/clash-yaml/main/subscription/clash.yaml")
    ]

    var onStatusChange: ((Bool) -> Void)?

    init() {
        subscriptionURL = UserDefaults.standard.string(forKey: udKey) ?? defaultSubscriptionURL
        selectedPresetID = presetSubscriptions.first(where: { $0.url == subscriptionURL })?.id ?? "custom"
    }

    // MARK: - lifecycle

    func start() {
        statusMessage = "正在启动…"
        let sub = subscriptionURL.isEmpty ? nil : subscriptionURL
        // 订阅可能在配置阶段被下载（最多 ~25s），放到后台避免界面卡死
        DispatchQueue.global(qos: .userInitiated).async {
            self.core.start(subscription: sub) { [weak self] result in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    switch result {
                    case .success:
                        self.isRunning = true
                        self.controller = ClashController(secret: self.core.secret)
                        self.connect()
                        self.onStatusChange?(true)
                        self.setSystemProxy(true)
                        self.statusMessage = "运行中"
                    case .failure(let e):
                        self.statusMessage = "启动失败：\(e.localizedDescription)"
                        self.isRunning = false
                    }
                }
            }
        }
    }

    private func connect() {
        guard let c = controller else { return }
        c.fetchVersion { [weak self] res in
            DispatchQueue.main.async { if case .success(let v) = res { self?.version = v } }
        }
        refreshProxies()
        trafficConn = c.subscribeTraffic { [weak self] up, down in
            DispatchQueue.main.async {
                self?.upSpeed = max(0, up - (self?.lastUp ?? 0))
                self?.downSpeed = max(0, down - (self?.lastDown ?? 0))
                self?.lastUp = up
                self?.lastDown = down
            }
        }
        logsConn = c.subscribeLogs { [weak self] line in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.logs.append(line)
                let overflow = self.logs.count - 300
                if overflow > 0 { self.logs.removeFirst(overflow) }
            }
        }
        // Periodically refresh the proxy list so auto-updated subscriptions show up.
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.refreshProxies()
        }
    }

    func refreshProxies() {
        controller?.fetchProxies { [weak self] res in
            DispatchQueue.main.async { if case .success(let g) = res { self?.groups = g } }
        }
        controller?.fetchMode { [weak self] m in
            DispatchQueue.main.async { self?.mode = m }
        }
    }

    func selectNode(group: String, node: String) {
        controller?.selectProxy(group, node: node) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.refreshProxies() }
        }
    }

    func setMode(_ m: String) {
        mode = m
        controller?.setMode(m) { _ in }
    }

    func testDelay(group: String, completion: @escaping (Int?) -> Void) {
        controller?.testDelay(group, completion: completion)
    }

    // MARK: - per-node delay

    private func delayKey(group: String, node: String) -> String { "\(group)|\(node)" }

    func delay(for node: String, group: String) -> Int? {
        delayMap[delayKey(group: group, node: node)]
    }

    /// Test latency of every node in a group and store the results in `delayMap`.
    func testAll(group: Proxy) {
        let gname = group.name
        let nodes = group.all ?? []
        guard !nodes.isEmpty else { return }
        for node in nodes {
            controller?.testDelay(node) { [weak self] result in
                DispatchQueue.main.async {
                    self?.delayMap[self?.delayKey(group: gname, node: node) ?? ""] = result ?? -1
                }
            }
        }
    }

    // MARK: - subscription

    /// Persist and (re)apply the subscription: full core restart with the new URL.
    func applySubscription() {
        UserDefaults.standard.set(subscriptionURL, forKey: udKey)
        stopInternal {
            self.start()
        }
    }

    /// Force-refresh the already-loaded HTTP subscription via the controller, then refresh the list.
    func updateSubscription() {
        controller?.updateSubscription { [weak self] ok in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self?.statusMessage = ok ? "订阅已更新" : (self?.statusMessage ?? "")
                self?.refreshProxies()
            }
        }
    }

    // MARK: - 可选订阅地址

    /// 把选中的预设订阅地址填进 subscriptionURL（不立即应用，由用户点「应用」）。
    func usePreset(_ id: String) {
        guard let p = presetSubscriptions.first(where: { $0.id == id }) else { return }
        subscriptionURL = p.url
    }

    /// 测试订阅地址「通路」：拉取 URL 并校验内容是否为合法 Clash YAML。
    func testSubscriptionURL() {
        let url = subscriptionURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else {
            subscriptionTestResult = "⚠️ 地址为空"
            return
        }
        subscriptionTesting = true
        subscriptionTestResult = "测试通路中…"
        DispatchQueue.global(qos: .userInitiated).async {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("clashvpn_subtest_\(UUID().uuidString).yaml")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            p.arguments = ["-sL", "-o", tmp.path,
                           "-w", "%{http_code} %{time_total} %{size_download}",
                           "--max-time", "25", url]
            let pipe = Pipe()
            p.standardOutput = pipe
            try? p.run()
            p.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let parts = out.split(separator: " ")
            let code = parts.first.map(String.init) ?? "?"
            let time = parts.count > 1 ? String(parts[1]) : "?"
            let size = parts.count > 2 ? String(parts[2]) : "0"
            let sizeKB = (Int(size) ?? 0) / 1024
            let content = (try? String(contentsOf: tmp, encoding: .utf8)) ?? ""
            let looksYaml = content.contains("proxies:")
                || content.contains("proxy-providers:")
                || content.contains("rules:")
            DispatchQueue.main.async {
                self.subscriptionTesting = false
                if p.terminationStatus == 0 && code == "200" && looksYaml {
                    self.subscriptionTestResult = "✅ 可达（\(time)s，\(sizeKB)KB）内容有效"
                } else if p.terminationStatus == 0 && code == "200" {
                    self.subscriptionTestResult = "⚠️ 可达但内容不像 Clash YAML（HTTP 200）"
                } else {
                    self.subscriptionTestResult = "❌ 无法连接（HTTP \(code)，退出码 \(p.terminationStatus)）"
                }
            }
        }
    }

    // MARK: - 代理通路测试

    /// 测试代理「通路」：经由本地 mixed-port 代理实测能否出网（generate_204）。
    func testConnectivity() {
        guard isRunning else {
            connectivityResult = "未运行，请先启动"
            return
        }
        connectivityTesting = true
        connectivityResult = "正在测试通路…"
        let port = core.mixedPort
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 20
        config.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable: 1,
            kCFNetworkProxiesHTTPProxy: "127.0.0.1",
            kCFNetworkProxiesHTTPPort: port,
            kCFNetworkProxiesHTTPSEnable: 1,
            kCFNetworkProxiesHTTPSProxy: "127.0.0.1",
            kCFNetworkProxiesHTTPSPort: port
        ]
        let session = URLSession(configuration: config)
        let start = Date()
        let url = URL(string: "http://www.gstatic.com/generate_204")!
        session.dataTask(with: url) { _, resp, err in
            DispatchQueue.main.async {
                self.connectivityTesting = false
                guard let http = resp as? HTTPURLResponse else {
                    if let err = err {
                        self.connectivityResult = "❌ 通路失败：\(err.localizedDescription)"
                    } else {
                        self.connectivityResult = "❌ 通路失败：无响应"
                    }
                    return
                }
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                if (200...399).contains(http.statusCode) {
                    self.connectivityResult = "✅ 通路正常（\(ms)ms，HTTP \(http.statusCode)）"
                } else {
                    self.connectivityResult = "⚠️ 通路有响应但异常（HTTP \(http.statusCode)）"
                }
            }
        }.resume()
    }

    func stop() {
        stopInternal {
            DispatchQueue.main.async {
                self.isRunning = false
                self.onStatusChange?(false)
                self.setSystemProxy(false)
                self.statusMessage = "已停止"
            }
        }
    }

    private func stopInternal(then: @escaping () -> Void) {
        refreshTimer?.invalidate()
        refreshTimer = nil
        trafficConn?.close()
        logsConn?.close()
        trafficConn = nil
        logsConn = nil
        core.stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { then() }
    }

    func setSystemProxy(_ on: Bool) {
        systemProxyOn = on
        core.setSystemProxy(enabled: on)
    }

    /// 清除一次性授权标记并重设系统代理，用于 sudoers 安装失败/取消后重试。
    func reauthorizeProxy() {
        core.resetSudoersAuthorization()
        setSystemProxy(true)
    }
}
