import Foundation

/// 폴더 상세 창(탐색 · 받기 · 보내기)에 보여 줄 정보. 에이전트 메모리에만 두고, 다시 뜨면 새로 쌓는다(사용자 2026-11-28).
struct SyncFolderDetail: Codable, Equatable {
    struct Scan: Codable, Equatable {
        enum Phase: String, Codable { case idle, events, full }
        var phase: Phase = .idle
        /// 변경 신호를 처리하느라 전체 재탐색이 기다리는 중
        var fullWaiting = false
        /// 지금 훑는 하위 폴더 (폴더 기준 경로, "" = 맨 위)
        var dir: String?
        var checked = 0
        var lastFull: Date?
        /// 재탐색 간격(초), 0 = 끔
        var interval: TimeInterval = 3600
    }

    struct Change: Codable, Equatable, Identifiable {
        enum Action: String, Codable { case added, modified, deleted }
        enum Origin: Codable, Equatable {
            /// 이 Mac · 파일 변경 신호(FSEvents)로 앎
            case event
            /// 이 Mac · 재탐색으로 앎
            case rescan
            /// 다른 Mac 에서 받음 (키 아이디)
            case peer(String)
        }
        var id = UUID()
        var date: Date
        var path: String
        var action: Action
        var origin: Origin
    }

    struct Transfer: Codable, Equatable, Identifiable {
        var since: Date
        var path: String
        /// 받는 곳 / 보낼 곳 (키 아이디)
        var peer: String
        var done: Int64
        var total: Int64
        /// 지금 주고받는 중
        var active: Bool
        var id: String { peer + "|" + path }
    }

    var scan = Scan()
    /// 최근 변경 (새것이 앞, 최대 changeLimit)
    var changes: [Change] = []
    /// 받을 것 (앞에서 rowLimit 개까지) · 전체 수 · 전체 크기
    var receive: [Transfer] = []
    var receiveCount = 0
    var receiveBytes: Int64 = 0
    /// 보낼 것 (기기마다 따로 줄)
    var send: [Transfer] = []
    var sendCount = 0
    var sendBytes: Int64 = 0

    /// 다른 Mac 에 달라고 하고 아직 답을 못 받음
    var waiting = false
    static var waiting: SyncFolderDetail { var d = SyncFolderDetail(); d.waiting = true; return d }

    static let changeLimit = 1000
    static let rowLimit = 500

    static func decode(_ data: Data) -> SyncFolderDetail? {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try? d.decode(SyncFolderDetail.self, from: data)
    }

    func encoded() -> Data {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return (try? e.encode(self)) ?? Data()
    }
}

/// 상세 정보 보관함. 엔진(actor)이 훑는 동안에도 창이 바로 읽을 수 있게 잠금으로 따로 둔다
final class SyncDetailBox: @unchecked Sendable {
    private let lock = NSLock()
    private var details: [String: SyncFolderDetail] = [:]

    func get(_ id: String) -> SyncFolderDetail {
        lock.lock(); defer { lock.unlock() }
        return details[id] ?? SyncFolderDetail()
    }

    func update(_ id: String, _ change: (inout SyncFolderDetail) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var d = details[id] ?? SyncFolderDetail()
        change(&d)
        details[id] = d
    }

    func remove(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        details[id] = nil
    }

    func record(_ id: String, _ changes: [SyncFolderDetail.Change]) {
        guard !changes.isEmpty else { return }
        update(id) { d in
            d.changes.insert(contentsOf: changes.reversed(), at: 0)
            if d.changes.count > SyncFolderDetail.changeLimit { d.changes.removeLast(d.changes.count - SyncFolderDetail.changeLimit) }
        }
    }
}
