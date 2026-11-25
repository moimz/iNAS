import CryptoKit
import Foundation
import Security

/// 앱·파일 제공 확장·인증 화면 확장이 함께 쓰는 설정.
/// 서버 목록은 App Group UserDefaults, 비밀번호는 App Group 키체인, 썸네일 캐시는 App Group 폴더.
enum Shared {
    static let appGroup = "group.com.moimz.iNAS"
    static var defaults: UserDefaults { UserDefaults(suiteName: appGroup) ?? .standard }
}

/// 파일 앱에 위치 하나로 보이는 NAS 서버
struct NASServer: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var name = ""
    var host = ""
    var port: Int?
    var username = ""
    /// 파일 앱에 보일 공유 (iNAS 에서 연결하기로 고른 것)
    var shares: [String] = []
}

enum ServerStore {
    private static let key = "servers"

    static func all() -> [NASServer] {
        guard let data = Shared.defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([NASServer].self, from: data)) ?? []
    }

    static func save(_ servers: [NASServer]) {
        Shared.defaults.set(try? JSONEncoder().encode(servers), forKey: key)
    }

    static func server(id: String) -> NASServer? {
        all().first { $0.id == id }
    }
}

/// NAS 비밀번호 (App Group 키체인 — 앱과 확장이 같이 읽는다)
enum PasswordStore {
    private static func query(_ id: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.moimz.iNAS",
            kSecAttrAccount as String: id,
            kSecAttrAccessGroup as String: Shared.appGroup,
        ]
    }

    static func password(for id: String) -> String? {
        var q = query(id)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func set(_ password: String, for id: String) -> OSStatus {
        SecItemDelete(query(id) as CFDictionary)
        var add = query(id)
        add[kSecValueData as String] = Data(password.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil)
    }

    static func delete(for id: String) {
        SecItemDelete(query(id) as CFDictionary)
    }
}

/// 확장이 파일 앱에 "인증 필요" 를 알릴 때 이유를 담는 키 (인증 화면이 문구를 고른다)
enum AuthReason {
    static let key = "iNASAuthReason"
    static let loginFailed = "login"
}

/// 썸네일 캐시: 파일 제공 확장이 만든 썸네일 jpg 를 App Group 폴더에 둔다 (앱에서 크기 보기·지우기).
/// 파일 이름은 "경로 + 크기 + 바뀐 시각" 의 해시라 NAS 에서 파일이 바뀌면 새로 만든다.
/// 썸네일을 못 만든 최근 기록 (iNAS 앱 화면에 보여 줌, 최근 10개, 같은 파일은 새 기록으로 바꿈)
enum ThumbnailFailures {
    struct Entry: Codable, Identifiable, Hashable {
        var date: Date
        var serverID: String
        /// 공유 이름부터 시작하는 경로 (예: Media/영화/a.mp4)
        var path: String
        var reason: String
        var id: String { serverID + "|" + path }
        var name: String { (path as NSString).lastPathComponent }
    }

    static let limit = 10
    private static let key = "thumbnailFailures"
    private static var defaults: UserDefaults? { UserDefaults(suiteName: Shared.appGroup) }

    static func all() -> [Entry] {
        guard let data = defaults?.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    static func add(serverID: String, path: String, reason: String) {
        var entries = all().filter { !($0.serverID == serverID && $0.path == path) }
        entries.insert(Entry(date: Date(), serverID: serverID, path: path, reason: reason), at: 0)
        defaults?.set(try? JSONEncoder().encode(Array(entries.prefix(limit))), forKey: key)
    }

    static func clear(serverID: String? = nil) {
        guard let serverID else { return defaults?.removeObject(forKey: key) ?? () }
        defaults?.set(try? JSONEncoder().encode(all().filter { $0.serverID != serverID }), forKey: key)
    }
}

enum ThumbnailCache {
    static var root: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Shared.appGroup)?
            .appendingPathComponent("Library/Caches/Thumbnails", isDirectory: true)
    }

    static func url(serverID: String, path: String, size: Int64?, modified: Date?, pixels: Int) -> URL? {
        let key = "\(path)|\(size ?? -1)|\(Int(modified?.timeIntervalSince1970 ?? 0))|\(pixels)"
        let name = SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return root?.appendingPathComponent(serverID, isDirectory: true).appendingPathComponent(name + ".jpg")
    }

    static func read(_ url: URL) -> Data? {
        try? Data(contentsOf: url)
    }

    static func write(_ data: Data, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// 만들 수 없는 파일 표시: 다시 시도하지 않는다 ("캐시 지우기" 로 함께 지워짐)
    static func isFailed(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathExtension("fail").path)
    }

    static func markFailed(_ url: URL) {
        write(Data(), to: url.appendingPathExtension("fail"))
    }

    /// 만드는 중 표시. 확장이 메모리 때문에 끝나면 이 표시가 남는다 → 몇 번 남으면 실패로 본다.
    /// 표시 내용: "횟수\n서버ID\n경로" (확장이 끝난 뒤 다음 실행 때 어느 파일이었는지 실패 기록에 남기려고)
    static func beginAttempt(_ url: URL, serverID: String, path: String) -> Int {
        let marker = url.appendingPathExtension("trying")
        let count = (try? String(contentsOf: marker, encoding: .utf8))?.split(separator: "\n").first.flatMap { Int($0) } ?? 0
        write(Data("\(count + 1)\n\(serverID)\n\(path)".utf8), to: marker)
        return count
    }

    /// 남아 있는 "만드는 중" 표시들 (서버ID, 경로)
    static func attemptMarker(_ marker: URL) -> (serverID: String, path: String)? {
        guard let lines = (try? String(contentsOf: marker, encoding: .utf8))?.split(separator: "\n", omittingEmptySubsequences: false),
              lines.count >= 3 else { return nil }
        return (String(lines[1]), lines[2...].joined(separator: "\n"))
    }

    static func endAttempt(_ url: URL) {
        try? FileManager.default.removeItem(at: url.appendingPathExtension("trying"))
    }

    static func size() -> Int64 {
        guard let root, let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    static func clear(serverID: String? = nil) {
        guard let root else { return }
        try? FileManager.default.removeItem(at: serverID.map { root.appendingPathComponent($0) } ?? root)
    }
}
