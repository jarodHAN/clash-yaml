import Foundation

final class MihomoCore {
    let mixedPort = 7890
    let controllerPort = 9090
    let secret = "clashvpn-\(UUID().uuidString)"
    private(set) var process: Process?
    /// 持久标志：是否已尝试过一次性 sudoers 授权（避免反复弹管理员密码框）。
    private let sudoersTriedKey = "clashVPN.sudoersTried"

    var configDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("clashVPN", isDirectory: true)
    }
    var configFile: URL { configDir.appendingPathComponent("config.yaml") }

    /// Locate the embedded mihomo binary (inside .app Resources, or next to the executable for dev runs).
    func mihomoPath() -> String? {
        if let p = Bundle.main.path(forResource: "mihomo", ofType: nil),
           FileManager.default.fileExists(atPath: p) { return p }
        if let exe = Bundle.main.executableURL {
            let candidates = [
                exe.deletingLastPathComponent().appendingPathComponent("mihomo"),
                exe.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("mihomo")
            ]
            for c in candidates where FileManager.default.fileExists(atPath: c.path) { return c.path }
        }
        return nil
    }

    // MARK: - config building

    /// Build the final mihomo config for the given subscription.
    ///
    /// Three cases:
    /// 1. No subscription  -> minimal local config.
    /// 2. Full-clash-config subscription (has top-level `rules:`/`script:`/`hosts:`) -> use it as the
    ///    main config, only appending controller fields that are NOT already present (avoids the
    ///    "mapping key already defined" fatal parse error that crashes mihomo on startup).
    /// 3. Node-list subscription -> write it to `subscription.yaml` and reference it via a `file` provider
    ///    (no runtime network needed). If it cannot be fetched, fall back to an `http` provider using the URL.
    func buildConfig(subscription: String?) -> String {
        guard let sub = subscription, !sub.isEmpty else {
            return minimalConfig()
        }

        if let content = resolveSubscriptionContent(sub) {
            if isFullConfig(content) {
                return makeFullConfig(from: content)
            }
            // Node list: embed locally so we don't depend on runtime network.
            try? content.write(to: configDir.appendingPathComponent("subscription.yaml"),
                              atomically: true, encoding: .utf8)
            return minimalConfig(providerType: "file", providerPath: "./subscription.yaml", providerURL: nil)
        }

        // Could not fetch (e.g. offline / blocked host): let mihomo pull it at runtime.
        return minimalConfig(providerType: "http", providerPath: "./subscription.yaml", providerURL: sub)
    }

    private func minimalConfig() -> String {
        minimalConfig(providerType: nil, providerPath: nil, providerURL: nil)
    }

    private func minimalConfig(providerType: String?, providerPath: String?, providerURL: String?) -> String {
        var l = [String]()
        l.append("mixed-port: \(mixedPort)")
        l.append("mode: rule")
        l.append("log-level: info")
        l.append("allow-lan: false")
        l.append("external-controller: 127.0.0.1:\(controllerPort)")
        l.append("secret: \"\(secret)\"")
        l.append("")
        l.append("dns:")
        l.append("  enable: true")
        l.append("  enhanced-mode: fake-ip")
        l.append("  nameserver:")
        l.append("    - 223.5.5.5")
        l.append("    - 119.29.29.29")
        l.append("")
        l.append("proxies: []")

        if let pType = providerType, let pPath = providerPath {
            l.append("proxy-providers:")
            l.append("  sub:")
            l.append("    type: \(pType)")
            if let url = providerURL {
                l.append("    url: \"\(url)\"")
                l.append("    interval: 3600")
            }
            l.append("    path: \(pPath)")
            l.append("    health-check:")
            l.append("      enable: true")
            l.append("      url: http://www.gstatic.com/generate_204")
            l.append("      interval: 300")
            l.append("")
            l.append("proxy-groups:")
            l.append("  - name: PROXY")
            l.append("    type: select")
            l.append("    use:")
            l.append("      - sub")
            l.append("    proxies:")
            l.append("      - DIRECT")
        } else {
            l.append("proxy-groups:")
            l.append("  - name: PROXY")
            l.append("    type: select")
            l.append("    proxies:")
            l.append("      - DIRECT")
        }

        l.append("rules:")
        if hasGeoIP {
            l.append("  - GEOIP,CN,DIRECT")
        }
        l.append("  - DOMAIN-SUFFIX,cn,DIRECT")
        l.append("  - DOMAIN-KEYWORD,cn,DIRECT")
        l.append("  - MATCH,PROXY")
        return l.joined(separator: "\n")
    }

    /// Use a full subscription as the main config. Only append controller keys that are missing,
    /// so we never create a duplicate top-level key (which makes mihomo fatal-exit on startup).
    private func makeFullConfig(from content: String) -> String {
        var out = content
        if !out.hasSuffix("\n") { out += "\n" }
        let needed: [(key: String, value: String)] = [
            ("mixed-port", "\(mixedPort)"),
            ("mode", "rule"),
            ("log-level", "info"),
            ("allow-lan", "true"),
            ("external-controller", "127.0.0.1:\(controllerPort)"),
            ("secret", "\"\(secret)\"")
        ]
        for (k, v) in needed where !hasTopLevelKey(content, k) {
            out += "\(k): \(v)\n"
        }
        return out
    }

    /// A full clash config (vs a node-only list) is identified by top-level keys that never appear
    /// in a standalone proxy-provider file.
    private func isFullConfig(_ content: String) -> Bool {
        for marker in ["\nrules:", "\nscript:", "\nhosts:"] {
            if content.contains(marker) { return true }
        }
        return false
    }

    /// Resolve subscription content from a local path / file:// URL, or download an http(s) URL.
    /// Returns nil if it cannot be obtained (caller falls back to runtime http provider).
    private func resolveSubscriptionContent(_ sub: String) -> String? {
        // Local file or file:// URL
        var path = sub
        if sub.lowercased().hasPrefix("file://") {
            if let u = URL(string: sub) { path = u.path }
        }
        if FileManager.default.fileExists(atPath: path),
           let c = try? String(contentsOfFile: path, encoding: .utf8), !c.isEmpty {
            return c
        }
        // http(s): download via curl (reuses system proxy/network)
        if sub.lowercased().hasPrefix("http") {
            let tmp = configDir.appendingPathComponent("subscription_download.yaml")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            p.arguments = ["-sL", "--max-time", "25", "-o", tmp.path, sub]
            try? p.run()
            p.waitUntilExit()
            if p.terminationStatus == 0,
               let c = try? String(contentsOf: tmp, encoding: .utf8), !c.isEmpty {
                return c
            }
        }
        return nil
    }

    private func hasTopLevelKey(_ content: String, _ key: String) -> Bool {
        for line in content.components(separatedBy: "\n") {
            if line.hasPrefix(" ") || line.hasPrefix("\t") { continue }
            if line == "\(key):" || line.hasPrefix("\(key): ") || line.hasPrefix("\(key):\t") {
                return true
            }
        }
        return false
    }

    func prepareConfig(subscription: String?) {
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        stageGeoFiles()
        let yaml = buildConfig(subscription: subscription)
        try? yaml.write(to: configFile, atomically: true, encoding: .utf8)
    }

    /// Copy pre-bundled geo databases (geoip.metadb / geosite.dat) into the config dir
    /// so mihomo does not need to download them at startup. Best-effort.
    private func stageGeoFiles() {
        let files = [("geoip", "metadb"), ("geosite", "dat")]
        for (base, ext) in files {
            if let src = Bundle.main.url(forResource: base, withExtension: ext),
               FileManager.default.fileExists(atPath: src.path) {
                let dst = configDir.appendingPathComponent("\(base).\(ext)")
                if !FileManager.default.fileExists(atPath: dst.path) {
                    try? FileManager.default.copyItem(at: src, to: dst)
                }
            }
        }
    }

    private var hasGeoIP: Bool {
        FileManager.default.fileExists(atPath: configDir.appendingPathComponent("geoip.metadb").path)
    }

    func start(subscription: String?, completion: @escaping (Result<Void, Error>) -> Void) {
        prepareConfig(subscription: subscription)
        guard let exe = mihomoPath() else {
            completion(.failure(NSError(domain: "clashVPN", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "找不到 mihomo 核心，请先运行 build.sh 下载"])))
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["-d", configDir.path, "-f", configFile.path]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do { try p.run() } catch { completion(.failure(error)); return }
        process = p

        let secret = self.secret
        let deadline = Date().addingTimeInterval(15)
        func poll() {
            if Date() > deadline {
                if process?.isRunning == true {
                    completion(.success(()))
                } else {
                    completion(.failure(NSError(domain: "clashVPN", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "mihomo 启动后退出，请查看日志"])))
                }
                return
            }
            if process?.isRunning != true {
                completion(.failure(NSError(domain: "clashVPN", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "mihomo 启动后退出，请查看日志"])))
                return
            }
            let c = ClashController(secret: secret)
            c.fetchVersion { res in
                if case .success = res {
                    completion(.success(()))
                } else {
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1) { poll() }
                }
            }
        }
        poll()
    }

    func stop() {
        let proc = process
        proc?.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if let p = proc, p.isRunning { p.interrupt() }
        }
        process = nil
    }

    /// Toggle the macOS system HTTP/HTTPS proxy through the primary network service.
    ///
    /// 设计目标：**绝不反复弹管理员密码框**。
    /// 1. 优先尝试 `sudo -n networksetup`（无需密码）。sudoers 规则文件持久存在，
    ///    即使 App 重启也依然静默可用。
    /// 2. 仅当 `sudo -n` 失败（尚未授权）时，弹**一次**管理员密码框写入
    ///    `/etc/sudoers.d/clashvpn`；用 UserDefaults 持久标记「已尝试」，之后不再弹。
    /// 3. 若用户取消授权导致 sudoers 未写入，则静默降级（系统代理保持原状），不再打扰。
    func setSystemProxy(enabled: Bool) {
        DispatchQueue.global().async {
            let service = self.activeService()
            let port = "\(self.mixedPort)"
            // 关键：networksetup 的启用/禁用语法与直觉不同——
            //   启用： -setwebproxy <svc> <server> <port>        （不带 state）
            //   禁用： -setwebproxy <svc> off                    （独立 off 才真正关闭）
            // 旧代码把 "on"/"off" 当作第 5 个参数（authenticated，需要用户名/密码），
            // 导致启用时报 “parameters were not valid” 而失败 → 反复弹管理员密码框。
            let webArgs: [String]
            let secureArgs: [String]
            if enabled {
                webArgs = ["-setwebproxy", service, "127.0.0.1", port]
                secureArgs = ["-setsecurewebproxy", service, "127.0.0.1", port]
            } else {
                webArgs = ["-setwebproxy", service, "off"]
                secureArgs = ["-setsecurewebproxy", service, "off"]
            }

            // 1) 无密码 sudo（sudoers 已装好 -> 静默成功）
            let ok1 = self.runSudoNetworksetup(webArgs)
            let ok2 = self.runSudoNetworksetup(secureArgs)
            if ok1, ok2 { return }

            // 2) 尚未授权：仅弹一次安装 sudoers 规则
            if !UserDefaults.standard.bool(forKey: self.sudoersTriedKey) {
                self.ensureSudoProxyAccess()  // 单次管理员弹窗
                UserDefaults.standard.set(true, forKey: self.sudoersTriedKey)
                if self.runSudoNetworksetup(webArgs), self.runSudoNetworksetup(secureArgs) {
                    return
                }
            }

            // 3) 授权失败/取消：静默降级，不再弹窗（系统代理保持原状）。
        }
    }

    // MARK: - privileged proxy access (one-time sudoers setup)

    /// Run a `networksetup` subcommand via passwordless sudo. Returns success.
    private func runSudoNetworksetup(_ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", "/usr/sbin/networksetup"] + args
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// 清除「已尝试授权」标记，下次 setSystemProxy 会再次弹一次窗安装 sudoers。
    /// 供 UI「重新授权」按钮调用，便于用户 sudoers 装失败/取消后重试。
    func resetSudoersAuthorization() {
        UserDefaults.standard.removeObject(forKey: sudoersTriedKey)
    }

    /// One-time admin authorization: install a sudoers.d rule so future `networksetup`
    /// calls need no password. Triggers a single `osascript` admin-password prompt.
    private func ensureSudoProxyAccess() {
        let user = NSUserName()
        let scriptBody = """
        tmp=$(mktemp /tmp/clashvpn.XXXXXX)
        printf '%s\\n' '\(user) ALL=(root) NOPASSWD: /usr/sbin/networksetup' > "$tmp"
        visudo -cf "$tmp" && install -m 0440 "$tmp" /etc/sudoers.d/clashvpn
        rm -f "$tmp"

        """
        let tmpURL = URL(fileURLWithPath: "/tmp/clashvpn_setup.sh")
        try? scriptBody.write(to: tmpURL, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "do shell script \"bash '/tmp/clashvpn_setup.sh'\" with administrator privileges"]
        try? p.run()
        p.waitUntilExit()
        try? FileManager.default.removeItem(at: tmpURL)
    }

    /// 选出「真正用于上网」的网络服务名。
    ///
    /// `networksetup -setwebproxy` 只对真实联网接口有效；像 Thunderbolt Bridge 这类
    /// 桥接接口会报 “The parameters were not valid”。旧逻辑取列表第一个服务，恰好选中了
    /// 桥接接口，导致代理设置永远失败 → 反复弹管理员密码框。
    ///
    /// 新逻辑：取默认路由接口的 IP，再匹配各服务 `getinfo` 里的 `IP address:`，命中者即为
    /// 当前上网服务（无需管理员权限即可查询）。
    private func activeService() -> String {
        let defIP = defaultRouteIP()
        let services = listNetworkServices()
        if let ip = defIP {
            for svc in services where ipOfService(svc) == ip {
                return svc
            }
        }
        // 回退：跳过明显不支持代理的接口（桥接/蓝牙/VPN），选第一个剩余
        let skip = ["Bridge", "Bluetooth", "FireWire", "VPN", "Thunderbolt"]
        for svc in services where !skip.contains(where: { svc.contains($0) }) {
            return svc
        }
        return services.first ?? "Wi-Fi"
    }

    private func listNetworkServices() -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        p.arguments = ["-listallnetworkservices"]
        let out = Pipe()
        p.standardOutput = out
        try? p.run()
        p.waitUntilExit()
        guard let str = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else { return [] }
        return str.split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .dropFirst() // 跳过 “An asterisk (*) denotes…” 说明行
            .filter { !$0.isEmpty && !$0.hasPrefix("*") }
    }

    private func defaultRouteInterface() -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/route")
        p.arguments = ["-n", "get", "default"]
        let out = Pipe()
        p.standardOutput = out
        try? p.run()
        p.waitUntilExit()
        guard let str = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else { return "" }
        for line in str.split(separator: "\n") where line.contains("interface:") {
            return line.split(separator: ":").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        }
        return ""
    }

    private func defaultRouteIP() -> String? {
        let iface = defaultRouteInterface()
        guard !iface.isEmpty else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/ipconfig")
        p.arguments = ["getifaddr", iface]
        let out = Pipe()
        p.standardOutput = out
        try? p.run()
        p.waitUntilExit()
        let s = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (s?.isEmpty == false) ? s : nil
    }

    private func ipOfService(_ svc: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        p.arguments = ["-getinfo", svc]
        let out = Pipe()
        p.standardOutput = out
        try? p.run()
        p.waitUntilExit()
        guard let str = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else { return nil }
        for line in str.split(separator: "\n") {
            let t = String(line).trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("IP address:") {
                let ip = t.replacingOccurrences(of: "IP address:", with: "")
                          .trimmingCharacters(in: .whitespaces)
                if ip.contains(".") && ip != "none" { return ip }
            }
        }
        return nil
    }
}
