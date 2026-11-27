import AppKit
import CloudKit
import Foundation

/// 같은 iCloud 계정의 기기에 기록한 "나는 누구, 어디서 기다림"
struct SyncDevice: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var model: String
    var modelID: String
    var os: String
    var appVersion: String
    var localIP: String
    var publicIP: String
    /// 바깥에서 붙을 포트 (공유기에 연 포트, 공인 IP 바로면 대기 포트)
    var port: Int
    /// 이 기기 안에서 기다리는 포트
    var internalPort: Int
    /// "UPnP (ipTIME A3008-MU)", "공인 IP 바로", "열지 못함: …"
    var portMethod: String
    /// 바깥에서 붙을 수 있다고 보는지 (포트를 열었거나 공인 IP 바로)
    var reachable: Bool
    var updatedAt: Date
    /// 이 기기가 본 다른 기기(아이디)와의 연결. CloudKit 칸 이름은 reach (운영 스키마를 다시 안 올리려고 그대로 씀)
    var links: [String: SyncLinkInfo]
}

/// 한 기기와의 연결 상태
struct SyncLinkInfo: Codable, Equatable {
    var up: Bool
    /// 내가 붙었는지(아니면 저쪽이 붙어 옴)
    var outgoing: Bool
    /// "외부 1.2.3.4:47731", "내부 192.168.0.5:47731", 받은 쪽은 상대 주소
    var via: String
    var since: Date?
    var lastSeen: Date?
    var rtt: Int?
    var error: String?
    var at: Date
}

/// 두 기기 사이에 누가 붙을지
enum SyncRole: Equatable {
    case dial(host: String, port: Int, via: String, reason: String)
    case wait(reason: String)
    case none(reason: String)

    var text: String {
        switch self {
        case .dial(_, _, let via, let reason): return "내가 붙음 → \(via) (\(reason))"
        case .wait(let reason): return "저쪽이 붙어 오길 기다림 (\(reason))"
        case .none(let reason): return "연결 안 함 (\(reason))"
        }
    }
}

/// 설정 > 동기화 (시험): 기기 정보 · 공인 IP · 포트 열기 · 대기 · iCloud 등록 · 역할을 정해 한쪽이 붙고 연결 유지.
/// 네트워크 확인 1분, iCloud 목록 15초, 연결 관리 5초마다 (앱이 떠 있는 동안).
@MainActor
final class SyncDiscovery: ObservableObject {
    nonisolated static let containerID = "iCloud.com.moimz.iNAS"
    nonisolated static let recordType = "SyncDevice"
    static let basePort: UInt16 = 47731
    nonisolated static let zoneID = CKRecordZone.ID(zoneName: "Sync", ownerName: CKCurrentUserDefaultName)
    /// 이만큼 소식이 없으면 꺼진 기기로 본다 (iCloud 기록은 1분마다 올림)
    static let staleAfter: TimeInterval = 3 * 60
    static let pingEvery: TimeInterval = 10
    static let deadAfter: TimeInterval = 35

    @Published private(set) var me: SyncDevice
    @Published private(set) var peers: [SyncDevice] = []
    @Published private(set) var listenStatus = "시작 전"
    @Published private(set) var stunStatus = ""
    @Published private(set) var iCloudStatus = "확인 전"
    @Published private(set) var iCloudOK = false
    @Published private(set) var busy = false
    @Published private(set) var log: [(Date, String)] = []

    private let listener = SyncListener()
    private var gateway: UPnPGateway?
    private var mappedExternal: UInt16?
    private var timers: [Timer] = []
    private var zoneReady = false
    private var changeToken: CKServerChangeToken?
    private var iCloudBusy = false
    private var iCloudAgain = false
    private var iCloudAgainForce = false
    private var allDevices: [String: SyncDevice] = [:]
    private var lastSaved: SyncDevice?
    private var lastSavedAt = Date.distantPast
    private lazy var database = CKContainer(identifier: Self.containerID).privateCloudDatabase

