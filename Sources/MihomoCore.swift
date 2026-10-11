import Foundation

final class MihomoCore {
    let mixedPort = 7890
    let controllerPort = 9090
    let secret = "clashvpn-\(UUID().uuidString)"
    private(set) var process: Process?

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
    func setSystemProxy(enabled: Bool) {
        DispatchQueue.global().async {
            let service = self.activeService()
            let port = "\(self.mixedPort)"
            let state = enabled ? "on" : "off"
            let inner = "networksetup -setwebproxy '\(service)' 127.0.0.1 \(port) \(state); networksetup -setsecurewebproxy '\(service)' 127.0.0.1 \(port) \(state)"
            let script = "do shell script \"\(inner)\" with administrator privileges"
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", script]
            try? p.run()
            p.waitUntilExit()
        }
    }

    private func activeService() -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        p.arguments = ["-listallnetworkservices"]
        let out = Pipe()
        p.standardOutput = out
        try? p.run()
        p.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let str = String(data: data, encoding: .utf8) else { return "Wi-Fi" }
        for line in str.split(separator: "\n").dropFirst() {
            let s = line.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("*") || s.isEmpty { continue }
            return s
        }
        return "Wi-Fi"
    }
}
