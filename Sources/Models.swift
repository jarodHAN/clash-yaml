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
