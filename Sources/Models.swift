import Foundation

struct ClashVersion: Codable {
    let version: String
    let meta: Bool?
}

struct Proxy: Identifiable, Codable {
    let name: String
    let type: String
    let now: String?
    let all: [String]?
    let udp: Bool?
    var id: String { name }
}

struct ProxiesResponse: Codable {
    let proxies: [String: Proxy]
}

struct ProviderInfo: Identifiable, Codable {
    let name: String
    let type: String
    let vehicleType: String?
    var id: String { name }
}

struct ProvidersResponse: Codable {
    let providers: [String: ProviderInfo]
}

/// 可选的预设订阅地址（公开 YAML），用户可在 UI 中一键填入。
struct PresetSubscription: Identifiable {
    let id: String      // 稳定字符串，便于 Picker 选中
    let name: String
    let url: String
}
