import CryptoKit
import Darwin
import Foundation
import Network

/// 폴더 하나의 상태 (화면용)
struct SyncFolderStatus: Codable, Equatable {
    enum State: String, Codable { case idle, scanning, syncing, stopped, waiting }
    var state: State = .waiting
    /// 내가 받을 항목 수 · 바이트
    var needItems = 0
    var needBytes: Int64 = 0
    /// 이 기기 목록 (지운 것 빼고)
    var localFiles = 0
    var localBytes: Int64 = 0
    /// 연결된 기기 중 이 폴더를 같이 쓰는 기기 이름
    var sharedWith: [String] = []
    /// 그 기기가 받을 항목 수 (기기 아이디 → 수)
    var peerNeed: [String: Int] = [:]
    /// 그 기기 파일 수 · 크기 (첫 파일 목록을 받은 뒤부터)
    var peerFiles: [String: Int] = [:]
    var peerBytes: [String: Int64] = [:]
    var lastError: String?
    var lastSync: Date?
    /// 충돌 사본 (이름에 .sync-conflict- 가 든 파일, 폴더 기준 경로, 최대 500개)
    var conflicts: [String] = []
    /// 충돌 사본 이름 끝 기기 표시 → 기기 이름 (상세 창 "만든 기기")
    var conflictDevices: [String: String] = [:]
}

/// 기기 연결 상태 (화면 · SyncDiscovery 용)
struct SyncPeerLink: Equatable {
    var keyID: String
    var name: String
    var remote: String
    var since: Date
    var lastSeen: Date
    var rtt: Int?
}

