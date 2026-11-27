import Foundation
import Security

/// SMB 비밀번호를 로그인 키체인의 인터넷 암호(kSecClassInternetPassword)로 보관한다.
enum Keychain {
    struct Failure: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "알 수 없는 오류"
            return "키체인 오류 (\(status)): \(message)"
        }
    }

    private static func query(for key: CredentialKey) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: key.host,
            kSecAttrAccount as String: key.username,
            kSecAttrProtocol as String: kSecAttrProtocolSMB,
        ]
        if let port = key.port {
            q[kSecAttrPort as String] = port
        }
        return q
    }

    static func password(for key: CredentialKey) -> String? {
        guard !key.host.isEmpty, !key.username.isEmpty else { return nil }
        var q = query(for: key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound {
                Log.app.error("키체인에서 비밀번호를 읽지 못했습니다: \(status)")
            }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func hasPassword(for key: CredentialKey) -> Bool {
        guard !key.host.isEmpty, !key.username.isEmpty else { return false }
        var q = query(for: key)
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        // 데이터를 요청하지 않으면 접근 허용 창 없이 존재 여부만 확인할 수 있다.
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    static func setPassword(_ password: String, for key: CredentialKey) throws {
        let data = Data(password.utf8)
        let q = query(for: key)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(q as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = q
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = key.port.map { "\(key.host):\($0)" } ?? key.host
            add[kSecAttrComment as String] = "iNAS 앱이 저장한 SMB 암호"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    static func deletePassword(for key: CredentialKey) {
        guard !key.host.isEmpty, !key.username.isEmpty else { return }
        SecItemDelete(query(for: key) as CFDictionary)
    }
}
