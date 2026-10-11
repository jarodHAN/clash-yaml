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

    func buildConfig(subscription: String?) -> String {
        var l = [String]()
        l.append("mixed-port: \(mixedPort)")
        l.append("mode: rule")
        l.append("log-level: info")
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
        l.append("proxy-groups:")
        if let sub = subscription, !sub.isEmpty {
            // Subscription nodes are pulled in via a proxy-provider and referenced by the group.
            l.append("proxy-providers:")
            l.append("  sub:")
            l.append("    type: http")
            l.append("    url: \"\(sub)\"")
            l.append("    interval: 3600")
            l.append("    path: ./subscription.yaml")
            l.append("    health-check:")
            l.append("      enable: true")
            l.append("      url: http://www.gstatic.com/generate_204")
            l.append("      interval: 300")
            l.append("")
            l.append("  - name: PROXY")
            l.append("    type: select")
            l.append("    use:")
            l.append("      - sub")
            l.append("    proxies:")
            l.append("      - DIRECT")
        } else {
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
        let deadline = Date().addingTimeInterval(12)
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
