import Foundation

/// Minimal Server-Sent-Events reader over URLSession (used for /traffic and /logs).
final class SSEConnection: NSObject, URLSessionDataDelegate {
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var buffer = ""
    private let onEvent: (String) -> Void
    private let secret: String

    init(url: URL, secret: String, onEvent: @escaping (String) -> Void) {
        self.secret = secret
        self.onEvent = onEvent
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        var req = URLRequest(url: url)
        if !secret.isEmpty {
            req.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        }
        task = session?.dataTask(with: req)
        task?.resume()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let str = String(data: data, encoding: .utf8) else { return }
        buffer += str
        while let range = buffer.range(of: "\n") {
            let line = String(buffer[buffer.startIndex..<range.lowerBound])
            buffer.removeSubrange(buffer.startIndex...range.upperBound)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("data:") {
                let payload = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !payload.isEmpty { onEvent(payload) }
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Connection closed; ignore for fire-and-forget subscriptions.
    }

    func close() {
        task?.cancel()
        session?.invalidateAndCancel()
    }
}

final class ClashController {
    let base: URL
    let secret: String

    init(secret: String, host: String = "127.0.0.1", port: Int = 9090) {
        self.secret = secret
        self.base = URL(string: "http://\(host):\(port)")!
    }

    private func request(_ path: String,
                         method: String = "GET",
                         body: Data? = nil,
                         completion: @escaping (Result<Data, Error>) -> Void) {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = method
        if !secret.isEmpty {
            req.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        }
        if let body = body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        URLSession.shared.dataTask(with: req) { data, _, err in
            if let err = err { completion(.failure(err)); return }
            completion(.success(data ?? Data()))
        }.resume()
    }

    func fetchVersion(completion: @escaping (Result<String, Error>) -> Void) {
        request("version") { res in
            switch res {
            case .failure(let e): completion(.failure(e))
            case .success(let d):
                if let v = try? JSONDecoder().decode(ClashVersion.self, from: d) {
                    completion(.success(v.version))
                } else {
                    completion(.success("unknown"))
                }
            }
        }
    }

    func fetchProxies(completion: @escaping (Result<[Proxy], Error>) -> Void) {
        request("proxies") { res in
            switch res {
            case .failure(let e): completion(.failure(e))
            case .success(let d):
                if let r = try? JSONDecoder().decode(ProxiesResponse.self, from: d) {
                    let list = r.proxies.values.filter { ($0.all?.count ?? 0) > 0 }
                    completion(.success(Array(list)))
                } else {
                    completion(.success([]))
                }
            }
        }
    }

    func fetchMode(completion: @escaping (String) -> Void) {
        request("configs") { res in
            switch res {
            case .success(let d):
                if let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                   let m = json["mode"] as? String {
                    completion(m)
                } else { completion("rule") }
            case .failure: completion("rule")
            }
        }
    }

    func selectProxy(_ group: String, node: String, completion: @escaping (Bool) -> Void) {
        guard let body = try? JSONSerialization.data(withJSONObject: ["name": node]) else {
            completion(false); return
        }
        let enc = group.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? group
        request("proxies/\(enc)", method: "PUT", body: body) { res in
            switch res { case .success: completion(true); case .failure: completion(false) }
        }
    }

    func setMode(_ mode: String, completion: @escaping (Bool) -> Void) {
        guard let body = try? JSONSerialization.data(withJSONObject: ["mode": mode]) else {
            completion(false); return
        }
        // mihomo (clash-meta) uses PATCH for partial config updates (mode).
        request("configs", method: "PATCH", body: body) { res in
            switch res { case .success: completion(true); case .failure: completion(false) }
        }
    }

    func testDelay(_ name: String, completion: @escaping (Int?) -> Void) {
        let enc = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        let path = "proxies/\(enc)/delay?url=http://www.gstatic.com/generate_204&timeout=5000"
        request(path) { res in
            switch res {
            case .failure: completion(nil)
            case .success(let d):
                if let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                   let delay = json["delay"] as? Int {
                    completion(delay)
                } else { completion(nil) }
            }
        }
    }

    func subscribeTraffic(onEvent: @escaping (Double, Double) -> Void) -> SSEConnection {
        let url = base.appendingPathComponent("traffic")
        return SSEConnection(url: url, secret: secret) { line in
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let up = json["up"] as? Double,
                  let down = json["down"] as? Double else { return }
            onEvent(up, down)
        }
    }

    func subscribeLogs(onEvent: @escaping (String) -> Void) -> SSEConnection {
        let url = base.appendingPathComponent("logs?level=info")
        return SSEConnection(url: url, secret: secret) { line in
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = json["payload"] as? String else { return }
            onEvent(payload)
        }
    }

    // MARK: - Subscription providers

    func fetchProviders(completion: @escaping (Result<[ProviderInfo], Error>) -> Void) {
        request("providers/proxies") { res in
            switch res {
            case .failure(let e): completion(.failure(e))
            case .success(let d):
                if let r = try? JSONDecoder().decode(ProvidersResponse.self, from: d) {
                    completion(.success(Array(r.providers.values)))
                } else {
                    completion(.success([]))
                }
            }
        }
    }

    /// Force-refresh the HTTP subscription provider (profile). Returns true if a provider
    /// was found and the update request succeeded.
    func updateSubscription(completion: @escaping (Bool) -> Void) {
        fetchProviders { res in
            guard case .success(let list) = res else { completion(false); return }
            // The subscription provider carries vehicleType "HTTP" (mihomo proxy-provider).
            let sub = list.first(where: {
                ($0.vehicleType ?? "").uppercased() == "HTTP"
                || $0.name == "sub" || $0.name == "profile"
            })
            guard let p = sub else { completion(false); return }
            let enc = p.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? p.name
            self.request("providers/proxies/\(enc)", method: "PUT") { r in
                switch r { case .success: completion(true); case .failure: completion(false) }
            }
        }
    }
}
