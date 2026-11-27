import Foundation
import os

/// 앱과 에이전트(com.moimz.iNAS.agent)가 같이 쓰는 설정 저장소: 앱의 UserDefaults(com.moimz.iNAS).
/// 에이전트는 번들 ID 가 달라 standard 로 읽으면 자기 것(빈 것)을 읽는다.
enum Prefs {
    static let suiteName = "com.moimz.iNAS"
    static let defaults: UserDefaults = Bundle.main.bundleIdentifier == suiteName
        ? .standard
        : UserDefaults(suiteName: suiteName) ?? .standard
}

enum Log {
    static let app = Logger(subsystem: "com.moimz.iNAS", category: "app")
    static let mount = Logger(subsystem: "com.moimz.iNAS", category: "mount")
}

/// 서버 하나의 설정. 비밀번호는 여기에 넣지 않고 키체인에만 둔다.
struct ServerConfig: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var host: String
    var port: Int?
    var username: String
    /// 자동 연결할 공유 이름
    var shares: [String]
    var enabled: Bool = true

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        return host.isEmpty ? "새 서버" : host
    }

    var hostAndPort: String {
        if let port { return "\(host):\(port)" }
        return host
    }

    /// 키체인 항목을 가리키는 값이 같은지 비교할 때 쓴다.
    var credentialKey: CredentialKey { CredentialKey(host: host, port: port, username: username) }

    static func blank() -> ServerConfig {
        ServerConfig(name: "", host: "", port: nil, username: "", shares: [])
    }

    /// 사용자가 `smb://host:port/` 처럼 적어도 받아들인다.
    mutating func normalize() {
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        var h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = h.range(of: "://") { h = String(h[range.upperBound...]) }
        if let at = h.lastIndex(of: "@") { h = String(h[h.index(after: at)...]) }
        if let slash = h.firstIndex(of: "/") { h = String(h[..<slash]) }
        if h.filter({ $0 == ":" }).count == 1, let colon = h.firstIndex(of: ":"),
           let p = Int(h[h.index(after: colon)...]) {
            port = p
            h = String(h[..<colon])
        }
        host = h
        if port == 445 { port = nil }
        var seen = Set<String>()
        shares = shares
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
}

struct CredentialKey: Hashable {
    var host: String
    var port: Int?
    var username: String
}

final class ServerStore: ObservableObject {
    private static let serversKey = "servers.v1"
    private static let notifyKey = "notifyAfterLoginMount"
    private static let atLoginKey = "autoMountAtLogin"
    private static let remountKey = "autoRemount"

    @Published var servers: [ServerConfig] {
        didSet { Self.save(servers) }
    }

    @Published var notifyAfterLoginMount: Bool {
        didSet { Prefs.defaults.set(notifyAfterLoginMount, forKey: Self.notifyKey) }
    }

    /// 설정 > 서버 > 시작 시 자동 연결 (에이전트가 로그인할 때 연결)
    @Published var autoMountAtLogin: Bool {
        didSet { Prefs.defaults.set(autoMountAtLogin, forKey: Self.atLoginKey) }
    }

    /// 설정 > 서버 > 연결 해제 시 자동 연결 (깨어남 · 네트워크 변경 · 서버가 끊겼다 돌아올 때)
    @Published var autoRemount: Bool {
        didSet { Prefs.defaults.set(autoRemount, forKey: Self.remountKey) }
    }

    init() {
        servers = Self.loadServers()
        notifyAfterLoginMount = Self.loadNotifyPreference()
        autoMountAtLogin = Self.loadAutoMountAtLogin()
        autoRemount = Self.loadAutoRemount()
    }

    func index(of id: ServerConfig.ID) -> Int? {
        servers.firstIndex { $0.id == id }
    }

    func upsert(_ server: ServerConfig) {
        if let i = index(of: server.id) {
            servers[i] = server
        } else {
            servers.append(server)
        }
    }

    func remove(id: ServerConfig.ID) {
        guard let i = index(of: id) else { return }
        let server = servers.remove(at: i)
        Keychain.deletePassword(for: server.credentialKey)
    }

    // MARK: 저장소

    static func loadServers() -> [ServerConfig] {
        guard let data = Prefs.defaults.data(forKey: serversKey) else { return [] }
        do {
            return try JSONDecoder().decode([ServerConfig].self, from: data)
        } catch {
            Log.app.error("서버 설정을 읽지 못했습니다: \(error.localizedDescription)")
            return []
        }
    }

    static func loadNotifyPreference() -> Bool {
        Prefs.defaults.object(forKey: notifyKey) as? Bool ?? true
    }

    static func loadAutoMountAtLogin() -> Bool {
        Prefs.defaults.object(forKey: atLoginKey) as? Bool ?? true
    }

    static func loadAutoRemount() -> Bool {
        Prefs.defaults.object(forKey: remountKey) as? Bool ?? true
    }

    private static func save(_ servers: [ServerConfig]) {
        do {
            let data = try JSONEncoder().encode(servers)
            Prefs.defaults.set(data, forKey: serversKey)
        } catch {
            Log.app.error("서버 설정을 저장하지 못했습니다: \(error.localizedDescription)")
        }
    }
}
