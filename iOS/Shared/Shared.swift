import Foundation
import Security

/// 앱·파일 제공 확장·인증 화면 확장이 함께 쓰는 설정.
/// 서버 목록과 잠금 해제 시각은 App Group UserDefaults, 비밀번호는 App Group 키체인.
enum Shared {
    static let appGroup = "group.com.moimz.iNAS"
    /// 잠금 폴더를 마지막으로 쓴 뒤 이만큼 지나면 다시 잠근다 (앱 설정, 기본 5분)
    static var lockMinutes: Int {
        get { let v = defaults.integer(forKey: "lockMinutes"); return v > 0 ? v : 5 }
        set { defaults.set(newValue, forKey: "lockMinutes") }
    }
    static var lockInterval: TimeInterval { TimeInterval(lockMinutes * 60) }

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
    /// 잠금 폴더: "공유/경로" 형식. 그 폴더와 안쪽은 Face ID 로 연다.
    var locked: [String] = []

    /// "공유/경로" 가 잠금 폴더 안인지
    func isLocked(_ path: String) -> Bool {
        locked.contains { path == $0 || path.hasPrefix($0 + "/") }
    }
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

/// 잠금 폴더 열림 상태 (서버별). 마지막 사용 시각 + lockInterval 까지 열려 있다.
enum LockState {
    private static func key(_ id: String) -> String { "unlockedUntil.\(id)" }

    static func isUnlocked(_ id: String) -> Bool {
        Shared.defaults.double(forKey: key(id)) > Date().timeIntervalSince1970
    }

    /// Face ID 로 확인했을 때
    static func unlock(_ id: String) {
        Shared.defaults.set(Date().timeIntervalSince1970 + Shared.lockInterval, forKey: key(id))
    }

    /// 열려 있는 동안 잠금 폴더를 쓰면 시간을 늘린다
    static func touch(_ id: String) {
        if isUnlocked(id) { unlock(id) }
    }

    static func lock(_ id: String) {
        Shared.defaults.removeObject(forKey: key(id))
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
    static let lockedFolder = "locked"
    static let loginFailed = "login"
}
