import CryptoKit
import Foundation
import Security

/// 이 Mac 의 동기화 키(Curve25519). 비밀 키는 로그인 키체인에만 두고, 공개 키만 iCloud 기기 기록에 올린다.
enum SyncKeyStore {
    /// 에이전트가 만들고 쓴다. (빌드 68~69 는 앱 창이 com.moimz.iNAS.sync-key 로 만들었다 → 앱이 한 번 지움)
    private static let service = "com.moimz.iNAS.agent.sync-key"
    static let oldAppService = "com.moimz.iNAS.sync-key"

    /// 앱 창이 만들었던 옛 키 지우기 (앱 창에서 부름: 자기가 만든 항목이라 묻지 않는다)
    static func removeOldAppKey() {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: oldAppService,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(q as CFDictionary)
    }
    private static let account = "device"

    static func loadOrCreate() -> SyncIdentity {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
           let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data) {
            return SyncIdentity(privateKey: key)
        }
        let key = Curve25519.KeyAgreement.PrivateKey()
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: "iNAS 동기화 키",
            kSecAttrComment as String: "iNAS 가 기기끼리 암호화 연결에 쓰는 이 Mac 의 비밀 키",
            kSecValueData as String: key.rawRepresentation,
        ]
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess { Log.app.error("동기화 키를 키체인에 못 넣음: \(status)") }
        return SyncIdentity(privateKey: key)
    }
}