    /// 기기 아이디 → 살아 있는 연결 (인사 끝난 것)
    private var conns: [String: LineConnection] = [:]
    /// 내가 붙는 중인 연결
    private var dialing: [String: LineConnection] = [:]
    /// 다시 붙기 전 기다림
    private var nextDial: [String: Date] = [:]
    private var dialFailures: [String: Int] = [:]
    /// 역할이 wait 가 된 시각 (오래 안 붙어 오면 나도 붙어 본다)
    private var waitingSince: [String: Date] = [:]
    private var pingSeq = 0
    private var lastDump = Date.distantPast
    private var pingSent: [String: (Int, Date)] = [:]

    init() {
        let key = "syncDeviceID"
        let id = UserDefaults.standard.string(forKey: key) ?? {
            let new = UUID().uuidString
            UserDefaults.standard.set(new, forKey: key)
            return new
        }()
        me = SyncDevice(
            id: id, name: DeviceInfo.computerName, model: DeviceInfo.productName ?? DeviceInfo.modelIdentifier,
            modelID: DeviceInfo.modelIdentifier, os: DeviceInfo.osVersion, appVersion: AppVersion.text,
            localIP: "", publicIP: "", port: 0, internalPort: 0, portMethod: "", reachable: false,
            updatedAt: .distantPast, links: [:]
        )
        listener.onConnection = { [weak self] c in
            Task { @MainActor in self?.accept(c) }
        }
    }

