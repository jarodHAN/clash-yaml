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
    @Published var statusMessage = "未启动"
    @Published var systemProxyOn = false
    /// Per-node latency keyed by "group|node". Value <0 means timeout.
    @Published var delayMap: [String: Int] = [:]

    let core = MihomoCore()
    private var controller: ClashController?
    private var trafficConn: SSEConnection?
    private var logsConn: SSEConnection?
    private var refreshTimer: Timer?
    private var lastUp: Double = 0
    private var lastDown: Double = 0

    private let udKey = "clashVPN.subscriptionURL"
    private let defaultSubscriptionURL = "https://raw.githubusercontent.com/jarodHAN/clash-yaml/main/subscription/clash.yaml"

    var onStatusChange: ((Bool) -> Void)?

    init() {
        subscriptionURL = UserDefaults.standard.string(forKey: udKey) ?? defaultSubscriptionURL
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
}
