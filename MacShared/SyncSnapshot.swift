import Foundation

/// 에이전트(동기화를 돌림) → 앱 창(보여 줌) 으로 보내는 동기화 상태 한 장
struct SyncSnapshot: Codable, Equatable {
    struct Peer: Codable, Equatable, Identifiable {
        var device: SyncDevice
        /// "내가 붙음 → …" / "저쪽이 붙어 오길 기다림 (…)"
        var role: String
        /// 이 기기 키가 차단됐으면 그 키 아이디
        var blockedKey: String?
        /// 공개 키 아이디 (없으면 옛 빌드)
        var keyID: String?
        /// 접속 가능 여부 (누구든 이 기기 지금 주소로 붙어 본 결과): true 확인됨 · false 막힘 · nil 확인 대기
        var reachOK: Bool?
        var reachText: String
        /// 이 Mac 과 지금 암호화 연결이 있는지
        var connected: Bool
        var id: String { device.id }
    }

    struct LogLine: Codable, Equatable {
        var date: Date
        var text: String
    }

    var me: SyncDevice
    var peers: [Peer]
    var blocked: [SyncBlockedDevice]
    var listenStatus: String
    var stunStatus: String
    var iCloudStatus: String
    var iCloudOK: Bool
    var inboundOK: Bool?
    var inboundText: String
    var folderStatus: [String: SyncFolderStatus]
    var busy: Bool
    var log: [LogLine]
    /// 이 Mac 의 키 아이디 (공개 키 SHA-256)
    var keyID: String

    static func decode(_ data: Data) -> SyncSnapshot? {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try? d.decode(SyncSnapshot.self, from: data)
    }

    func encoded() -> Data {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return (try? e.encode(self)) ?? Data()
    }
}

/// 앱 창 → 에이전트 동기화 명령
enum SyncCommand: Codable {
    /// 지금 새로 고침 (공인 IP · 포트 · iCloud · 연결)
    case refresh
    /// 이 Mac 의 폴더 설정(토글 · 로컬 폴더)이나 폴더 목록이 바뀜 → 다시 읽기
    case reloadFolders
    /// 기기 지우기(키 차단)
    case removeDevice(String)
    /// 차단 풀기
    case restoreDevice(String)

    static func decode(_ data: Data) -> SyncCommand? { try? JSONDecoder().decode(SyncCommand.self, from: data) }
    func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }
}