    func start() {
        guard timers.isEmpty else { return }
        Task { await refresh() }
        timers = [
            Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.refresh() }
            },
            Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.pollICloud() }
            },
            Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.manageLinks() }
            },
        ]
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.closePortSync() }
        }
    }

    /// 네트워크 한 바퀴: 내 정보 → 대기 → 공인 IP → 포트 열기 → iCloud 올리고 받기
    func refresh() async {
        guard !busy else { return }
        busy = true
        defer {
            busy = false
            dumpForDebug()
        }
        me.name = DeviceInfo.computerName
        me.localIP = DeviceInfo.primaryIPv4() ?? ""

        await ensureListening()

        do {
            let r = try await STUN.publicAddress()
            if r.ip != me.publicIP {
                note("공인 IP \(r.ip) (STUN \(r.server))")
                if !me.publicIP.isEmpty {
                    note("공인 IP 가 바뀌어 붙어 본 기록을 지움")
                    networkChanged()
                }
            }
            me.publicIP = r.ip
            stunStatus = "STUN \(r.server)"
        } catch {
            stunStatus = "공인 IP 를 못 알아냄: \(error.localizedDescription)"
            note(stunStatus)
        }

        await openPort()
        await pollICloud(forceSave: true)
        manageLinks()
    }

    // MARK: 대기

    private func ensureListening() async {
        if listener.port != 0, me.internalPort == Int(listener.port) { return }
        for offset in 0..<10 {
            let port = Self.basePort + UInt16(offset)
            do {
                try await listener.start(port: port)
                me.internalPort = Int(port)
                listenStatus = "TCP \(port) 에서 대기 중"
                note(listenStatus)
                return
            } catch {
                listenStatus = "TCP \(port) 대기 실패: \(error.localizedDescription)"
            }
        }
        note(listenStatus)
    }

    // MARK: 포트 열기

    private func openPort() async {
        guard me.internalPort != 0 else {
            me.portMethod = "대기 못 함"
            me.reachable = false
            return
        }
        if !me.localIP.isEmpty, !DeviceInfo.isPrivate(me.localIP) {
            me.port = me.internalPort
            me.portMethod = "공인 IP 바로 (공유기 없음, 방화벽은 붙어 봐야 앎)"
            me.reachable = true
            return
        }
        do {
            if gateway == nil {
                gateway = try await UPnP.findGateway()
                note("공유기 찾음: \(gateway!.name)")
            }
            guard let gw = gateway else { return }
            let wan = try await UPnP.externalIP(gw)
            var opened: UInt16?
            var lastError: Error?
            for offset in 0..<5 {
                let ext = UInt16(me.internalPort) + UInt16(offset)
                if let owner = await UPnP.mappingClient(gw, external: ext),
                   owner.client != me.localIP || owner.port != "\(me.internalPort)" {
                    continue  // 다른 기기가 쓰는 바깥 포트
                }
                do {
                    try await UPnP.addMapping(gw, external: ext, internal: UInt16(me.internalPort), client: me.localIP, lease: 3600)
                    opened = ext
                    break
                } catch { lastError = error }
            }
            guard let ext = opened else { throw lastError ?? NetError("빈 바깥 포트가 없음") }
            if mappedExternal != ext { note("공유기 포트 열기: 바깥 \(ext) → \(me.localIP):\(me.internalPort)") }
            mappedExternal = ext
            me.port = Int(ext)
            var method = "UPnP (\(gw.name))"
            if !me.publicIP.isEmpty, wan != me.publicIP {
                method += " · 공유기 바깥 IP \(wan) 가 공인 IP 와 다름 (공유기 뒤에 또 NAT)"
                me.reachable = false
            } else {
                me.reachable = true
            }
            me.portMethod = method
        } catch {
            gateway = nil
            me.port = me.internalPort
            me.reachable = false
            let text = "열지 못함: \(error.localizedDescription)"
            if me.portMethod != text { note("포트 \(text)") }
            me.portMethod = text
        }
    }

    /// 앱이 끝날 때 공유기 포트를 닫는다 (못 닫아도 1시간 뒤 풀린다)
    private func closePortSync() {
        guard let gw = gateway, let ext = mappedExternal else { return }
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            await UPnP.deleteMapping(gw, external: ext)
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 2)
    }

    // MARK: iCloud (CloudKit 개인 DB, Sync 영역에 기기마다 기록 하나)

    /// 바뀐 기록만 받고(변경 토큰), 내 기록은 바뀌었거나 1분 지났으면 올린다
    func pollICloud(forceSave: Bool = false) async {
        // 겹쳐 부르면 끝난 뒤 한 번 더
        if iCloudBusy {
            iCloudAgain = true
            iCloudAgainForce = iCloudAgainForce || forceSave
            return
        }
        iCloudBusy = true
        await pollICloudOnce(forceSave: forceSave)
        while iCloudAgain {
            let force = iCloudAgainForce
            iCloudAgain = false
            iCloudAgainForce = false
            await pollICloudOnce(forceSave: force)
        }
        iCloudBusy = false
    }

    private func pollICloudOnce(forceSave: Bool) async {
        do {
            if !zoneReady {
                let status = try await CKContainer(identifier: Self.containerID).accountStatus()
                guard status == .available else {
                    iCloudOK = false
                    iCloudStatus = "iCloud 를 쓸 수 없음 (\(status.rawValue)) — 시스템 설정에서 iCloud 로그인 확인"
                    note(iCloudStatus)
                    return
                }
                _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: Self.zoneID)], deleting: [])
                zoneReady = true
            }
            try await fetchChanges()
            me.links = me.links.filter { id, _ in allDevices[id] != nil }
            me.appVersion = AppVersion.text
            var compare = me
            compare.updatedAt = lastSaved?.updatedAt ?? .distantPast
            if forceSave || compare != lastSaved || Date().timeIntervalSince(lastSavedAt) > 60 {
                me.updatedAt = Date()
                try await save(me)
                lastSaved = me
                lastSavedAt = Date()
            }
            peers = allDevices.values.filter { $0.id != me.id }.sorted { $0.name < $1.name }
            iCloudOK = true
            iCloudStatus = "올림 · 기기 \(allDevices.count)대 (내 기록 포함)"
        } catch {
            iCloudOK = false
            iCloudStatus = "iCloud 오류: \(error.localizedDescription)"
            note(iCloudStatus)
            if let ck = error as? CKError, ck.code == .changeTokenExpired { changeToken = nil }
        }
    }

    private func fetchChanges() async throws {
        while true {
            let r = try await database.recordZoneChanges(inZoneWith: Self.zoneID, since: changeToken)
            for (_, result) in r.modificationResultsByID {
                if case .success(let m) = result, let d = Self.device(from: m.record) {
                    if allDevices[d.id] == nil, d.id != me.id { note("iCloud 에서 \(d.name) 찾음") }
                    allDevices[d.id] = d
                }
            }
            for deletion in r.deletions { allDevices[deletion.recordID.recordName] = nil }
            changeToken = r.changeToken
            if !r.moreComing { break }
        }
    }

    private func save(_ d: SyncDevice) async throws {
        try await Self.saveChecked(Self.record(from: d), in: database)
    }

    /// modifyRecords 는 기록 하나하나의 실패를 던지지 않고 결과에 담으므로 꺼내서 던진다
    nonisolated private static func saveChecked(_ rec: CKRecord, in db: CKDatabase) async throws {
        let r = try await db.modifyRecords(saving: [rec], deleting: [], savePolicy: .allKeys, atomically: false)
        for (_, result) in r.saveResults {
            if case .failure(let e) = result { throw e }
        }
    }

    nonisolated private static func record(from d: SyncDevice) -> CKRecord {
        let rec = CKRecord(recordType: Self.recordType, recordID: CKRecord.ID(recordName: d.id, zoneID: Self.zoneID))
        rec["name"] = d.name
        rec["model"] = d.model
        rec["modelID"] = d.modelID
        rec["os"] = d.os
        rec["appVersion"] = d.appVersion
        rec["localIP"] = d.localIP
        rec["publicIP"] = d.publicIP
        rec["port"] = d.port
        rec["internalPort"] = d.internalPort
        rec["portMethod"] = d.portMethod
        rec["reachable"] = d.reachable ? 1 : 0
        rec["updatedAt"] = d.updatedAt
        rec["reach"] = String(decoding: (try? json.encode(d.links)) ?? Data("{}".utf8), as: UTF8.self)  // 칸 이름은 운영 스키마 그대로 reach
        return rec
    }

    nonisolated private static let json: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let jsonDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private static func device(from r: CKRecord) -> SyncDevice? {
        guard r.recordType == recordType else { return nil }
        let links = (r["reach"] as? String).flatMap { try? jsonDecoder.decode([String: SyncLinkInfo].self, from: Data($0.utf8)) } ?? [:]
        return SyncDevice(
            id: r.recordID.recordName, name: r["name"] as? String ?? "?", model: r["model"] as? String ?? "",
            modelID: r["modelID"] as? String ?? "", os: r["os"] as? String ?? "", appVersion: r["appVersion"] as? String ?? "",
            localIP: r["localIP"] as? String ?? "", publicIP: r["publicIP"] as? String ?? "",
            port: r["port"] as? Int ?? 0, internalPort: r["internalPort"] as? Int ?? 0,
            portMethod: r["portMethod"] as? String ?? "", reachable: (r["reachable"] as? Int ?? 0) != 0,
            updatedAt: r["updatedAt"] as? Date ?? .distantPast, links: links
        )
    }

    // MARK: 역할 · 연결 유지

    /// 같은 공유기 안이면 아이디 작은 쪽이 내부 주소로. 아니면 포트를 연 쪽이 기다리고 못 연 쪽이 붙는다.
    /// 둘 다 열렸으면 아이디 작은 쪽이 붙고, 90초 안에 안 붙으면 다른 쪽도 붙어 본다.
    func role(for peer: SyncDevice) -> SyncRole {
        if Date().timeIntervalSince(peer.updatedAt) > Self.staleAfter { return .none(reason: "\(peer.name) 소식 없음") }
        if me.internalPort == 0 { return .none(reason: "나는 대기 못 함") }
        let iAmFirst = me.id < peer.id
        if !peer.publicIP.isEmpty, peer.publicIP == me.publicIP, !peer.localIP.isEmpty, peer.internalPort > 0 {
            let dial = SyncRole.dial(host: peer.localIP, port: peer.internalPort, via: "내부 \(peer.localIP):\(peer.internalPort)", reason: "같은 공유기 안")
            return iAmFirst || waitedTooLong(peer) ? dial : .wait(reason: "같은 공유기 안 · 저쪽 차례")
        }
        guard !peer.publicIP.isEmpty, peer.port > 0 else {
            return me.reachable ? .wait(reason: "저쪽 주소를 모름") : .none(reason: "저쪽 주소를 모름")
        }
        let dial = SyncRole.dial(host: peer.publicIP, port: peer.port, via: "외부 \(peer.publicIP):\(peer.port)", reason: "")
        func withReason(_ r: String) -> SyncRole {
            if case .dial(let h, let p, let v, _) = dial { return .dial(host: h, port: p, via: v, reason: r) }
            return dial
        }
        // 짐작(포트를 열었다/공인 IP 다)보다 실제로 붙어 본 결과가 먼저다
        let meIn = inbound(from: peer)
        let peerIn = outbound(to: peer)
        let meOpen = meIn.evidence ?? me.reachable
        let peerOpen = peerIn.evidence ?? peer.reachable
        switch (meOpen, peerOpen) {
        case (false, true):
            return withReason(meIn.evidence == false ? "저쪽이 나에게 못 붙음" : "저쪽만 포트가 열림")
        case (true, false):
            return .wait(reason: peerIn.evidence == false ? "내가 저쪽에 못 붙음" : "나만 포트가 열림")
        case (true, true):
            if meIn.evidence == true, peerIn.evidence != true { return .wait(reason: "저쪽이 나에게 붙은 적 있음") }
            if peerIn.evidence == true, meIn.evidence != true { return withReason("내가 저쪽에 붙은 적 있음") }
            if iAmFirst { return withReason("둘 다 열림 · 내 차례") }
            return waitedTooLong(peer) ? withReason("저쪽이 안 붙어 와서") : .wait(reason: "둘 다 열림 · 저쪽 차례")
        case (false, false):
            return .none(reason: "둘 다 들어오는 연결이 막혀 중계가 필요")
        }
    }

    /// 이 정도 지난 실패는 잊고 다시 해 본다 (주소가 바뀌면 시간과 상관없이 바로 잊는다)
    static let evidenceTTL: TimeInterval = 10 * 60

    /// 붙어 본 기록이 지금 이 주소에 대한 것인지 ("외부 1.2.3.4:47731" / "내부 192.168.0.5:47731")
    private static func link(_ l: SyncLinkInfo, isFor d: SyncDevice) -> Bool {
        l.via == "외부 \(d.publicIP):\(d.port)" || l.via == "내부 \(d.localIP):\(d.internalPort)"
    }

    /// 저쪽이 나에게 붙어 본 결과 (true 붙음, false 못 붙음, nil 모름) — 저쪽 기록과 지금 받은 연결로.
    /// 저쪽이 붙어 본 주소가 지금 내 주소와 다르면(내가 다른 망으로 옮김) 그 기록은 버린다.
    func inbound(from peer: SyncDevice) -> (evidence: Bool?, text: String) {
        if conns[peer.id] != nil, me.links[peer.id]?.outgoing == false { return (true, "\(peer.name) 이 붙어 와 있음") }
        guard let l = peer.links[me.id], l.outgoing else { return (nil, "아직 아무도 붙어 보지 않음") }
        guard Self.link(l, isFor: me) else { return (nil, "내 주소가 바뀌어 다시 확인 필요") }
        let fresh = Date().timeIntervalSince(l.at) < Self.evidenceTTL
        if l.up { return (true, "\(peer.name) 이 붙음") }
        // 붙었다가 끊긴 것(앱 재시작 등)은 못 붙은 게 아니다. 붙어 본 적 없는 실패만 lastSeen 이 없다
        if l.lastSeen != nil { return (true, "\(peer.name) 이 붙은 적 있음") }
        if fresh { return (false, "\(peer.name) 이 못 붙음: \(l.error ?? "")") }
        return (nil, "오래전 실패라 다시 확인 필요")
    }

    /// 내가 저쪽에 붙어 본 결과. 저쪽 주소가 바뀌었으면(다른 망으로 옮김) 기록을 버린다.
    func outbound(to peer: SyncDevice) -> (evidence: Bool?, text: String) {
        guard let l = me.links[peer.id], l.outgoing else { return (nil, "") }
        guard Self.link(l, isFor: peer) else { return (nil, "저쪽 주소가 바뀜") }
        if l.up || l.lastSeen != nil { return (true, "") }
        if Date().timeIntervalSince(l.at) < Self.evidenceTTL { return (false, l.error ?? "") }
        return (nil, "")
    }

    /// 내 공인 IP 가 바뀌면(다른 망) 내가 붙어 본 실패 기록과 다시 붙기 대기를 지운다
    private func networkChanged() {
        me.links = me.links.filter { $0.value.up }
        nextDial = [:]
        dialFailures = [:]
        waitingSince = [:]
    }

    /// 화면용: 바깥에서 나에게 붙을 수 있는지 — 다른 기기가 실제로 붙어 본 결과
    var inboundSummary: (ok: Bool?, text: String) {
        var results: [(Bool?, String)] = peers.map { inbound(from: $0) }.map { ($0.evidence, $0.text) }
        results = results.filter { $0.0 != nil }
        if let yes = results.first(where: { $0.0 == true }) { return (true, "확인됨 · \(yes.1)") }
        if let no = results.first { return (false, "막힘 · \(no.1)") }
        return (nil, "확인 전 (다른 기기가 붙어 봐야 앎)")
    }

    static let waitGiveUp: TimeInterval = 3 * 60

    private func fallbackTarget(_ peer: SyncDevice) -> (host: String, port: Int, via: String)? {
        if !peer.publicIP.isEmpty, peer.publicIP == me.publicIP, !peer.localIP.isEmpty, peer.internalPort > 0 {
            return (peer.localIP, peer.internalPort, "내부 \(peer.localIP):\(peer.internalPort)")
        }
        guard !peer.publicIP.isEmpty, peer.port > 0 else { return nil }
        return (peer.publicIP, peer.port, "외부 \(peer.publicIP):\(peer.port)")
    }

    private func waitedTooLong(_ peer: SyncDevice) -> Bool {
        guard let since = waitingSince[peer.id] else { return false }
        return Date().timeIntervalSince(since) > 90
    }

    /// 5초마다: 역할대로 붙고, 신호 보내고, 오래 조용한 연결은 끊는다
    func manageLinks() {
        let now = Date()
        for peer in peers {
            if conns[peer.id] != nil {
                waitingSince[peer.id] = nil
                continue
            }
            let r = role(for: peer)
            if case .wait = r {
                if waitingSince[peer.id] == nil { waitingSince[peer.id] = now }
            } else {
                waitingSince[peer.id] = nil
            }
            if case .dial(let host, let port, let via, _) = r, dialing[peer.id] == nil, (nextDial[peer.id] ?? .distantPast) <= now {
                dial(peer, host: host, port: port, via: via)
            } else if case .wait = r, let since = waitingSince[peer.id], now.timeIntervalSince(since) > Self.waitGiveUp,
                      dialing[peer.id] == nil, (nextDial[peer.id] ?? .distantPast) <= now,
                      let target = fallbackTarget(peer) {
                // 서로 기다리는 일이 없게: 3분 넘게 안 붙어 오면 나도 붙어 본다
                note("\(peer.name) 이 \(Int(Self.waitGiveUp / 60))분 넘게 안 붙어 와서 내가 붙어 봄")
                waitingSince[peer.id] = now
                dial(peer, host: target.host, port: target.port, via: target.via)
            }
        }
        for (id, c) in conns {
            let info = me.links[id]
            if let seen = info?.lastSeen, now.timeIntervalSince(seen) > Self.deadAfter {
                c.queue.async { c.close("\(Int(Self.deadAfter))초 동안 신호 없음") }
                continue
            }
            if info?.outgoing == true {
                pingSeq += 1
                pingSent[id] = (pingSeq, now)
                let n = pingSeq
                c.queue.async { c.send(SyncMsg(t: "ping", n: n)) }
            }
        }
        dumpForDebug()
    }

    private func dial(_ peer: SyncDevice, host: String, port: Int, via: String) {
        let c = LineConnection(host: host, port: UInt16(port), queue: listener.queue)
        dialing[peer.id] = c
        let started = Date()
        let me = SyncMsg(t: "hello", id: self.me.id, name: self.me.name)
        c.onReady = { c.send(me) }
        c.onMessage = { [weak self] m in
            Task { @MainActor in self?.dialMessage(m, peer: peer, conn: c, via: via, started: started) }
        }
        c.onClose = { [weak self] reason in
            Task { @MainActor in self?.closed(peer.id, conn: c, reason: reason, outgoing: true, via: via) }
        }
        c.start()
    }

    private func dialMessage(_ m: SyncMsg, peer: SyncDevice, conn c: LineConnection, via: String, started: Date) {
        switch m.t {
        case "hello":
            guard m.id == peer.id else {
                c.queue.async { c.close("다른 기기가 답함 (\(m.name ?? "?"))") }
                return
            }
            dialing[peer.id] = nil
            dialFailures[peer.id] = 0
            replace(peer.id, with: c)
            let rtt = Int(Date().timeIntervalSince(started) * 1000)
            me.links[peer.id] = SyncLinkInfo(up: true, outgoing: true, via: via, since: Date(), lastSeen: Date(), rtt: rtt, error: nil, at: Date())
            note("\(peer.name) 에 붙음 — \(via) (\(rtt)ms)")
            Task { await pollICloud() }
        case "pong":
            guard conns[peer.id] === c else { return }
            me.links[peer.id]?.lastSeen = Date()
            if let (n, at) = pingSent[peer.id], n == m.n {
                me.links[peer.id]?.rtt = Int(Date().timeIntervalSince(at) * 1000)
            }
        default: break
        }
    }

    /// 들어온 연결: 첫 줄이 같은 iCloud 목록 기기의 인사여야 받는다
    private func accept(_ c: LineConnection) {
        var peerID: String?
        c.onMessage = { [weak self] m in
            Task { @MainActor in
                guard let self else { return }
                switch m.t {
                case "hello":
                    guard peerID == nil, let id = m.id, id != self.me.id, let peer = self.allDevices[id] else {
                        c.queue.async { c.close("모르는 기기 (\(m.name ?? "?"))") }
                        if peerID == nil { self.note("모르는 기기의 연결 거절: \(m.name ?? "?") \(c.remote)") }
                        return
                    }
                    peerID = id
                    let reply = SyncMsg(t: "hello", id: self.me.id, name: self.me.name)
                    c.queue.async { c.send(reply) }
                    self.replace(id, with: c)
                    self.me.links[id] = SyncLinkInfo(up: true, outgoing: false, via: c.remote, since: Date(), lastSeen: Date(), rtt: nil, error: nil, at: Date())
                    self.note("\(peer.name) 이(가) 붙어 옴 — \(c.remote)")
                    Task { await self.pollICloud() }
                case "ping":
                    guard let id = peerID, self.conns[id] === c else { return }
                    self.me.links[id]?.lastSeen = Date()
                    let pong = SyncMsg(t: "pong", n: m.n)
                    c.queue.async { c.send(pong) }
                default: break
                }
            }
        }
        c.onClose = { [weak self] reason in
            Task { @MainActor in
                guard let self, let id = peerID else { return }
                self.closed(id, conn: c, reason: reason, outgoing: false, via: c.remote)
            }
        }
        c.start()
        // 인사가 10초 안에 안 오면 끊는다
        c.queue.asyncAfter(deadline: .now() + 10) {
            Task { @MainActor in if peerID == nil { c.queue.async { c.close("인사 없음") } } }
        }
    }

    /// 같은 기기와의 옛 연결은 끊고 새 것으로
    private func replace(_ id: String, with c: LineConnection) {
        if let old = conns[id], old !== c {
            conns[id] = c
            old.queue.async { old.close("새 연결로 바뀜") }
        } else {
            conns[id] = c
        }
    }

    private func closed(_ id: String, conn c: LineConnection, reason: String?, outgoing: Bool, via: String) {
        let name = allDevices[id]?.name ?? "?"
        if dialing[id] === c {
            dialing[id] = nil
            let fails = (dialFailures[id] ?? 0) + 1
            dialFailures[id] = fails
            let wait = min(60, 5 * fails)
            nextDial[id] = Date().addingTimeInterval(TimeInterval(wait))
            let text = reason ?? "끊김"
            if me.links[id]?.error != text || me.links[id]?.up == true { note("\(name) 에 못 붙음 — \(via): \(text) (\(wait)초 뒤 다시)") }
            me.links[id] = SyncLinkInfo(up: false, outgoing: true, via: via, since: nil, lastSeen: nil, rtt: nil, error: text, at: Date())
            Task { await pollICloud() }
            return
        }
        guard conns[id] === c else { return }
        conns[id] = nil
        nextDial[id] = Date().addingTimeInterval(3)
        note("\(name) 연결 끊김 — \(reason ?? "")")
        me.links[id] = SyncLinkInfo(up: false, outgoing: outgoing, via: via, since: nil, lastSeen: me.links[id]?.lastSeen, rtt: nil, error: reason ?? "끊김", at: Date())
        Task { await pollICloud() }
    }

    // MARK: 스키마 만들기 (개발 환경 한 번)

    /// `iNAS --sync-schema`: 개발 서명 빌드로 한 번 돌려 CloudKit 개발 환경에 Sync 영역 · SyncDevice 형식을 만든다.
    /// Developer ID 앱은 운영 환경만 쓸 수 있어서, 그다음 CloudKit 콘솔에서 운영으로 올려야(Deploy Schema Changes) 한다.
    nonisolated static let schemaArgument = "--sync-schema"

    nonisolated static func runSchemaSeed() -> Never {
        Task.detached {
            do {
                let db = CKContainer(identifier: containerID).privateCloudDatabase
                _ = try await db.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
                let seed = SyncDevice(
                    id: "schema-seed", name: "seed", model: "seed", modelID: "seed", os: "seed", appVersion: "seed",
                    localIP: "0.0.0.0", publicIP: "0.0.0.0", port: 1, internalPort: 1, portMethod: "seed", reachable: true,
                    updatedAt: Date(), links: ["x": SyncLinkInfo(up: true, outgoing: true, via: "seed", at: Date())]
                )
                try await saveChecked(record(from: seed), in: db)
                _ = try await db.modifyRecords(saving: [], deleting: [CKRecord.ID(recordName: seed.id, zoneID: zoneID)])
                let folder = SyncFolder(id: "schema-seed-folder", name: "seed")
                try await SyncFolderStore.save(folder, in: db)
                _ = try await db.modifyRecords(saving: [], deleting: [CKRecord.ID(recordName: folder.id, zoneID: zoneID)])
                print("스키마 만듦: 영역 Sync · 형식 \(recordType), \(SyncFolderStore.recordType)")
                exit(0)
            } catch {
                print("스키마 실패: \(error)")
                exit(1)
            }
        }
        dispatchMain()
    }

    // MARK: 기록

    private func note(_ text: String) {
        log.insert((Date(), text), at: 0)
        if log.count > 100 { log.removeLast(log.count - 100) }
        Log.app.info("sync: \(text, privacy: .public)")
    }

    /// 시험용: `defaults write com.moimz.iNAS syncDebugDumpDir <폴더>` 를 해 두면 상태를 <폴더>/<이름>.json 으로 쓴다
    /// 30초에 한 번만 쓴다. 5초마다 다시 쓰면 Syncthing 이 옮기는 도중 파일이 바뀌어 끝내 못 넘긴다(.syncthing.*.tmp 만 남음).
    private func dumpForDebug() {
        guard let dir = UserDefaults.standard.string(forKey: "syncDebugDumpDir"), !dir.isEmpty else { return }
        guard Date().timeIntervalSince(lastDump) >= 30 else { return }
        lastDump = Date()
        struct Dump: Encodable {
            var at: Date
            var me: SyncDevice
            var peers: [SyncDevice]
            var roles: [String: String]
            var listen, stun, iCloud: String
            var log: [String]
        }
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        let dump = Dump(
            at: Date(), me: me, peers: peers,
            roles: Dictionary(uniqueKeysWithValues: peers.map { ("\($0.name) \($0.id.prefix(8))", role(for: $0).text) }),
            listen: listenStatus, stun: stunStatus, iCloud: iCloudStatus,
            log: log.map { "\(f.string(from: $0.0)) \($0.1)" }
        )
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        guard let data = try? e.encode(dump) else { return }
        let url = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath).appendingPathComponent("\(me.name).json")
        try? data.write(to: url, options: .atomic)
    }
}