/// 동기화 엔진: 폴더마다 훑기 · 목록 주고받기 · 받기 (Syncthing 규칙, Ai/iNAS/동기화-설계.md).
/// 연결은 밖(SyncDiscovery · 시험 장치)이 TLS 로 맺어 attach 로 넘긴다.
actor SyncEngine {
    nonisolated let identity: SyncIdentity
    private let name: String
    private let stateDir: URL
    private let log: @Sendable (String) -> Void
    /// 상태가 바뀔 때 (폴더 아이디 → 상태)
    private var onStatus: (@Sendable ([String: SyncFolderStatus]) -> Void)?

    private var folders: [String: SyncFolderIndex] = [:]
    private var peers: [String: SyncPeer] = [:]

    private final class Peer {
        let conn: FrameConnection
        let peer: SyncPeer
        var folders: Set<String> = []
        var pending: [Int: CheckedContinuation<Data, Error>] = [:]
        let since = Date()
        var lastSeen = Date()
        var pingSent: Date?
        var rtt: Int?
        init(conn: FrameConnection, peer: SyncPeer) {
            self.conn = conn
            self.peer = peer
        }
    }

    /// 인사가 끝난 연결 (기기 아이디 → 연결)
    private var connected: [String: Peer] = [:]
    private var nextRequest = 1
    private let netQueue = DispatchQueue(label: "iNAS.sync.engine.net")

    // 폴더마다 한 번에 일 하나: 돌고 있으면 표시만 해 두고 끝나면 한 번 더
    private var running: Set<String> = []
    private var again: Set<String> = []
    /// 변경 신호(FSEvents · 받은 뒤 등)로 훑을 곳 — 전체 재탐색보다 먼저
    private var pendingEvents: [String: Set<String>] = [:]
    /// 전체 재탐색이 필요한 폴더
    private var pendingFull: Set<String> = []
    private var lastFullScan: [String: Date] = [:]
    // 상세 창: 받기 · 보내기 (에이전트 메모리에만)
    private var needSince: [String: [String: Date]] = [:]
    private var pullDone: [String: [String: Int64]] = [:]
    private var pullingNow: [String: String] = [:]
    private var sendSince: [String: [String: [String: Date]]] = [:]   // 폴더 → 기기 → 이름 → 들어온 시각
    private var sent: [String: [String: [String: Int64]]] = [:]
    private var sendingNow: [String: [String: (String, Date)]] = [:]  // 폴더 → 기기 → (이름, 마지막 보낸 시각)
    /// 상세 창 정보 (actor 밖에서 바로 읽는다)
    nonisolated let detail = SyncDetailBox()
    private var status: [String: SyncFolderStatus] = [:]
    /// 폴더가 멈춘 이유 (풀려나면 lastError 에서 지우려고 기억)
    private var stopReasons: [String: String] = [:]

    init(identity: SyncIdentity, name: String, stateDir: URL, log: @escaping @Sendable (String) -> Void) {
        self.identity = identity
        self.name = name
        self.stateDir = stateDir
        self.log = log
    }

    func setStatusHandler(_ h: @escaping @Sendable ([String: SyncFolderStatus]) -> Void) {
        onStatus = h
    }

    /// 연결이 생기거나 끊기거나 신호가 올 때
    private var onLinks: (@Sendable ([SyncPeerLink]) -> Void)?
    func setLinkHandler(_ h: @escaping @Sendable ([SyncPeerLink]) -> Void) { onLinks = h }

    func links() -> [SyncPeerLink] {
        connected.values.map { SyncPeerLink(keyID: $0.peer.keyID, name: $0.peer.name, remote: $0.conn.remote, since: $0.since, lastSeen: $0.lastSeen, rtt: $0.rtt) }
    }

    private func publishLinks() { onLinks?(links()) }

    static let pingEvery: Double = 10
    static let deadAfter: Double = 35
    static let requestTimeout: Double = 60

    /// 10초마다 신호, 35초 동안 아무 말도 없으면 끊는다
    private func keepAlive(_ p: Peer) async {
        while connected[p.peer.keyID] === p {
            try? await Task.sleep(for: .seconds(Self.pingEvery))
            guard connected[p.peer.keyID] === p else { return }
            if Date().timeIntervalSince(p.lastSeen) > Self.deadAfter {
                p.conn.close("\(Int(Self.deadAfter))초 동안 신호 없음")
                return
            }
            p.pingSent = Date()
            p.conn.send(.ping)
        }
    }

    // MARK: 설정

    /// 꺼서 빠진 폴더 (지워졌다는 forget 이 오면 그 뒤 저장을 막으려고 잠깐 들고 있는다)
    private var retired: [String: SyncFolderIndex] = [:]

    /// 폴더가 iCloud 에서 지워졌을 때: 이 Mac 의 파일 목록 파일(folder-<id>.plist)을 지우고, 아직 돌던 일이 다시 저장하지 않게 한다.
    /// 끄기(configure 에서 빠짐)와 달리 다시 켤 일이 없으니 목록을 남길 까닭이 없다
    func forget(_ folderID: String) {
        folders[folderID]?.discard = true
        retired.removeValue(forKey: folderID)?.discard = true
        try? FileManager.default.removeItem(at: SyncFolderIndex.stateURL(stateDir: stateDir, folderID: folderID))
        peerDetails = peerDetails.filter { !$0.key.hasSuffix("|" + folderID) }
    }

    /// 이 기기에서 켜진 폴더들 (경로가 있는 것만)
    func configure(folders configs: [SyncFolderConfig]) {
        let ids = Set(configs.map(\.id))
        for id in folders.keys where !ids.contains(id) {
            retired[id] = folders[id]
            folders[id] = nil
            status[id] = nil
            detail.remove(id)
        }
        for c in configs {
            if let f = folders[c.id] {
                let ignoresChanged = f.config.ignores != c.ignores
                let pathChanged = f.config.path != c.path
                f.update(config: c)
                if pathChanged || ignoresChanged { requestScan(c.id, nil) }
            } else {
                retired[c.id] = nil
                folders[c.id] = SyncFolderIndex(config: c, me: identity.shortID, stateDir: stateDir)
                status[c.id] = SyncFolderStatus()
                requestScan(c.id, nil)
            }
        }
        for p in connected.values { p.conn.send(.folders(Array(folders.keys))) }
        publish()
    }

    func setPeers(_ list: [SyncPeer]) {
        peers = Dictionary(list.map { ($0.keyID, $0) }, uniquingKeysWith: { a, _ in a })
        for (id, p) in connected where peers[id] == nil {
            p.conn.close("iCloud 기기 목록에서 빠짐")
        }
        // 충돌 사본 목록(어느 기기 것인지)이 기기 목록에 따라 달라지므로 다시 계산
        for f in folders.values { updateStatus(f) }
        publish()
    }

    func connectedPeerIDs() -> [String] { Array(connected.keys) }

    /// 모든 연결을 끊는다 (시험 · 앱 끝날 때)
    func disconnectAll(_ reason: String) {
        for p in connected.values { p.conn.close(reason) }
    }

    // MARK: 연결

    /// TLS 로 맺은 연결을 넘긴다. 붙는 쪽이면 peer 를 안다
    /// result: 붙는 쪽에게 인사가 끝나면 nil, 그 전에 끊기면 이유
    nonisolated func attach(_ nw: NWConnection, to peer: SyncPeer?, result: (@Sendable (String?) -> Void)? = nil) {
        let fc = FrameConnection(nw, queue: netQueue)
        Task { await self.setup(fc, outgoingTo: peer, result: result) }
    }

    private var dialResults: [ObjectIdentifier: @Sendable (String?) -> Void] = [:]

    private func setup(_ fc: FrameConnection, outgoingTo peer: SyncPeer?, result: (@Sendable (String?) -> Void)?) {
        if let result { dialResults[ObjectIdentifier(fc)] = result }
        fc.onReady = { [weak self] in
            guard let self, let peer else { return }
            Task { await self.sendHello(fc, to: peer) }
        }
        fc.onMessage = { [weak self] m in
            guard let self else { return }
            Task { await self.received(m, on: fc) }
        }
        fc.onClose = { [weak self] reason in
            guard let self else { return }
            Task { await self.closed(fc, reason: reason) }
        }
        fc.start()
        netQueue.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self else { return }
            Task { if await !self.isConnected(fc) { fc.close("인사 없음") } }
        }
    }

    private func isConnected(_ fc: FrameConnection) -> Bool { connected.values.contains { $0.conn === fc } }

    private var helloSent: Set<ObjectIdentifier> = []

    private func sendHello(_ fc: FrameConnection, to peer: SyncPeer) {
        guard !helloSent.contains(ObjectIdentifier(fc)) else { return }
        guard let proof = SyncTLS.helloProof(me: identity, peer: peer, from: identity.keyID, to: peer.keyID) else {
            return fc.close("키 오류")
        }
        helloSent.insert(ObjectIdentifier(fc))
        fc.send(.hello(.init(keyID: identity.keyID, name: name, proof: proof, folders: Array(folders.keys))))
    }

    private func received(_ m: SyncMessage, on fc: FrameConnection) async {
        if case .hello(let h) = m {
            guard let peer = peers[h.keyID],
                  let expect = SyncTLS.helloProof(me: identity, peer: peer, from: h.keyID, to: identity.keyID),
                  expect == h.proof else {
                log("모르는 기기의 인사 거절 (\(h.name), \(fc.remote))")
                return fc.close("모르는 기기")
            }
            if let old = connected[h.keyID], old.conn !== fc { old.conn.close("새 연결로 바뀜") }
            let p = Peer(conn: fc, peer: peer)
            p.folders = Set(h.folders)
            connected[h.keyID] = p
            dialResults.removeValue(forKey: ObjectIdentifier(fc))?(nil)
            Task { await self.keepAlive(p) }
            publishLinks()
            // 받는 쪽이면 인사를 돌려준다 (붙는 쪽은 이미 보냄)
            sendHello(fc, to: peer)
            log("\(peer.name) 와 연결 (\(fc.remote))")
            sendFullIndexes(to: p)
            publish()
            return
        }
        guard let p = connected.values.first(where: { $0.conn === fc }) else { return }
        p.lastSeen = Date()
        switch m {
        case .hello: break
        case .folders(let list):
            let before = p.folders
            p.folders = Set(list)
            for id in p.folders.subtracting(before) where folders[id] != nil { sendIndex(id, to: p, files: nil) }
            publish()
        case .index(let ix):
            guard let f = folders[ix.folder], p.folders.contains(ix.folder) else { return }
            if ix.reset { f.remote[p.peer.keyID] = [:] }
            var list = f.remote[p.peer.keyID] ?? [:]
            for file in ix.files where Self.safeName(file.name) { list[file.name] = file }
            f.remote[p.peer.keyID] = list
            requestPull(ix.folder)
        case .request(let r):
            serve(r, to: p)
        case .response(let r):
            if let c = p.pending.removeValue(forKey: r.id) {
                if let d = r.data { c.resume(returning: d) } else { c.resume(throwing: SyncError(r.error ?? "받기 실패")) }
            }
        case .detailAsk(let folder):
            guard folders[folder] != nil, p.folders.contains(folder) else { return }
            fc.send(.detailReply(.init(folder: folder, detail: detail.get(folder).encoded())))
        case .detailReply(let r):
            guard p.folders.contains(r.folder), let d = SyncFolderDetail.decode(r.detail) else { return }
            peerDetails[p.peer.keyID + "|" + r.folder] = d
        case .rescanAsk(let folder):
            guard folders[folder] != nil, p.folders.contains(folder) else { return }
            requestScan(folder, nil)
        case .ping:
            fc.send(.pong)
        case .pong:
            if let sent = p.pingSent { p.rtt = Int(Date().timeIntervalSince(sent) * 1000) }
            publishLinks()
        }
    }

    private func closed(_ fc: FrameConnection, reason: String?) {
        helloSent.remove(ObjectIdentifier(fc))
        dialResults.removeValue(forKey: ObjectIdentifier(fc))?(reason ?? "끊김")
        guard let (id, p) = connected.first(where: { $0.value.conn === fc }) else { return }
        connected[id] = nil
        for (_, c) in p.pending { c.resume(throwing: SyncError("연결 끊김")) }
        p.pending = [:]
        log("\(p.peer.name) 연결 끊김 — \(reason ?? "")")
        publish()
        publishLinks()
    }

    /// 경로로 쓸 수 있는 이름인지 (.. · 절대 경로 · 빈 칸 막기)
    static func safeName(_ n: String) -> Bool {
        if n.isEmpty || n.hasPrefix("/") || n.contains("\0") { return false }
        return !n.split(separator: "/", omittingEmptySubsequences: false).contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }

    // MARK: 목록 보내기

    private func sendFullIndexes(to p: Peer) {
        for id in p.folders where folders[id] != nil {
            sendIndex(id, to: p, files: nil)
        }
    }

    /// files 가 nil 이면 전체(reset), 아니면 바뀐 것만. 2000개씩 나눠 보낸다
    private func sendIndex(_ folderID: String, to p: Peer, files: [SyncFile]?) {
        guard let f = folders[folderID], p.folders.contains(folderID) else { return }
        let list = files ?? Array(f.files.values)
        if list.isEmpty && files != nil { return }
        var first = files == nil
        var start = 0
        repeat {
            let chunk = Array(list[start..<min(start + 2000, list.count)])
            p.conn.send(.index(.init(folder: folderID, files: chunk, reset: first)))
            first = false
            start += 2000
        } while start < list.count
    }

    private func broadcast(_ folderID: String, _ changed: [SyncFile]) {
        guard !changed.isEmpty else { return }
        for p in connected.values where p.folders.contains(folderID) {
            sendIndex(folderID, to: p, files: changed)
        }
    }

    // MARK: 블록 주기

    private func serve(_ r: SyncMessage.Request, to p: Peer) {
        func fail(_ e: String) { p.conn.send(.response(.init(id: r.id, data: nil, error: e))) }
        guard p.folders.contains(r.folder), let f = folders[r.folder], let file = f.files[r.name], !file.deleted, file.kind == .file else {
            return fail("없는 파일")
        }
        guard let h = try? FileHandle(forReadingFrom: f.url(of: r.name)) else { return fail("열 수 없음") }
        defer { try? h.close() }
        guard (try? h.seek(toOffset: UInt64(r.offset))) != nil, let data = try? h.read(upToCount: Int(r.size)), data.count == Int(r.size) else {
            return fail("읽기 실패")
        }
        guard Data(SHA256.hash(data: data)) == r.hash else {
            requestScan(r.folder, [r.name])
            return fail("파일이 바뀜")
        }
        p.conn.send(.response(.init(id: r.id, data: data, error: nil)))
        // 상세 창 "보내기": 이 기기에 이 파일을 얼마나 보냈나
        let key = p.peer.keyID
        let total = (sent[r.folder]?[key]?[r.name] ?? 0) + Int64(data.count)
        sent[r.folder, default: [:]][key, default: [:]][r.name] = total
        sendingNow[r.folder, default: [:]][key] = (r.name, Date())
        // 도는 표시는 지금 보내는 파일 하나에만 (전에 보낸 줄은 끈다)
        detail.update(r.folder) { d in
            for i in d.send.indices where d.send[i].peer == key {
                if d.send[i].path == r.name {
                    d.send[i].done = total
                    d.send[i].active = true
                } else if d.send[i].active {
                    d.send[i].active = false
                }
            }
        }
    }

    private func request(_ p: Peer, folder: String, name: String, block b: SyncBlock) async throws -> Data {
        let id = nextRequest
        nextRequest += 1
        let data: Data = try await withCheckedThrowingContinuation { c in
            p.pending[id] = c
            p.conn.send(.request(.init(id: id, folder: folder, name: name, offset: b.offset, size: b.size, hash: b.hash)))
            Task {
                try? await Task.sleep(for: .seconds(Self.requestTimeout))
                self.timeoutRequest(p, id)
            }
        }
        guard data.count == Int(b.size), Data(SHA256.hash(data: data)) == b.hash else { throw SyncError("블록 해시가 다름") }
        return data
    }

    private func timeoutRequest(_ p: Peer, _ id: Int) {
        if let c = p.pending.removeValue(forKey: id) {
            c.resume(throwing: SyncError("\(Int(Self.requestTimeout))초 동안 답이 없음"))
        }
    }

    // MARK: 일 순서

    /// 이 폴더를 (일부) 다시 훑어 달라 (FSEvents · 받은 뒤 등)
    func requestScan(_ folderID: String, _ subpaths: [String]?) {
        if let subpaths {
            pendingEvents[folderID, default: []].formUnion(subpaths)
        } else {
            pendingFull.insert(folderID)
            detail.update(folderID) { $0.scan.fullWaiting = true }
        }
        kick(folderID)
    }

    /// 상세 창 정보 (훑는 중에도 바로)
    nonisolated func folderDetail(_ folderID: String) -> SyncFolderDetail { detail.get(folderID) }

    /// 다른 Mac 의 폴더 상세: 마지막으로 받은 것을 돌려주고, 그 Mac 에 새로 달라고 한다(0.8초에 한 번까지).
    /// 연결이 없거나 그 Mac 이 이 폴더를 안 쓰면 nil
    private var peerDetails: [String: SyncFolderDetail] = [:]
    private var peerDetailAsked: [String: Date] = [:]
    func peerDetail(_ folderID: String, peer keyID: String) -> SyncFolderDetail? {
        let k = keyID + "|" + folderID
        guard let p = connected[keyID], p.folders.contains(folderID) else {
            peerDetails[k] = nil
            return nil
        }
        if peerDetailAsked[k].map({ Date().timeIntervalSince($0) > 0.8 }) ?? true {
            peerDetailAsked[k] = Date()
            p.conn.send(.detailAsk(folderID))
        }
        return peerDetails[k] ?? SyncFolderDetail.waiting
    }

    /// 다른 Mac 에 이 폴더를 지금 전체 재탐색해 달라고
    func askPeerRescan(_ folderID: String, peer keyID: String) {
        guard let p = connected[keyID], p.folders.contains(folderID) else { return }
        p.conn.send(.rescanAsk(folderID))
    }

    /// 폴더마다 재탐색 간격이 되면 전체를 다시 훑는다 (30초마다 확인, 앱 쪽에서 한 번 시작)
    private var rescanLoopStarted = false
    func startRescanLoop() {
        guard !rescanLoopStarted else { return }
        rescanLoopStarted = true
        Task {
            while true {
                try? await Task.sleep(for: .seconds(30))
                self.rescanDue()
            }
        }
    }

    private func rescanDue() {
        let now = Date()
        for (id, f) in folders where f.config.rescanInterval > 0 && !pendingFull.contains(id) {
            if let last = lastFullScan[id], now.timeIntervalSince(last) < f.config.rescanInterval { continue }
            requestScan(id, nil)
        }
    }

    func requestPull(_ folderID: String) { kick(folderID) }

    func rescanAll() {
        for id in folders.keys { requestScan(id, nil) }
    }

    private func kick(_ id: String) {
        if running.contains(id) {
            again.insert(id)
            return
        }
        running.insert(id)
        Task { await self.run(id) }
    }

    private func run(_ id: String) async {
        repeat {
            again.remove(id)
            await work(id)
        } while again.contains(id) && folders[id] != nil
        running.remove(id)
    }

    /// 한 바퀴: 훑기 → 알리기 → 받기 → 알리기
    private func work(_ id: String) async {
        guard let f = folders[id] else { return }
        // 1) 변경 신호가 먼저 (그동안 전체 재탐색은 대기)
        if let events = pendingEvents.removeValue(forKey: id), !events.isEmpty {
            status[id]?.state = .scanning
            detail.update(id) { $0.scan.phase = .events; $0.scan.fullWaiting = self.pendingFull.contains(id); $0.scan.dir = nil; $0.scan.checked = 0 }
            publish()
            let changed = f.scan(subpaths: Array(events)) { [detail] dir, n in detail.update(id) { $0.scan.dir = dir; $0.scan.checked = n } }
            recordLocal(f, changed, origin: .event)
            broadcast(id, changed)
        }
        // 2) 전체 재탐색 (그사이 새 변경 신호가 오면 다음 바퀴에 먼저)
        if pendingEvents[id] == nil, pendingFull.remove(id) != nil {
            status[id]?.state = .scanning
            detail.update(id) { $0.scan.phase = .full; $0.scan.fullWaiting = false; $0.scan.dir = ""; $0.scan.checked = 0 }
            publish()
            let changed = f.scan(subpaths: nil) { [detail] dir, n in detail.update(id) { $0.scan.dir = dir; $0.scan.checked = n } }
            lastFullScan[id] = Date()
            recordLocal(f, changed, origin: .rescan)
            broadcast(id, changed)
        } else if pendingEvents[id] != nil {
            again.insert(id)
        }
        let last = lastFullScan[id]
        let interval = f.config.rescanInterval
        detail.update(id) { $0.scan.phase = .idle; $0.scan.dir = nil; $0.scan.lastFull = last; $0.scan.interval = interval
            $0.scan.fullWaiting = self.pendingFull.contains(id) }
        if let reason = f.stopReason {
            status[id]?.state = .stopped
            status[id]?.lastError = reason
            stopReasons[id] = reason
            publish()
            return
        }
        // 멈춤에서 풀려났으면 멈춘 이유를 지운다 (남아 있으면 폴더 줄에 문제 아이콘이 계속 뜸)
        if let old = stopReasons.removeValue(forKey: id), status[id]?.lastError == old {
            status[id]?.lastError = nil
        }
        await pull(f)
        updateStatus(f)
        publish()
    }

    // MARK: 받기

    /// 이 Mac 에서 알아챈 변경을 상세 창 "최근 변경" 에 (폴더 줄은 빼고)
    private func recordLocal(_ f: SyncFolderIndex, _ changed: [SyncFile], origin: SyncFolderDetail.Change.Origin) {
        let now = Date()
        let list = changed.filter { $0.kind != .directory }.map { c in
            SyncFolderDetail.Change(date: now, path: c.name,
                                    action: c.deleted ? .deleted : (f.lastScanNew.contains(c.name) ? .added : .modified), origin: origin)
        }
        detail.record(f.config.id, list)
    }

    /// 받을 것: 들어온 시각을 기억하고(새것 추가 · 끝난 것 빼기) 상세 창 줄을 만든다
    private func refreshReceive(_ f: SyncFolderIndex, _ needs: [(file: SyncFile, from: String)]) {
        let id = f.config.id
        let now = Date()
        var since = needSince[id] ?? [:]
        let names = Set(needs.map(\.file.name))
        since = since.filter { names.contains($0.key) }
        for n in needs where since[n.file.name] == nil { since[n.file.name] = now }
        needSince[id] = since
        pullDone[id] = (pullDone[id] ?? [:]).filter { names.contains($0.key) }
        let files = needs.filter { $0.file.kind != .directory }
        let rows = files.prefix(SyncFolderDetail.rowLimit).map { n in
            SyncFolderDetail.Transfer(since: since[n.file.name] ?? now, path: n.file.name, peer: n.from,
                                      done: pullDone[id]?[n.file.name] ?? 0, total: n.file.deleted ? 0 : n.file.size,
                                      active: pullingNow[id] == n.file.name)
        }
        let count = files.count
        let bytes = files.reduce(Int64(0)) { $0 + ($1.file.deleted ? 0 : $1.file.size) }
        detail.update(id) { $0.receive = rows; $0.receiveCount = count; $0.receiveBytes = bytes }
    }

    private func pull(_ f: SyncFolderIndex) async {
        let id = f.config.id
        var needs = f.needed()
        refreshReceive(f, needs)
        if needs.isEmpty { return }
        status[id]?.state = .syncing
        status[id]?.needItems = needs.count
        status[id]?.needBytes = needs.reduce(0) { $0 + ($1.file.deleted ? 0 : $1.file.size) }
        publish()
        var done: [SyncFile] = []
        var rescans: [String] = []
        var errors = 0
        // 받은 것은 다 끝날 때까지 모으지 않고 1초(또는 500개)마다 알린다 — 보낸 쪽 "보내기" 줄과 남은 개수가 받는 대로 줄게
        // (Syncthing 도 받는 동안 목록을 계속 보낸다). 목록 파일 저장은 10초마다
        var unsent: [SyncFile] = []
        var lastBroadcast = Date()
        var lastSave = Date()
        // 내 블록 찾기표 (같은 내용이면 저쪽에 안 묻고 내 파일에서 복사)
        var localBlocks: [Data: (String, Int64)] = [:]
        for (n, lf) in f.files where !lf.deleted && lf.kind == .file {
            for b in lf.blocks { localBlocks[b.hash] = (n, b.offset) }
        }
        for (g, from) in needs {
            guard let p = connected[from], p.folders.contains(id) else { continue }
            if f.diskDiffers(g.name) {
                rescans.append(g.name)
                continue
            }
            let before = f.files[g.name]
            pullingNow[id] = g.name
            refreshReceive(f, needs)
            do {
                let changedNames: [String]
                switch (g.deleted, g.kind) {
                case (true, _): changedNames = try deleteItem(f, g)
                case (false, .directory): changedNames = try makeDirectory(f, g)
                case (false, .symlink): changedNames = try makeSymlink(f, g)
                case (false, .file): changedNames = try await pullFile(f, g, from: p, localBlocks: localBlocks)
                }
                rescans += changedNames
                if let rec = f.files[g.name] { done.append(rec); unsent.append(rec) }
                if g.kind != .directory {
                    let action: SyncFolderDetail.Change.Action = g.deleted ? .deleted : ((before == nil || before!.deleted) ? .added : .modified)
                    detail.record(id, [SyncFolderDetail.Change(date: Date(), path: g.name, action: action, origin: .peer(from))])
                }
            } catch {
                errors += 1
                status[id]?.lastError = "\(g.name): \(error.localizedDescription)"
                log("\(f.config.name) / \(g.name) 받기 실패: \(error.localizedDescription)")
            }
            status[id]?.needItems -= 1
            if done.count % 200 == 0 { publish() }
            if !unsent.isEmpty, unsent.count >= 500 || Date().timeIntervalSince(lastBroadcast) >= 1 {
                if Date().timeIntervalSince(lastSave) >= 10 { f.save(); lastSave = Date() }
                broadcast(id, unsent)
                unsent = []
                lastBroadcast = Date()
            }
        }
        pullingNow[id] = nil
        refreshReceive(f, f.needed().filter { connected[$0.from] != nil })
        f.save()
        broadcast(id, unsent)
        if errors == 0 { status[id]?.lastError = nil }
        status[id]?.lastSync = Date()
        if !rescans.isEmpty { requestScan(id, rescans) }
        needs = []
    }

    private func diskName(_ f: SyncFolderIndex, _ name: String) -> String {
        f.meta[name]?.diskName ?? name.decomposedStringWithCanonicalMapping
    }

    /// 파일 받기: 임시 파일에 블록을 모아 해시 확인 → 충돌이면 내 것을 사본으로 → 제자리로
    private func pullFile(_ f: SyncFolderIndex, _ g: SyncFile, from p: Peer, localBlocks: [Data: (String, Int64)]) async throws -> [String] {
        let fm = FileManager.default
        let cur = f.files[g.name]
        // 내용이 같으면 기록만 맞춘다 (Syncthing shortcutFile)
        if let cur, !cur.deleted, cur.kind == .file, g.blocksEqual(cur) {
            let u = f.url(of: g.name)
            try setMeta(u, g)
            f.record(g, diskName: diskName(f, g.name))
            return []
        }
        let disk = diskName(f, g.name)
        let finalURL = f.root.appendingPathComponent(disk)
        try fm.createDirectory(at: finalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = finalURL.deletingLastPathComponent().appendingPathComponent(SyncFolderIndex.tempPrefix + finalURL.lastPathComponent)
        try? fm.removeItem(at: tmp)
        guard fm.createFile(atPath: tmp.path, contents: nil) else { throw SyncError("임시 파일을 못 만듦") }
        var ok = false
        defer { if !ok { try? fm.removeItem(at: tmp) } }
        let out = try FileHandle(forWritingTo: tmp)
        defer { try? out.close() }
        // 블록: 내 파일에 같은 것이 있으면 복사, 없으면 저쪽에 (한 번에 16개까지 동시에)
        var remoteBlocks: [SyncBlock] = []
        var written: Int64 = 0
        let fid = f.config.id
        func progress(_ n: Int64) {
            written += n
            pullDone[fid, default: [:]][g.name] = written
            let w = written
            detail.update(fid) { d in
                if let i = d.receive.firstIndex(where: { $0.path == g.name }) { d.receive[i].done = w }
            }
        }
        for b in g.blocks {
            if let (n, off) = localBlocks[b.hash], let src = try? FileHandle(forReadingFrom: f.url(of: n)) {
                defer { try? src.close() }
                if (try? src.seek(toOffset: UInt64(off))) != nil, let d = try? src.read(upToCount: Int(b.size)),
                   d.count == Int(b.size), Data(SHA256.hash(data: d)) == b.hash {
                    try out.seek(toOffset: UInt64(b.offset))
                    try out.write(contentsOf: d)
                    progress(Int64(d.count))
                    continue
                }
            }
            remoteBlocks.append(b)
        }
        var index = 0
        while index < remoteBlocks.count {
            let batch = Array(remoteBlocks[index..<min(index + 16, remoteBlocks.count)])
            index += batch.count
            var results: [(SyncBlock, Data)] = []
            try await withThrowingTaskGroup(of: (SyncBlock, Data).self) { group in
                for b in batch {
                    group.addTask { (b, try await self.request(p, folder: f.config.id, name: g.name, block: b)) }
                }
                for try await r in group { results.append(r) }
            }
            for (b, d) in results {
                try out.seek(toOffset: UInt64(b.offset))
                try out.write(contentsOf: d)
            }
            progress(results.reduce(Int64(0)) { $0 + Int64($1.1.count) })
        }
        try out.truncate(atOffset: UInt64(g.size))
        try out.close()
        try setMeta(tmp, g)
        // 받는 사이 내 쪽이 바뀌었으면 그만두고 다시 훑는다
        if f.diskDiffers(g.name) { return [g.name] }
        var rescans: [String] = []
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: finalURL.path, isDirectory: &isDir) {
            if isDir.boolValue {
                try removeEmptyDirectory(f, g.name)
            } else if let cur, !cur.deleted, g.inConflict(with: cur) {
                if let copy = try f.moveForConflict(g.name, by: g.modifiedBy) { rescans.append(copy) }
                log("\(f.config.name) / \(g.name) 충돌 — 내 것을 사본으로 남김")
            }
        }
        guard rename(tmp.path, finalURL.path) == 0 else { throw SyncError("제자리로 옮기기 실패 (\(errno))") }
        ok = true
        f.record(g, diskName: disk)
        return rescans
    }

    private func makeDirectory(_ f: SyncFolderIndex, _ g: SyncFile) throws -> [String] {
        let fm = FileManager.default
        let u = f.root.appendingPathComponent(diskName(f, g.name))
        var rescans: [String] = []
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: u.path, isDirectory: &isDir), !isDir.boolValue {
            if let cur = f.files[g.name], !cur.deleted, cur.kind == .file, g.inConflict(with: cur) {
                if let copy = try f.moveForConflict(g.name, by: g.modifiedBy) { rescans.append(copy) }
            } else {
                try fm.removeItem(at: u)
            }
        }
        try fm.createDirectory(at: u, withIntermediateDirectories: true)
        chmod(u.path, mode_t(g.permissions == 0 ? 0o755 : g.permissions))
        f.record(g, diskName: diskName(f, g.name))
        return rescans
    }

    private func makeSymlink(_ f: SyncFolderIndex, _ g: SyncFile) throws -> [String] {
        let fm = FileManager.default
        let u = f.root.appendingPathComponent(diskName(f, g.name))
        if (try? fm.destinationOfSymbolicLink(atPath: u.path)) != nil || fm.fileExists(atPath: u.path) {
            try fm.removeItem(at: u)
        }
        try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: u.path, withDestinationPath: g.symlinkTarget ?? "")
        f.record(g, diskName: diskName(f, g.name))
        return []
    }

    /// 지우기: 내 파일이 충돌이면 지우지 않고 사본으로 (Syncthing deleteFile)
    private func deleteItem(_ f: SyncFolderIndex, _ g: SyncFile) throws -> [String] {
        let fm = FileManager.default
        guard let cur = f.files[g.name], !cur.deleted else {
            f.record(g, diskName: nil)
            return []
        }
        let u = f.url(of: g.name)
        var rescans: [String] = []
        switch cur.kind {
        case .file:
            if g.inConflict(with: cur) {
                if let copy = try f.moveForConflict(g.name, by: g.modifiedBy) { rescans.append(copy) }
                log("\(f.config.name) / \(g.name) 저쪽은 지웠지만 이쪽이 고쳐서 사본으로 남김")
            } else {
                try? fm.removeItem(at: u)
            }
        case .symlink:
            try? fm.removeItem(at: u)
        case .directory:
            try removeEmptyDirectory(f, g.name)
        }
        f.record(g, diskName: nil)
        return rescans
    }

    /// 폴더 지우기: 안에 (?d) 예외 파일만 있으면 같이 지우고, 다른 것이 있으면 실패 (Syncthing)
    private func removeEmptyDirectory(_ f: SyncFolderIndex, _ name: String) throws {
        let fm = FileManager.default
        let u = f.url(of: name)
        let items = (try? fm.contentsOfDirectory(atPath: u.path)) ?? []
        for item in items {
            let child = name + "/" + item.precomposedStringWithCanonicalMapping
            let r = f.ignore.match(child)
            if r.ignored && r.deletable {
                try fm.removeItem(at: u.appendingPathComponent(item))
            } else {
                throw SyncError("폴더가 비어 있지 않아 못 지움 (\(item))")
            }
        }
        try? fm.removeItem(at: u)
    }

    private func setMeta(_ u: URL, _ g: SyncFile) throws {
        chmod(u.path, mode_t(g.permissions == 0 ? 0o644 : g.permissions))
        var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)),
                     timespec(tv_sec: Int(g.modified / 1_000_000_000), tv_nsec: Int(g.modified % 1_000_000_000))]
        guard utimensat(AT_FDCWD, u.path, &times, 0) == 0 else { throw SyncError("수정 시각을 못 맞춤") }
    }

    // MARK: 상태

    private func updateStatus(_ f: SyncFolderIndex) {
        let id = f.config.id
        pendingSendRows = [:]
        var s = status[id] ?? SyncFolderStatus()
        let needs = f.needed().filter { connected[$0.from] != nil }
        s.needItems = needs.count
        s.needBytes = needs.reduce(0) { $0 + ($1.file.deleted ? 0 : $1.file.size) }
        let live = f.files.values.filter { !$0.deleted }
        // 파일 수는 폴더를 빼고 센다 (다른 Mac 의 수와 같은 기준)
        s.localFiles = live.filter { $0.kind != .directory }.count
        s.localBytes = live.reduce(0) { $0 + $1.size }
        // iNAS 기기(나 · 믿는 기기)가 만든 사본만. Syncthing 이 남긴 사본(끝이 Syncthing 기기 아이디)은 우리 충돌이 아니라 빼고 보여 준다
        var tags = [SyncFolderIndex.conflictTag(identity.shortID): name]
        for p in peers.values { tags[SyncFolderIndex.conflictTag(p.shortID)] = p.name }
        s.conflictDevices = tags
        let mine = Set(tags.keys)
        s.conflicts = Array(live.filter { $0.kind == .file && SyncFolderIndex.isConflict($0.name) && mine.contains(SyncFolderIndex.conflictTagOf($0.name) ?? "") }
            .map(\.name).sorted().prefix(500))
        s.sharedWith = connected.values.filter { $0.folders.contains(id) }.map(\.peer.name).sorted()
        var peerNeed: [String: Int] = [:]
        var peerFiles: [String: Int] = [:]
        var peerBytes: [String: Int64] = [:]
        for p in connected.values where p.folders.contains(id) {
            peerNeed[p.peer.keyID] = peerNeeds(f, p.peer.keyID)
            if let list = f.remote[p.peer.keyID] {
                let theirs = list.values.filter { !$0.deleted && $0.kind != .directory }
                peerFiles[p.peer.keyID] = theirs.count
                peerBytes[p.peer.keyID] = theirs.reduce(0) { $0 + $1.size }
            }
        }
        s.peerNeed = peerNeed
        s.peerFiles = peerFiles
        s.peerBytes = peerBytes
        // 상세 창 "보내기": 기기마다 따로 줄 (같은 파일도 기기가 다르면 다른 줄)
        let all = pendingSendRows.values.flatMap { $0 }.sorted { ($0.since, $0.path, $0.peer) < ($1.since, $1.path, $1.peer) }
        pendingSendRows = [:]
        let sendBytes = all.reduce(Int64(0)) { $0 + $1.total }
        detail.update(id) { d in
            d.send = Array(all.prefix(SyncFolderDetail.rowLimit))
            d.sendCount = all.count
            d.sendBytes = sendBytes
        }
        if s.state != .stopped { s.state = needs.isEmpty ? .idle : .syncing }
        // 멈춤에서 풀려나면(표시 파일이 돌아옴 등) 멈춘 이유도 지운다 (남아 있으면 폴더 줄에 문제 아이콘이 계속 뜸)
        if f.stopReason == nil, s.state == .stopped {
            s.state = needs.isEmpty ? .idle : .syncing
            s.lastError = nil
        }
        status[id] = s
    }

    /// 저쪽이 받아야 할 수: 전역 버전과 저쪽 버전이 다른 이름 (지움인데 저쪽에 없으면 빼고)
    /// 저쪽이 받아야 할 수 (+ 그중 이 Mac 이 최신을 가진 파일 = 이 Mac 이 보낼 것)
    private func peerNeeds(_ f: SyncFolderIndex, _ peer: String) -> Int {
        let theirs = f.remote[peer] ?? [:]
        var names = Set(f.files.keys)
        for list in f.remote.values { names.formUnion(list.keys) }
        var n = 0
        var sendable: [SyncFile] = []
        for name in names where !f.isIgnored(name) {
            guard let g = f.global(name) else { continue }
            let t = theirs[name]
            if let t, t.version == g.file.version { continue }
            if g.file.deleted && (t == nil || t!.deleted) { continue }
            n += 1
            if g.file.kind == .file, !g.file.deleted, let mine = f.files[name], mine.version == g.file.version { sendable.append(g.file) }
        }
        // 들어온 시각 기억 (새것 추가 · 끝난 것 빼기)
        let id = f.config.id
        let now = Date()
        let keep = Set(sendable.map(\.name))
        var since = (sendSince[id]?[peer] ?? [:]).filter { keep.contains($0.key) }
        for file in sendable where since[file.name] == nil { since[file.name] = now }
        sendSince[id, default: [:]][peer] = since
        sent[id, default: [:]][peer] = (sent[id]?[peer] ?? [:]).filter { keep.contains($0.key) }
        sendable.sort { (since[$0.name] ?? now, $0.name) < (since[$1.name] ?? now, $1.name) }
        pendingSendRows[peer] = sendable.map { file in
            let active = sendingNow[id]?[peer].map { $0.0 == file.name && now.timeIntervalSince($0.1) < 3 } ?? false
            return SyncFolderDetail.Transfer(since: since[file.name] ?? now, path: file.name, peer: peer,
                                             done: sent[id]?[peer]?[file.name] ?? 0, total: file.size, active: active)
        }
        return n
    }

    /// updateStatus 한 바퀴 동안 기기별 보낼 줄을 모은다
    private var pendingSendRows: [String: [SyncFolderDetail.Transfer]] = [:]

    func currentStatus() -> [String: SyncFolderStatus] { status }

    private func publish() {
        onStatus?(status)
    }

    /// 시험용: 폴더 목록 (이름 → 항목)
    func localFiles(_ folderID: String) -> [String: SyncFile] { folders[folderID]?.files ?? [:] }
    func isBusy() -> Bool { !running.isEmpty }
}

struct SyncError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}
