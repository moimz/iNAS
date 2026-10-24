import Foundation
import os

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
    private static let seededKey = "didSeedDefaults"
    private static let notifyKey = "notifyAfterLoginMount"

    @Published var servers: [ServerConfig] {
        didSet { Self.save(servers) }
    }

    @Published var notifyAfterLoginMount: Bool {
        didSet { UserDefaults.standard.set(notifyAfterLoginMount, forKey: Self.notifyKey) }
    }

    init() {
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: Self.seededKey) {
            defaults.set(true, forKey: Self.seededKey)
            if Self.loadServers().isEmpty {
                Self.save([Self.legacyServer])
            }
        }
        servers = Self.loadServers()
        notifyAfterLoginMount = Self.loadNotifyPreference()
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
        guard let data = UserDefaults.standard.data(forKey: serversKey) else { return [] }
        do {
            return try JSONDecoder().decode([ServerConfig].self, from: data)
        } catch {
            Log.app.error("서버 설정을 읽지 못했습니다: \(error.localizedDescription)")
            return []
        }
    }

    static func loadNotifyPreference() -> Bool {
        UserDefaults.standard.object(forKey: notifyKey) as? Bool ?? true
    }

    private static func save(_ servers: [ServerConfig]) {
        do {
            let data = try JSONEncoder().encode(servers)
            UserDefaults.standard.set(data, forKey: serversKey)
        } catch {
            Log.app.error("서버 설정을 저장하지 못했습니다: \(error.localizedDescription)")
        }
    }

    /// 기존 iNAS 애플릿에서 쓰던 서버. 비밀번호는 사용자가 직접 넣는다.
    private static let legacyServer = ServerConfig(
        name: "iNAS",
        host: "nas.moimz.com",
        port: 5445,
        username: "iNas",
        shares: ["Application", "Book", "Media", "Project", "Temp", "AES"]
    )
}
